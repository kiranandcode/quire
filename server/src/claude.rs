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

pub const DEFAULT_MODEL: &str = "claude-sonnet-4-20250514";

#[derive(Deserialize)]
struct ClaudeResponse {
    content: Vec<ContentBlock>,
}

#[derive(Deserialize)]
struct ContentBlock {
    text: Option<String>,
}

/// Chat with a mixed-content message (text + images) appended to history (non-streaming).
pub async fn chat_mixed(
    api_key: &str,
    history: &[ClaudeMessage],
    new_message: ClaudeRawMessage,
    model: &str,
) -> Result<String, String> {
    let mut raw: Vec<ClaudeRawMessage> = history.iter().map(|m| m.to_raw()).collect();
    raw.push(new_message);

    let client = Client::new();
    let req = ClaudeRequest {
        model: model.to_string(),
        max_tokens: 4096,
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

// --- Tool use support ---

pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub input: serde_json::Value,
}

/// Result of a single streaming call — text + any tool calls.
pub struct StreamResult {
    pub text: String,
    pub tool_calls: Vec<ToolCall>,
    /// Full assistant content blocks (text + tool_use) for building continuation messages.
    pub assistant_blocks: Vec<serde_json::Value>,
}

#[derive(Serialize)]
struct ClaudeStreamRequest {
    model: String,
    max_tokens: u32,
    stream: bool,
    messages: Vec<ClaudeRawMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    system: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tools: Option<Vec<serde_json::Value>>,
}

/// Stream a single Claude request. Returns accumulated text + tool calls.
/// Text deltas are sent through `tx` for real-time streaming.
pub async fn stream_request(
    api_key: &str,
    messages: Vec<ClaudeRawMessage>,
    model: &str,
    system: Option<&str>,
    tools: Option<&[serde_json::Value]>,
    tx: &mpsc::Sender<String>,
) -> Result<StreamResult, String> {
    let client = Client::new();
    let req = ClaudeStreamRequest {
        model: model.to_string(),
        max_tokens: 4096,
        stream: true,
        messages,
        system: system.map(|s| s.to_string()),
        tools: tools.map(|t| t.to_vec()),
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
    let mut tool_calls = Vec::new();
    let mut assistant_blocks = Vec::new();
    let mut stream = resp.bytes_stream();
    let mut buf = String::new();

    // Tool use accumulation state
    let mut current_tool_id = String::new();
    let mut current_tool_name = String::new();
    let mut current_tool_input = String::new();
    let mut in_tool_use = false;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("Stream read error: {e}"))?;
        buf.push_str(&String::from_utf8_lossy(&chunk));

        while let Some(pos) = buf.find("\n\n") {
            let event_block = buf[..pos].to_string();
            buf = buf[pos + 2..].to_string();

            let mut event_type = String::new();
            let mut data_str = String::new();
            for line in event_block.lines() {
                if let Some(et) = line.strip_prefix("event: ") {
                    event_type = et.trim().to_string();
                } else if let Some(d) = line.strip_prefix("data: ") {
                    data_str = d.to_string();
                }
            }

            if data_str.is_empty() {
                continue;
            }

            let v: serde_json::Value = match serde_json::from_str(&data_str) {
                Ok(v) => v,
                Err(_) => continue,
            };

            match event_type.as_str() {
                "content_block_start" => {
                    let block = &v["content_block"];
                    if block["type"].as_str() == Some("tool_use") {
                        in_tool_use = true;
                        current_tool_id = block["id"].as_str().unwrap_or("").to_string();
                        current_tool_name = block["name"].as_str().unwrap_or("").to_string();
                        current_tool_input.clear();
                    }
                }
                "content_block_delta" => {
                    if in_tool_use {
                        if let Some(json_frag) = v["delta"]["partial_json"].as_str() {
                            current_tool_input.push_str(json_frag);
                        }
                    } else if let Some(text) = v["delta"]["text"].as_str() {
                        full_text.push_str(text);
                        let _ = tx.send(text.to_string()).await;
                    }
                }
                "content_block_stop" => {
                    if in_tool_use {
                        let input: serde_json::Value =
                            serde_json::from_str(&current_tool_input).unwrap_or_default();
                        assistant_blocks.push(serde_json::json!({
                            "type": "tool_use",
                            "id": &current_tool_id,
                            "name": &current_tool_name,
                            "input": &input,
                        }));
                        tool_calls.push(ToolCall {
                            id: current_tool_id.clone(),
                            name: current_tool_name.clone(),
                            input,
                        });
                        in_tool_use = false;
                    }
                }
                _ => {}
            }
        }
    }

    // Add text block if we accumulated any
    if !full_text.is_empty() {
        assistant_blocks.insert(0, serde_json::json!({
            "type": "text",
            "text": &full_text,
        }));
    }

    Ok(StreamResult {
        text: full_text,
        tool_calls,
        assistant_blocks,
    })
}
