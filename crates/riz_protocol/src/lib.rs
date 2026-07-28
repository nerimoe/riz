use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_ATTACHMENT_BYTES: usize = 25 * 1024 * 1024;
pub const FILE_CHUNK_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Envelope {
    pub v: u16,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub daemon_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seq: Option<i64>,
    #[serde(default)]
    pub payload: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ProtocolError>,
}

impl Envelope {
    pub fn response(request: &Self, daemon_id: Uuid, payload: Value) -> Self {
        Self {
            v: PROTOCOL_VERSION,
            kind: "response".into(),
            request_id: request.request_id.clone(),
            daemon_id: Some(daemon_id),
            seq: None,
            payload,
            error: None,
        }
    }

    pub fn failure(
        request: &Self,
        daemon_id: Uuid,
        code: &str,
        message: impl Into<String>,
    ) -> Self {
        Self {
            v: PROTOCOL_VERSION,
            kind: "response".into(),
            request_id: request.request_id.clone(),
            daemon_id: Some(daemon_id),
            seq: None,
            payload: Value::Null,
            error: Some(ProtocolError {
                code: code.into(),
                message: message.into(),
                details: None,
            }),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Queued,
    Running,
    WaitingPermission,
    WaitingInput,
    Completed,
    Failed,
    Cancelled,
    Interrupted,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCapabilities {
    pub steering: bool,
    pub image_input: bool,
    pub image_output: bool,
    pub thinking: bool,
    pub tools: bool,
    pub permissions: bool,
    pub resume: bool,
    pub slash_commands: bool,
    pub quota: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum BinaryChannel {
    Attachment = 1,
    File = 2,
    Terminal = 3,
}

pub fn encode_binary(channel: BinaryChannel, id: Uuid, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(17 + payload.len());
    out.push(channel as u8);
    out.extend_from_slice(id.as_bytes());
    out.extend_from_slice(payload);
    out
}

pub fn decode_binary(frame: &[u8]) -> Option<(BinaryChannel, Uuid, &[u8])> {
    if frame.len() < 17 {
        return None;
    }
    let channel = match frame[0] {
        1 => BinaryChannel::Attachment,
        2 => BinaryChannel::File,
        3 => BinaryChannel::Terminal,
        _ => return None,
    };
    Some((channel, Uuid::from_slice(&frame[1..17]).ok()?, &frame[17..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_frame_round_trips() {
        let id = Uuid::new_v4();
        let frame = encode_binary(BinaryChannel::Terminal, id, b"hello");
        let (channel, decoded, body) = decode_binary(&frame).unwrap();
        assert_eq!(channel, BinaryChannel::Terminal);
        assert_eq!(decoded, id);
        assert_eq!(body, b"hello");
    }
}
