use std::{sync::Arc, time::Duration};

use loco_rs::{app::AppContext, Error, Result};

use crate::{
    account_settings::AccountMail, agent_access::OAuthService, backup::Backups,
    backup_sets::BackupSets, credentials::Credentials, notifications::Notifications,
    reports::Reports, runtime::Runtime,
};

pub struct Services {
    pub billing: Arc<crate::billing::Billing>,
    pub turnstile: Option<crate::turnstile::Turnstile>,
    pub oauth: OAuthService,
    pub notifications: Notifications,
    pub reports: Reports,
    pub account_mail: Arc<dyn AccountMail>,
    pub backups: Arc<BackupSets>,
}

impl Services {
    pub fn install(ctx: &AppContext, runtime: &Arc<Runtime>) -> Result<()> {
        let credentials = ctx
            .shared_store
            .get::<Arc<Credentials>>()
            .ok_or_else(|| Error::string("typed credentials are not installed"))?;
        let turnstile = credentials
            .turnstile
            .as_ref()
            .map(crate::turnstile::Turnstile::new)
            .transpose()?;
        let notifications = Notifications::new(
            runtime.control.clone(),
            runtime.tenants.clone(),
            runtime.store.clone(),
            &credentials.security.data_key,
            credentials.smtp.as_ref(),
            runtime.settings.notifications.clone(),
        )
        .map_err(|_| Error::string("notification configuration is invalid"))?;
        let reports = Reports::new(
            runtime.control.clone(),
            runtime.tenants.clone(),
            runtime.store.clone(),
            notifications.clone(),
        );
        let scratch = crate::backup::scratch_root(&runtime.settings.tenants.root)
            .ok_or_else(|| Error::string("tenant root needs a parent directory"))?;
        std::fs::create_dir_all(&scratch)
            .map_err(|_| Error::string("backup scratch could not be created"))?;
        let data_root = crate::disk::data_root(&runtime.settings.tenants.root)
            .map_err(|_| Error::string("tenant root needs a parent directory"))?;
        crate::backup::prepare_sqlite_temp(
            std::env::var_os("SQLITE_TMPDIR").as_deref(),
            &data_root,
            ctx.environment == loco_rs::environment::Environment::Production,
        )
        .map_err(|error| Error::string(&error))?;
        let backups = Backups::new(
            scratch,
            runtime.settings.backup.limits(),
            &credentials.security.data_key,
        )
        .map_err(|_| Error::string("backup configuration is invalid"))?;
        let backups = BackupSets::new(backups, runtime.settings.backup.clone());
        let billing = Arc::new(crate::billing::Billing::new(
            credentials.stripe.as_ref(),
            &runtime.settings,
        )?);
        ctx.shared_store.insert(billing.clone());
        runtime
            .notifications
            .set(notifications.clone())
            .map_err(|_| Error::string("notifications are already installed"))?;
        let oauth = ctx
            .shared_store
            .get::<OAuthService>()
            .ok_or_else(|| Error::string("OAuth service is not installed"))?;
        ctx.shared_store.insert(Arc::new(Self {
            billing,
            turnstile,
            oauth,
            account_mail: Arc::new(notifications.clone()),
            notifications,
            reports,
            backups: Arc::new(backups),
        }));
        Ok(())
    }

    pub fn get(ctx: &AppContext) -> Arc<Self> {
        ctx.shared_store
            .get::<Arc<Self>>()
            .expect("application services are installed")
    }
}

pub async fn notification_loop(runtime: Arc<Runtime>, service: Notifications, oauth: OAuthService) {
    let mut interval = tokio::time::interval(Duration::from_secs(5));
    let mut after = None;
    loop {
        tokio::select! {
            () = runtime.cancel.cancelled() => return,
            _ = interval.tick() => {}
        }
        let Some(_guard) = runtime.gate.enter() else {
            if !runtime.gate.is_open() {
                return;
            }
            continue;
        };
        if crate::account_settings::sweep_tokens(&runtime, 500)
            .await
            .is_err()
            || oauth.sweep(500).await.is_err()
        {
            tracing::warn!("expired access token cleanup failed");
        }
        let orgs = match crate::identity::orgs::page_ids(&runtime, after.as_ref(), 200).await {
            Ok(orgs) => orgs,
            Err(_) => {
                tracing::warn!("notification organization lookup failed");
                continue;
            }
        };
        after = (orgs.len() == 200).then(|| orgs.last().unwrap().clone());
        for org in orgs {
            tokio::select! {
                () = runtime.cancel.cancelled() => return,
                result = service.run_pending_for_org(&org) => {
                    if result.is_err() {
                        tracing::warn!("notification processing failed");
                    }
                }
            }
            tokio::select! {
                () = runtime.cancel.cancelled() => return,
                result = crate::billing::alerts::deliver(&runtime, &service, &org) => {
                    if result.is_err() {
                        tracing::warn!("usage alert delivery failed");
                    }
                }
            }
            tokio::select! {
                () = runtime.cancel.cancelled() => return,
                result = crate::billing::notices::deliver(&runtime, &service, &org) => {
                    if result.is_err() {
                        tracing::warn!("trial notice delivery failed");
                    }
                }
            }
        }
    }
}
