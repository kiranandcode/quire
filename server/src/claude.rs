use futures::StreamExt;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

#[derive(Serialize)]
struct ClaudeRequest {
    model: String,
    max_tokens: u32,
    messages: Vec<ClaudeRawMessage>,
}

/// A message with content as either plain string or multi-part blocks.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct ClaudeRawMessage {
    pub role: String,
    pub content: serde_json::Value, // string or array of content blocks
}

/// Simple text-only message for session history.
#[derive(Clone, Debug)]
pub struct ClaudeMessage {
    pub role: String,
    pub content: String,
}

impl ClaudeMessage {
    pub fn to_raw(&self) -> ClaudeRawMessage {
        ClaudeRawMessage {
            role: self.role.clone(),
            content: serde_json::Value::String(self.content.clone()),
        }
    }
}

/// Build a multi-part user message with text and images.
pub fn build_multipart_message(parts: &[ContentPart]) -> ClaudeRawMessage {
    let blocks: Vec<serde_json::Value> = parts
        .iter()
        .map(|p| match p {
            ContentPart::Text(t) => serde_json::json!({"type": "text", "text": t}),
            ContentPart::ImageBase64 { media_type, data } => serde_json::json!({
                "type": "image",
                "source": {"type": "base64", "media_type": media_type, "data": data}
            }),
        })
        .collect();

    ClaudeRawMessage {
        role: "user".into(),
        content: serde_json::Value::Array(blocks),
    }
}

pub enum ContentPart {
    Text(String),
    ImageBase64 { media_type: String, data: String },
}

#[derive(Deserialize)]
struct ClaudeResponse {
    content: Vec<ContentBlock>,
}

#[derive(Deserialize)]
struct ContentBlock {
    text: Option<String>,
}

pub const DEFAULT_MODEL: &str = "claude-sonnet-4-20250514";

/// Chat with plain text messages (existing sessions).
pub async fn chat(
    api_key: &str,
    messages: &[ClaudeMessage],
    model: &str,
) -> Result<String, String> {
    let raw: Vec<ClaudeRawMessage> = messages.iter().map(|m| m.to_raw()).collect();
    send_request(api_key, &raw, model).await
}

/// Chat with a mixed-content final message (text + images) appended to history.
pub async fn chat_mixed(
    api_key: &str,
    history: &[ClaudeMessage],
    new_message: ClaudeRawMessage,
    model: &str,
) -> Result<String, String> {
    let mut raw: Vec<ClaudeRawMessage> = history.iter().map(|m| m.to_raw()).collect();
    raw.push(new_message);
    send_request(api_key, &raw, model).await
}

async fn send_request(
    api_key: &str,
    messages: &[ClaudeRawMessage],
    model: &str,
) -> Result<String, String> {
    let client = Client::new();

    let req = ClaudeRequest {
        model: model.to_string(),
        max_tokens: 1024,
        messages: messages.to_vec(),
    };

    let resp = client
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(&req)
        .send()
        .await
        .map_err(|e| format!("Request failed: {e}"))?;

    let status = resp.status();
    let body = resp.text().await.map_err(|e| format!("Read body failed: {e}"))?;

    if !status.is_success() {
        return Err(format!("Claude API error {status}: {body}"));
    }

    let parsed: ClaudeResponse =
        serde_json::from_str(&body).map_err(|e| format!("Parse failed: {e}"))?;

    Ok(parsed
        .content
        .iter()
        .filter_map(|b| b.text.as_deref())
        .collect::<Vec<_>>()
        .join(""))
}

#[derive(Serialize)]
struct ClaudeStreamRequest {
    model: String,
    max_tokens: u32,
    stream: bool,
    messages: Vec<ClaudeRawMessage>,
}

/// Stream a Claude response, sending text deltas through the channel.
/// Returns the full accumulated text when done.
pub async fn chat_mixed_stream(
    api_key: &str,
    history: &[ClaudeMessage],
    new_message: ClaudeRawMessage,
    model: &str,
    tx: mpsc::Sender<String>,
) -> Result<String, String> {
    let mut raw: Vec<ClaudeRawMessage> = history.iter().map(|m| m.to_raw()).collect();
    raw.push(new_message);

    let client = Client::new();
    let req = ClaudeStreamRequest {
        model: model.to_string(),
        max_tokens: 1024,
        stream: true,
        messages: raw,
    };

    let resp = client
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(&req)
        .send()
        .await
        .map_err(|e| format!("Request failed: {e}"))?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("Claude API error {status}: {body}"));
    }

    let mut full_text = String::new();
    let mut stream = resp.bytes_stream();
    let mut buf = String::new();

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("Stream read error: {e}"))?;
        buf.push_str(&String::from_utf8_lossy(&chunk));

        // Process complete SSE lines from buffer
        while let Some(pos) = buf.find("\n\n") {
            let event_block = buf[..pos].to_string();
            buf = buf[pos + 2..].to_string();

            // Parse SSE event
            let mut event_type = "";
            let mut data_str = String::new();
            for line in event_block.lines() {
                if let Some(et) = line.strip_prefix("event: ") {
                    event_type = match et.trim() {
                        "content_block_delta" => "content_block_delta",
                        "message_stop" => "message_stop",
                        _ => "",
                    };
                } else if let Some(d) = line.strip_prefix("data: ") {
                    data_str = d.to_string();
                }
            }

            if event_type == "content_block_delta" && !data_str.is_empty() {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&data_str) {
                    if let Some(text) = v["delta"]["text"].as_str() {
                        full_text.push_str(text);
                        let _ = tx.send(text.to_string()).await;
                    }
                }
            }
        }
    }

    Ok(full_text)
}
