mod claude;
mod log;
mod ocr;
mod render;

use axum::{
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode},
    routing::{get, post},
    Json, Router,
};
use claude::ClaudeMessage;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use tower_http::cors::CorsLayer;

struct AppState {
    password: Option<String>,
    anthropic_key: String,
    ocr_port: u16,
    sessions: Mutex<HashMap<String, Vec<ClaudeMessage>>>,
}

#[derive(Deserialize)]
struct StrokePoint {
    x: f64,
    y: f64,
    #[serde(default)]
    p: Option<f64>,
}

// --- OCR endpoint ---

#[derive(Deserialize)]
struct OcrRequest {
    strokes: Vec<Vec<StrokePoint>>,
}

#[derive(Serialize)]
struct OcrResponse {
    text: String,
}

async fn ocr_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<OcrRequest>,
) -> Result<Json<OcrResponse>, StatusCode> {
    check_auth(&state, &headers)?;

    if req.strokes.is_empty() {
        return Ok(Json(OcrResponse { text: String::new() }));
    }

    log::log("ocr_request", &serde_json::json!({"stroke_count": req.strokes.len()}));
    let img = render::strokes_to_image(&req.strokes);
    let text = ocr::recognize(&img, state.ocr_port).await.map_err(|e| {
        log::log("ocr_error", &serde_json::json!({"error": e.to_string()}));
        StatusCode::INTERNAL_SERVER_ERROR
    })?;
    log::log("ocr_result", &serde_json::json!({"text": &text}));

    Ok(Json(OcrResponse { text }))
}

// --- Chat endpoint: OCR strokes → text → Claude → response ---

#[derive(Deserialize)]
struct ChatRequest {
    strokes: Vec<Vec<StrokePoint>>,
    #[serde(default)]
    session_id: Option<String>,
}

#[derive(Serialize)]
struct ChatResponse {
    text: String,
    ocr_text: String,
    session_id: String,
}

async fn chat_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<ChatRequest>,
) -> Result<Json<ChatResponse>, (StatusCode, String)> {
    check_auth(&state, &headers).map_err(|s| (s, "Unauthorized".into()))?;

    if req.strokes.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "No strokes".into()));
    }

    // OCR
    log::log("chat_request", &serde_json::json!({"stroke_count": req.strokes.len(), "session_id": &req.session_id}));
    let img = render::strokes_to_image(&req.strokes);
    let ocr_text = ocr::recognize(&img, state.ocr_port).await.map_err(|e| {
        log::log("chat_ocr_error", &serde_json::json!({"error": e.to_string()}));
        (StatusCode::INTERNAL_SERVER_ERROR, format!("OCR failed: {e}"))
    })?;
    log::log("chat_ocr_result", &serde_json::json!({"text": &ocr_text}));

    if ocr_text.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "OCR returned empty".into()));
    }

    // Session management
    let session_id = req
        .session_id
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    let mut sessions = state.sessions.lock().await;
    let history = sessions.entry(session_id.clone()).or_default();

    // Add user message
    history.push(ClaudeMessage {
        role: "user".into(),
        content: ocr_text.clone(),
    });

    // Call Claude
    let response_text = claude::chat(&state.anthropic_key, history)
        .await
        .map_err(|e| {
            history.pop();
            log::log("chat_claude_error", &serde_json::json!({"error": e.to_string()}));
            (StatusCode::INTERNAL_SERVER_ERROR, format!("Claude failed: {e}"))
        })?;
    log::log("chat_claude_response", &serde_json::json!({"text": &response_text, "session_id": &session_id}));

    history.push(ClaudeMessage {
        role: "assistant".into(),
        content: response_text.clone(),
    });

    Ok(Json(ChatResponse {
        text: response_text,
        ocr_text,
        session_id,
    }))
}

// --- Auth ---

fn check_auth(state: &AppState, headers: &HeaderMap) -> Result<(), StatusCode> {
    if let Some(ref expected) = state.password {
        let token = headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "));
        match token {
            Some(t) if t == expected => Ok(()),
            _ => Err(StatusCode::UNAUTHORIZED),
        }
    } else {
        Ok(())
    }
}

async fn debug_handler(Json(payload): Json<serde_json::Value>) -> StatusCode {
    log::log("client_debug", &payload);
    StatusCode::OK
}

async fn screenshot_handler(body: Bytes) -> StatusCode {
    let ts = chrono::Local::now().format("%Y%m%d_%H%M%S");
    let dir = "quire_screenshots";
    let _ = std::fs::create_dir_all(dir);
    let path = format!("{dir}/screenshot_{ts}.png");
    match std::fs::write(&path, &body) {
        Ok(_) => {
            log::log("screenshot_saved", &serde_json::json!({"path": &path, "bytes": body.len()}));
            StatusCode::OK
        }
        Err(e) => {
            log::log("screenshot_error", &serde_json::json!({"error": e.to_string()}));
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

async fn canvas_dump_handler(Json(payload): Json<serde_json::Value>) -> StatusCode {
    let ts = chrono::Local::now().format("%Y%m%d_%H%M%S");
    let dir = "quire_dumps";
    let _ = std::fs::create_dir_all(dir);
    let path = format!("{dir}/canvas_{ts}.json");
    match std::fs::write(&path, serde_json::to_string_pretty(&payload).unwrap_or_default()) {
        Ok(_) => {
            log::log("canvas_dump_saved", &serde_json::json!({"path": &path}));
            StatusCode::OK
        }
        Err(e) => {
            log::log("canvas_dump_error", &serde_json::json!({"error": e.to_string()}));
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

// --- Detect endpoint ---

#[derive(Deserialize)]
struct DetectRequest {
    strokes: Vec<Vec<StrokePoint>>,
}

async fn detect_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<DetectRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    check_auth(&state, &headers).map_err(|s| (s, "Unauthorized".into()))?;

    if req.strokes.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "No strokes".into()));
    }

    let img = render::strokes_to_image(&req.strokes);
    let regions = ocr::detect(&img, state.ocr_port).await.map_err(|e| {
        eprintln!("Detect error: {e}");
        (StatusCode::INTERNAL_SERVER_ERROR, format!("Detect failed: {e}"))
    })?;

    // Also save the rendered image dimensions for coordinate mapping
    let result = serde_json::json!({
        "regions": regions.iter().map(|r| {
            let mut obj = serde_json::json!({"type": r.region_type});
            if let Some(ref content) = r.content {
                obj["content"] = serde_json::json!(content);
            }
            if let Some(ref bbox) = r.bbox {
                obj["bbox"] = serde_json::json!(bbox);
            }
            obj
        }).collect::<Vec<_>>(),
        "image_width": img.width(),
        "image_height": img.height(),
    });

    Ok(Json(result))
}

async fn health() -> &'static str {
    "ok"
}

#[tokio::main]
async fn main() {
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8080);

    let ocr_port: u16 = std::env::var("OCR_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8090);

    let password = std::env::var("QUIRE_PASSWORD").ok();

    let anthropic_key = std::env::var("ANTHROPIC_API_KEY")
        .expect("ANTHROPIC_API_KEY must be set");

    let state = Arc::new(AppState {
        password,
        anthropic_key,
        ocr_port,
        sessions: Mutex::new(HashMap::new()),
    });

    let app = Router::new()
        .route("/ocr", post(ocr_handler))
        .route("/chat", post(chat_handler))
        .route("/detect", post(detect_handler))
        .route("/debug", post(debug_handler))
        .route("/screenshot", post(screenshot_handler))
        .route("/canvas-dump", post(canvas_dump_handler))
        .route("/health", get(health))
        .layer(CorsLayer::permissive())
        .with_state(state);

    let addr = format!("0.0.0.0:{port}");
    println!("Quire server listening on {addr}");

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
