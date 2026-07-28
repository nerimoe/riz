use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    fs::OpenOptions,
    io::Write,
    net::SocketAddr,
    path::{Path, PathBuf},
};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IssuedToken {
    pub id: Uuid,
    pub name: String,
    pub token_hash: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayConfig {
    pub base_url: String,
    pub device_id: String,
    pub token: String,
}

impl RelayConfig {
    pub fn daemon_url(&self) -> String {
        format!("{}/v1/relay/{}/daemon", self.base_url, self.device_id)
    }

    pub fn client_url(&self) -> String {
        format!("{}/v1/relay/{}/client", self.base_url, self.device_id)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub daemon_id: Uuid,
    pub name: String,
    pub listen: SocketAddr,
    pub token_hash: String,
    #[serde(default)]
    pub issued_tokens: Vec<IssuedToken>,
    #[serde(default)]
    pub relay: Option<RelayConfig>,
}

impl Config {
    pub fn create(path: &Path, listen: SocketAddr) -> Result<(Self, String)> {
        if path.exists() {
            bail!("config already exists at {}", path.display());
        }
        let mut bytes = [0_u8; 32];
        rand::rng().fill_bytes(&mut bytes);
        let token = URL_SAFE_NO_PAD.encode(bytes);
        let hostname = std::process::Command::new("hostname")
            .arg("-s")
            .output()
            .ok()
            .filter(|v| v.status.success())
            .map(|v| String::from_utf8_lossy(&v.stdout).trim().to_owned())
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| "Mac".into());
        let config = Self {
            daemon_id: Uuid::new_v4(),
            name: hostname,
            listen,
            token_hash: hash_token(&token),
            issued_tokens: Vec::new(),
            relay: None,
        };
        config.save(path)?;
        Ok((config, token))
    }

    pub fn load(path: &Path) -> Result<Self> {
        let data = fs::read(path).with_context(|| format!("read {}", path.display()))?;
        Ok(serde_json::from_slice(&data)?)
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temp = path.with_extension("tmp");
        let mut options = OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temp)?;
        file.write_all(&serde_json::to_vec_pretty(self)?)?;
        file.sync_all()?;
        fs::rename(temp, path)?;
        Ok(())
    }

    pub fn verify_token(&self, token: &str) -> bool {
        let candidate = hash_token(token);
        constant_time_eq(self.token_hash.as_bytes(), candidate.as_bytes())
            || self
                .issued_tokens
                .iter()
                .any(|issued| constant_time_eq(issued.token_hash.as_bytes(), candidate.as_bytes()))
    }

    pub fn rotate_token(&mut self, path: &Path) -> Result<String> {
        let mut bytes = [0_u8; 32];
        rand::rng().fill_bytes(&mut bytes);
        let token = URL_SAFE_NO_PAD.encode(bytes);
        self.token_hash = hash_token(&token);
        self.issued_tokens.clear();
        self.save(path)?;
        Ok(token)
    }

    pub fn issue_token(&mut self, path: &Path, name: String) -> Result<(Uuid, String)> {
        let mut bytes = [0_u8; 32];
        rand::rng().fill_bytes(&mut bytes);
        let token = URL_SAFE_NO_PAD.encode(bytes);
        let id = Uuid::new_v4();
        self.issued_tokens.push(IssuedToken {
            id,
            name,
            token_hash: hash_token(&token),
            created_at: chrono::Utc::now().to_rfc3339(),
        });
        self.save(path)?;
        Ok((id, token))
    }

    pub fn revoke_token(&mut self, path: &Path, id: Uuid) -> Result<bool> {
        let before = self.issued_tokens.len();
        self.issued_tokens.retain(|token| token.id != id);
        let removed = self.issued_tokens.len() != before;
        if removed {
            self.save(path)?;
        }
        Ok(removed)
    }
}

pub fn data_dir() -> PathBuf {
    std::env::var_os("RIZ_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| dirs::home_dir().expect("home directory").join(".riz"))
}

pub fn hash_token(token: &str) -> String {
    format!("{:x}", Sha256::digest(token.as_bytes()))
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0_u8, |diff, (x, y)| diff | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn token_hash_verification() {
        let c = Config {
            daemon_id: Uuid::nil(),
            name: "test".into(),
            listen: "127.0.0.1:7497".parse().unwrap(),
            token_hash: hash_token("secret"),
            issued_tokens: Vec::new(),
            relay: None,
        };
        assert!(c.verify_token("secret"));
        assert!(!c.verify_token("other"));
    }

    #[test]
    fn issues_and_revokes_an_additional_token() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        let (mut config, primary) =
            Config::create(&path, "127.0.0.1:7497".parse().unwrap()).unwrap();
        let (id, issued) = config.issue_token(&path, "phone".into()).unwrap();
        assert!(config.verify_token(&primary));
        assert!(config.verify_token(&issued));
        assert!(config.revoke_token(&path, id).unwrap());
        assert!(!config.verify_token(&issued));
        assert!(config.verify_token(&primary));
    }
}
