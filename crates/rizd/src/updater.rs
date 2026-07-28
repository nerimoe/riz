use crate::{build_version::BUILD_VERSION, config::data_dir};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf, process::Command};
use uuid::Uuid;

const RELEASES_URL: &str = "https://api.github.com/repos/nerimoe/riz/releases";
const USER_AGENT: &str = "rizd-updater";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UpdateChannel {
    Stable,
    Prerelease,
}

impl UpdateChannel {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "stable" | "release" => Ok(Self::Stable),
            "prerelease" => Ok(Self::Prerelease),
            _ => bail!("invalid update channel: {value}"),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
struct ReleaseAsset {
    name: String,
    browser_download_url: String,
}

#[derive(Debug, Clone, Deserialize)]
struct Release {
    tag_name: String,
    name: Option<String>,
    prerelease: bool,
    published_at: Option<String>,
    assets: Vec<ReleaseAsset>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    current_version: String,
    channel: UpdateChannel,
    target_version: String,
    release_name: String,
    prerelease: bool,
    published_at: Option<String>,
    available: bool,
    compatible: bool,
    asset_name: String,
    #[serde(skip_serializing)]
    binary_url: Option<String>,
    #[serde(skip_serializing)]
    checksum_url: Option<String>,
}

impl UpdateInfo {
    pub fn is_available(&self) -> bool {
        self.available
    }
}

pub fn current_version() -> &'static str {
    BUILD_VERSION
}

pub fn configured_channel() -> UpdateChannel {
    fs::read_to_string(channel_path())
        .ok()
        .and_then(|value| UpdateChannel::parse(value.trim()).ok())
        .unwrap_or(UpdateChannel::Stable)
}

pub fn set_channel(channel: UpdateChannel) -> Result<()> {
    let path = channel_path();
    fs::create_dir_all(path.parent().context("invalid update channel path")?)?;
    let temporary = path.with_extension("tmp");
    fs::write(
        &temporary,
        match channel {
            UpdateChannel::Stable => "stable\n",
            UpdateChannel::Prerelease => "prerelease\n",
        },
    )?;
    fs::rename(temporary, path)?;
    Ok(())
}

pub fn status() -> serde_json::Value {
    serde_json::json!({
        "currentVersion": current_version(),
        "channel": configured_channel(),
        "repository": "nerimoe/riz",
        "platform": std::env::consts::OS,
        "architecture": std::env::consts::ARCH,
    })
}

pub async fn check(channel: UpdateChannel) -> Result<UpdateInfo> {
    set_channel(channel)?;
    let client = reqwest::Client::builder().user_agent(USER_AGENT).build()?;
    let release = match channel {
        UpdateChannel::Stable => {
            client
                .get(format!("{RELEASES_URL}/latest"))
                .send()
                .await?
                .error_for_status()?
                .json::<Release>()
                .await?
        }
        UpdateChannel::Prerelease => {
            let releases = client
                .get(format!("{RELEASES_URL}?per_page=30"))
                .send()
                .await?
                .error_for_status()?
                .json::<Vec<Release>>()
                .await?;
            releases
                .into_iter()
                .find(|release| release.prerelease)
                .context("no prerelease is currently available")?
        }
    };
    Ok(update_info(channel, release))
}

pub async fn install(channel: UpdateChannel) -> Result<UpdateInfo> {
    let info = check(channel).await?;
    if !info.compatible {
        bail!(
            "release does not contain a compatible {} asset",
            info.asset_name
        );
    }
    if !info.available {
        return Ok(info);
    }
    let client = reqwest::Client::builder().user_agent(USER_AGENT).build()?;
    let binary = download(
        &client,
        info.binary_url.as_deref().context("missing binary URL")?,
    )
    .await?;
    let checksum = download(
        &client,
        info.checksum_url
            .as_deref()
            .context("missing checksum URL")?,
    )
    .await?;
    let expected = String::from_utf8(checksum)?
        .split_whitespace()
        .next()
        .context("empty checksum")?
        .to_ascii_lowercase();
    let actual = format!("{:x}", Sha256::digest(&binary));
    if actual != expected {
        bail!("downloaded daemon checksum mismatch");
    }
    replace_current_executable(&binary)?;
    Ok(info)
}

pub fn schedule_restart() -> Result<bool> {
    let command = if cfg!(target_os = "linux") {
        "sleep 1; systemctl --user restart rizd.service"
    } else if cfg!(target_os = "macos") {
        "sleep 1; launchctl kickstart -k gui/$(id -u)/dev.riz.rizd"
    } else {
        return Ok(false);
    };
    Command::new("sh")
        .args(["-c", command])
        .spawn()
        .context("schedule daemon restart")?;
    Ok(true)
}

fn update_info(channel: UpdateChannel, release: Release) -> UpdateInfo {
    let asset_name = platform_asset_name();
    let checksum_name = format!("{asset_name}.sha256");
    let binary_url = release
        .assets
        .iter()
        .find(|asset| asset.name == asset_name)
        .map(|asset| asset.browser_download_url.clone());
    let checksum_url = release
        .assets
        .iter()
        .find(|asset| asset.name == checksum_name)
        .map(|asset| asset.browser_download_url.clone());
    let compatible = binary_url.is_some() && checksum_url.is_some();
    let target_version = release.tag_name.trim_start_matches('v').to_owned();
    UpdateInfo {
        current_version: current_version().to_owned(),
        channel,
        available: target_version != current_version(),
        target_version,
        release_name: release.name.unwrap_or_else(|| release.tag_name.clone()),
        prerelease: release.prerelease,
        published_at: release.published_at,
        compatible,
        asset_name,
        binary_url,
        checksum_url,
    }
}

fn platform_asset_name() -> String {
    let target = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") => "x86_64-unknown-linux-gnu",
        ("linux", "aarch64") => "aarch64-unknown-linux-gnu",
        ("macos", "x86_64") => "x86_64-apple-darwin",
        ("macos", "aarch64") => "aarch64-apple-darwin",
        (os, architecture) => return format!("rizd-{architecture}-{os}"),
    };
    format!("rizd-{target}")
}

async fn download(client: &reqwest::Client, url: &str) -> Result<Vec<u8>> {
    let response = client.get(url).send().await?.error_for_status()?;
    let length = response.content_length().unwrap_or_default();
    if length > 100 * 1024 * 1024 {
        bail!("update asset is larger than 100 MiB");
    }
    let bytes = response.bytes().await?;
    if bytes.len() > 100 * 1024 * 1024 {
        bail!("update asset is larger than 100 MiB");
    }
    Ok(bytes.to_vec())
}

fn replace_current_executable(bytes: &[u8]) -> Result<()> {
    let executable = std::env::current_exe().context("locate current rizd executable")?;
    let parent = executable
        .parent()
        .context("invalid rizd executable path")?;
    let temporary = parent.join(format!(".rizd-update-{}", Uuid::new_v4()));
    fs::write(&temporary, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o755))?;
    }
    if let Err(error) = fs::rename(&temporary, &executable) {
        let _ = fs::remove_file(&temporary);
        return Err(error).context("replace rizd executable");
    }
    Ok(())
}

fn channel_path() -> PathBuf {
    data_dir().join("update-channel")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(prerelease: bool, tag: &str, assets: &[&str]) -> Release {
        Release {
            tag_name: tag.into(),
            name: None,
            prerelease,
            published_at: Some("2026-07-28T00:00:00Z".into()),
            assets: assets
                .iter()
                .map(|name| ReleaseAsset {
                    name: (*name).into(),
                    browser_download_url: format!("https://example.test/{name}"),
                })
                .collect(),
        }
    }

    #[test]
    fn maps_update_channels() {
        assert_eq!(
            UpdateChannel::parse("release").unwrap(),
            UpdateChannel::Stable
        );
        assert_eq!(
            UpdateChannel::parse("prerelease").unwrap(),
            UpdateChannel::Prerelease
        );
        assert!(UpdateChannel::parse("nightly").is_err());
    }

    #[test]
    fn requires_binary_and_checksum_assets() {
        let asset = platform_asset_name();
        let checksum = format!("{asset}.sha256");
        let complete = update_info(
            UpdateChannel::Stable,
            release(false, "v9.0.0", &[&asset, &checksum]),
        );
        assert!(complete.compatible);
        assert!(complete.available);
        let incomplete = update_info(
            UpdateChannel::Prerelease,
            release(true, "v9.0.0-deadbeef", &[&asset]),
        );
        assert!(!incomplete.compatible);
    }
}
