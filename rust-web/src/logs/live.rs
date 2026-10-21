//! Live publication of committed log entries. Publishing never blocks: a slow
//! viewer lags its own receiver and then replays from storage.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use tokio::sync::broadcast;

use crate::{domain::OrgId, error::ApiError, logs::read::Cursor};

/// The cursor of the last committed entry.
pub struct Published {
    pub cursor: Cursor,
}

pub struct OrgChannel {
    pub tx: broadcast::Sender<Arc<Published>>,
}

pub struct LiveHub {
    channels: Mutex<HashMap<OrgId, Arc<OrgChannel>>>,
    viewers: Arc<Mutex<Viewers>>,
    capacity: usize,
    max_orgs: usize,
}

#[derive(Default)]
struct Viewers {
    total: usize,
    per_org: HashMap<OrgId, usize>,
}

pub struct ViewerSlot {
    viewers: Arc<Mutex<Viewers>>,
    org: OrgId,
}

impl Drop for ViewerSlot {
    fn drop(&mut self) {
        let mut viewers = self.viewers.lock().expect("viewer lock");
        viewers.total -= 1;
        if let Some(count) = viewers.per_org.get_mut(&self.org) {
            *count -= 1;
            if *count == 0 {
                viewers.per_org.remove(&self.org);
            }
        }
    }
}

impl LiveHub {
    pub fn new(capacity: usize, max_orgs: usize) -> Self {
        Self {
            channels: Mutex::default(),
            viewers: Arc::default(),
            capacity: capacity.max(1),
            max_orgs: max_orgs.max(1),
        }
    }

    pub fn cached_orgs(&self) -> usize {
        self.channels.lock().expect("hub lock").len()
    }

    pub fn existing(&self, org: &OrgId) -> Option<Arc<OrgChannel>> {
        self.channels.lock().expect("hub lock").get(org).cloned()
    }

    pub fn channel(&self, org: &OrgId) -> Result<Arc<OrgChannel>, ApiError> {
        let mut channels = self.channels.lock().expect("hub lock");
        if let Some(channel) = channels.get(org) {
            return Ok(channel.clone());
        }
        if channels.len() >= self.max_orgs {
            let idle = channels
                .iter()
                .find(|(_, channel)| {
                    Arc::strong_count(channel) == 1 && channel.tx.receiver_count() == 0
                })
                .map(|(org, _)| org.clone())
                .ok_or(ApiError::Unavailable("org_cache_overloaded"))?;
            channels.remove(&idle);
        }
        let channel = Arc::new(OrgChannel {
            tx: broadcast::channel(self.capacity).0,
        });
        channels.insert(org.clone(), channel.clone());
        Ok(channel)
    }

    pub fn viewer(&self, org: &OrgId, max_total: usize, max_org: usize) -> Option<ViewerSlot> {
        let mut viewers = self.viewers.lock().expect("viewer lock");
        let current = viewers.per_org.get(org).copied().unwrap_or(0);
        if viewers.total >= max_total || current >= max_org {
            return None;
        }
        viewers.total += 1;
        viewers.per_org.insert(org.clone(), current + 1);
        Some(ViewerSlot {
            viewers: self.viewers.clone(),
            org: org.clone(),
        })
    }
}
