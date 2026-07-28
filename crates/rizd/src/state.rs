use crate::{
    config::Config,
    db::{Database, Event},
    provider::AgyProvider,
    terminal::TerminalManager,
};
use anyhow::Result;
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::broadcast;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub enum Outbound {
    Event(Event),
    Binary(Vec<u8>),
}

pub struct UploadTransfer {
    pub path: PathBuf,
    pub expected_size: usize,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Default)]
pub struct AuthRateLimiter(Arc<Mutex<VecDeque<Instant>>>);

impl AuthRateLimiter {
    pub fn delay(&self) -> Duration {
        let failures = self.recent_failures();
        if failures == 0 {
            return Duration::ZERO;
        }
        Duration::from_millis(250_u64.saturating_mul(1_u64 << (failures - 1).min(4)))
    }

    pub fn record_failure(&self) {
        let now = Instant::now();
        let mut failures = self.0.lock().unwrap();
        prune_failures(&mut failures, now);
        failures.push_back(now);
    }

    fn recent_failures(&self) -> usize {
        let now = Instant::now();
        let mut failures = self.0.lock().unwrap();
        prune_failures(&mut failures, now);
        failures.len()
    }
}

fn prune_failures(failures: &mut VecDeque<Instant>, now: Instant) {
    while failures
        .front()
        .is_some_and(|failure| now.duration_since(*failure) >= Duration::from_secs(60))
    {
        failures.pop_front();
    }
}

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub db: Database,
    pub outbound: broadcast::Sender<Outbound>,
    pub terminals: TerminalManager,
    pub agy: AgyProvider,
    pub workers: Arc<Mutex<HashSet<String>>>,
    pub uploads: Arc<Mutex<HashMap<Uuid, UploadTransfer>>>,
    pub auth_limiter: AuthRateLimiter,
}

impl AppState {
    pub fn new(config: Config, db: Database) -> Self {
        let (outbound, _) = broadcast::channel(1024);
        let terminals = TerminalManager::new(outbound.clone(), db.clone());
        Self {
            config: Arc::new(config),
            db,
            terminals,
            agy: AgyProvider::new(),
            outbound,
            workers: Arc::new(Mutex::new(HashSet::new())),
            uploads: Arc::new(Mutex::new(HashMap::new())),
            auth_limiter: AuthRateLimiter::default(),
        }
    }

    pub fn emit(&self, topic: &str, payload: Value) -> Result<Event> {
        let event = self.db.append_event(topic, payload)?;
        let _ = self.outbound.send(Outbound::Event(event.clone()));
        Ok(event)
    }

    pub fn daemon_id(&self) -> Uuid {
        self.config.daemon_id
    }
}

#[cfg(test)]
mod tests {
    use super::AuthRateLimiter;
    use std::time::Duration;

    #[test]
    fn authentication_failures_back_off_exponentially_with_a_cap() {
        let limiter = AuthRateLimiter::default();
        assert_eq!(limiter.delay(), Duration::ZERO);
        let expected = [250, 500, 1000, 2000, 4000, 4000];
        for milliseconds in expected {
            limiter.record_failure();
            assert_eq!(limiter.delay(), Duration::from_millis(milliseconds));
        }
    }
}
