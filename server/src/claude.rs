use reqwest::Client;
use serde::{Deserialize, Serialize};

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

/// Chat with plain text messages (existing sessions).
pub async fn chat(
    api_key: &str,
    messages: &[ClaudeMessage],
) -> Result<String, String> {
    let raw: Vec<ClaudeRawMessage> = messages.iter().map(|m| m.to_raw()).collect();
    send_request(api_key, &raw).await
}

/// Chat with a mixed-content final message (text + images) appended to history.
pub async fn chat_mixed(
    api_key: &str,
    history: &[ClaudeMessage],
    new_message: ClaudeRawMessage,
) -> Result<String, String> {
    let mut raw: Vec<ClaudeRawMessage> = history.iter().map(|m| m.to_raw()).collect();
    raw.push(new_message);
    send_request(api_key, &raw).await
}

async fn send_request(
    api_key: &str,
    messages: &[ClaudeRawMessage],
) -> Result<String, String> {
    let client = Client::new();

    let req = ClaudeRequest {
        model: "claude-sonnet-4-20250514".to_string(),
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
