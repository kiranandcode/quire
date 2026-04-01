use reqwest::Client;
use serde::{Deserialize, Serialize};

#[derive(Serialize)]
struct ClaudeRequest {
    model: String,
    max_tokens: u32,
    messages: Vec<ClaudeMessage>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct ClaudeMessage {
    pub role: String,
    pub content: String,
}

#[derive(Deserialize)]
struct ClaudeResponse {
    content: Vec<ContentBlock>,
}

#[derive(Deserialize)]
struct ContentBlock {
    text: Option<String>,
}

pub async fn chat(
    api_key: &str,
    messages: &[ClaudeMessage],
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

    let text = parsed
        .content
        .iter()
        .filter_map(|b| b.text.as_deref())
        .collect::<Vec<_>>()
        .join("");

    Ok(text)
}
