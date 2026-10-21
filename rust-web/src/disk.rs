use std::{
    fs, io,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use crate::{runtime::Runtime, settings::DiskSettings};

#[derive(Clone, Copy, Debug)]
pub struct Snapshot {
    pub bytes: u64,
    pub entries: usize,
    pub available_bytes: u64,
}

pub struct DiskAdmission {
    root: PathBuf,
    settings: DiskSettings,
    state: Mutex<Option<(Snapshot, Instant)>>,
}

impl DiskAdmission {
    pub fn new(root: PathBuf, settings: DiskSettings) -> Self {
        Self {
            root,
            settings,
            state: Mutex::new(None),
        }
    }

    pub fn refresh(&self) -> io::Result<Snapshot> {
        let result = self.scan();
        *self.state.lock().expect("disk admission lock") =
            result.as_ref().ok().map(|s| (*s, Instant::now()));
        result
    }

    pub fn permits_write(&self) -> bool {
        self.state
            .lock()
            .expect("disk admission lock")
            .as_ref()
            .is_some_and(|(snapshot, at)| {
                at.elapsed()
                    <= Duration::from_secs(self.settings.scan_interval_secs.saturating_mul(3))
                    && snapshot.bytes < self.settings.max_bytes
                    && snapshot.entries < self.settings.max_entries
                    && snapshot.available_bytes >= self.settings.min_free_bytes
            })
    }

    fn scan(&self) -> io::Result<Snapshot> {
        let mut snapshot = Snapshot {
            bytes: 0,
            entries: 0,
            available_bytes: fs2::available_space(&self.root)?,
        };
        let mut pending = vec![self.root.clone()];
        while let Some(path) = pending.pop() {
            let entries = match fs::read_dir(path) {
                Ok(entries) => entries,
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error),
            };
            for entry in entries {
                let entry = entry?;
                let metadata = match entry.path().symlink_metadata() {
                    Ok(metadata) => metadata,
                    Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                    Err(error) => return Err(error),
                };
                if metadata.is_symlink() {
                    return Err(io::Error::other("data directory contains a symlink"));
                }
                snapshot.entries += 1;
                snapshot.bytes = snapshot.bytes.saturating_add(metadata.len());
                if snapshot.entries >= self.settings.max_entries
                    || snapshot.bytes >= self.settings.max_bytes
                {
                    return Ok(snapshot);
                }
                if metadata.is_dir() {
                    pending.push(entry.path());
                }
            }
        }
        Ok(snapshot)
    }
}

pub async fn monitor(rt: Arc<Runtime>) {
    let mut interval =
        tokio::time::interval(Duration::from_secs(rt.settings.disk.scan_interval_secs));
    loop {
        tokio::select! {
            () = rt.cancel.cancelled() => return,
            _ = interval.tick() => {}
        }
        let disk = rt.disk.clone();
        if !matches!(
            tokio::task::spawn_blocking(move || disk.refresh()).await,
            Ok(Ok(_))
        ) {
            tracing::warn!("local storage admission scan failed");
        }
    }
}

pub fn data_root(tenant_root: &Path) -> io::Result<PathBuf> {
    let parent = tenant_root
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or_else(|| io::Error::other("tenant root requires a dedicated data parent"))?;
    parent.canonicalize()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_growth_blocks_writes_and_reclamation_restores_admission() {
        let root = std::env::var_os("POSTDEPLOY_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("data/test-runs"))
            .join(format!("disk-admission-{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&root).unwrap();
        let settings = DiskSettings {
            max_bytes: 4096,
            min_free_bytes: 0,
            ..DiskSettings::default()
        };
        let disk = DiskAdmission::new(root.clone(), settings);
        assert!(!disk.permits_write());
        disk.refresh().unwrap();
        assert!(disk.permits_write());
        let file = fs::File::create(root.join("metadata.sqlite")).unwrap();
        file.set_len(8192).unwrap();
        disk.refresh().unwrap();
        assert!(!disk.permits_write());
        file.set_len(0).unwrap();
        disk.refresh().unwrap();
        assert!(disk.permits_write());
    }
}
