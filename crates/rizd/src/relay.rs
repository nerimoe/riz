use crate::config::{Config, RelayConfig};
use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::{SinkExt, StreamExt};
use rand::RngCore;
use serde::Serialize;
use std::{
    path::Path,
    time::{Duration, Instant},
};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, http::HeaderValue},
};
use url::Url;

const RELAY_PROTOCOL_PREFIX: &str = "riz-relay-v1.";
const CLIENT_PAIRED_MARKER: &str = "riz-relay:client-paired:v1";
const DAEMON_HEARTBEAT: &str = "riz-relay:daemon-heartbeat:v1";
const DAEMON_HEARTBEAT_ACK: &str = "riz-relay:daemon-heartbeat-ack:v1";
const RELAY_CHANNELS: usize = 4;
const CLIENT_FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(10);
const DAEMON_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
const DAEMON_HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingCode<'a> {
    v: u8,
    name: &'a str,
    url: String,
    token: &'a str,
    relay_token: &'a str,
}

pub fn configure(config: &mut Config, path: &Path, raw_url: &str) -> Result<String> {
    let base_url = normalize_base_url(raw_url)?;
    let relay = RelayConfig {
        base_url,
        device_id: random_secret(18),
        token: random_secret(32),
    };
    let (_, client_token) = config.issue_token(path, "relay pairing".into())?;
    let payload = PairingCode {
        v: 1,
        name: &config.name,
        url: relay.client_url(),
        token: &client_token,
        relay_token: &relay.token,
    };
    let code = format!(
        "riz1.{}",
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload)?)
    );
    config.relay = Some(relay);
    config.save(path)?;
    Ok(code)
}

pub async fn run(config: Config) {
    let Some(relay) = config.relay else {
        return;
    };
    futures_util::future::join_all(
        (0..RELAY_CHANNELS).map(|slot| run_channel(config.listen.to_string(), relay.clone(), slot)),
    )
    .await;
}

async fn run_channel(listen: String, relay: RelayConfig, slot: usize) {
    let mut delay = Duration::from_secs(1);
    loop {
        let started = Instant::now();
        match bridge_once(&listen, &relay).await {
            Ok(()) => tracing::warn!(slot, "relay channel closed"),
            Err(error) => {
                tracing::warn!(slot, error = %format!("{error:#}"), "relay channel failed")
            }
        }
        if started.elapsed() >= DAEMON_HEARTBEAT_INTERVAL {
            delay = Duration::from_secs(1);
        } else {
            delay = (delay * 2).min(Duration::from_secs(30));
        }
        tokio::time::sleep(delay).await;
    }
}

async fn bridge_once(listen: &str, relay: &RelayConfig) -> Result<()> {
    let mut request = relay
        .daemon_url()
        .into_client_request()
        .context("build relay WebSocket request")?;
    let relay_protocol = format!("{RELAY_PROTOCOL_PREFIX}{}", relay.token);
    request.headers_mut().insert(
        "sec-websocket-protocol",
        HeaderValue::from_str(&relay_protocol)?,
    );
    let (remote, response) = connect_async(request)
        .await
        .with_context(|| format!("connect relay {}", relay.daemon_url()))?;
    let selected_protocol = response
        .headers()
        .get("sec-websocket-protocol")
        .and_then(|value| value.to_str().ok());
    if selected_protocol != Some(relay_protocol.as_str()) {
        bail!("relay selected an unexpected WebSocket protocol");
    }

    let (mut remote_write, mut remote_read) = remote.split();
    let mut heartbeat_deadline = tokio::time::Instant::now() + DAEMON_HEARTBEAT_INTERVAL;
    let mut awaiting_heartbeat_ack = false;
    let first = loop {
        let message = match tokio::time::timeout_at(heartbeat_deadline, remote_read.next()).await {
            Ok(message) => message.context("relay channel closed")??,
            Err(_) if awaiting_heartbeat_ack => {
                bail!("relay daemon heartbeat was not acknowledged within 10 seconds")
            }
            Err(_) => {
                remote_write
                    .send(tokio_tungstenite::tungstenite::Message::Text(
                        DAEMON_HEARTBEAT.into(),
                    ))
                    .await?;
                awaiting_heartbeat_ack = true;
                heartbeat_deadline = tokio::time::Instant::now() + DAEMON_HEARTBEAT_TIMEOUT;
                continue;
            }
        };
        match message {
            tokio_tungstenite::tungstenite::Message::Ping(value) => {
                remote_write
                    .send(tokio_tungstenite::tungstenite::Message::Pong(value))
                    .await?;
            }
            tokio_tungstenite::tungstenite::Message::Close(_) => return Ok(()),
            tokio_tungstenite::tungstenite::Message::Text(value)
                if value == DAEMON_HEARTBEAT_ACK =>
            {
                awaiting_heartbeat_ack = false;
                heartbeat_deadline = tokio::time::Instant::now() + DAEMON_HEARTBEAT_INTERVAL;
            }
            tokio_tungstenite::tungstenite::Message::Text(value)
                if value == CLIENT_PAIRED_MARKER =>
            {
                break tokio::time::timeout(CLIENT_FIRST_FRAME_TIMEOUT, async {
                    loop {
                        match remote_read.next().await.context("relay channel closed")?? {
                            tokio_tungstenite::tungstenite::Message::Ping(value) => {
                                remote_write
                                    .send(tokio_tungstenite::tungstenite::Message::Pong(value))
                                    .await?;
                            }
                            tokio_tungstenite::tungstenite::Message::Close(_) => {
                                return Ok::<_, anyhow::Error>(None);
                            }
                            tokio_tungstenite::tungstenite::Message::Text(value)
                                if value == DAEMON_HEARTBEAT_ACK => {}
                            message => return Ok::<_, anyhow::Error>(Some(message)),
                        }
                    }
                })
                .await
                .context("relay client did not send its first frame within 10 seconds")??;
            }
            message => break Some(message),
        }
    };
    let Some(first) = first else {
        return Ok(());
    };

    let local_url = format!("ws://{listen}/ws");
    let (local, _) = connect_async(&local_url)
        .await
        .with_context(|| format!("connect local daemon {local_url}"))?;
    tracing::info!(url = %relay.client_url(), "relay connected");

    let (mut local_write, mut local_read) = local.split();
    local_write.send(first).await?;
    tokio::select! {
        result = async {
            while let Some(message) = remote_read.next().await {
                local_write.send(message?).await?;
            }
            Result::<()>::Ok(())
        } => result?,
        result = async {
            while let Some(message) = local_read.next().await {
                remote_write.send(message?).await?;
            }
            Result::<()>::Ok(())
        } => result?,
    }
    Ok(())
}

fn normalize_base_url(raw: &str) -> Result<String> {
    let mut url = Url::parse(raw.trim()).context("invalid relay URL")?;
    match url.scheme() {
        "https" => url.set_scheme("wss").expect("valid scheme"),
        "http" => url.set_scheme("ws").expect("valid scheme"),
        "wss" | "ws" => {}
        scheme => bail!("unsupported relay URL scheme: {scheme}"),
    }
    if url.host_str().is_none() || url.query().is_some() || url.fragment().is_some() {
        bail!("relay URL must contain only a scheme, host, optional port, and path");
    }
    let path = url.path().trim_end_matches('/').to_owned();
    url.set_path(&path);
    Ok(url.to_string().trim_end_matches('/').to_owned())
}

fn random_secret(bytes: usize) -> String {
    let mut value = vec![0_u8; bytes];
    rand::rng().fill_bytes(&mut value);
    URL_SAFE_NO_PAD.encode(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_relay_url() {
        assert_eq!(
            normalize_base_url("https://relay.example/").unwrap(),
            "wss://relay.example"
        );
        assert!(normalize_base_url("ftp://relay.example").is_err());
        assert!(normalize_base_url("https://relay.example?secret=yes").is_err());
    }

    #[test]
    fn configures_a_parseable_pairing_code() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        let (mut config, _) = Config::create(&path, "127.0.0.1:7497".parse().unwrap()).unwrap();
        let code = configure(&mut config, &path, "https://relay.example").unwrap();
        let encoded = code.strip_prefix("riz1.").unwrap();
        let value: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(encoded).unwrap()).unwrap();
        assert_eq!(value["v"], 1);
        assert_eq!(value["name"], config.name);
        assert_eq!(value["url"], config.relay.as_ref().unwrap().client_url());
        assert!(config.verify_token(value["token"].as_str().unwrap()));
        assert_eq!(value["relayToken"], config.relay.as_ref().unwrap().token);
    }
}
