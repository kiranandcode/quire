mod claude;
mod log;
mod ocr;
mod render;

use axum::{
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::sse::{Event, Sse},
    routing::{get, post},
    Json, Router,
};
use claude::ClaudeMessage;
use futures::stream::Stream;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_stream::wrappers::ReceiverStream;
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
    let render = render::strokes_to_image(&req.strokes);
    let text = ocr::recognize(&render.image, state.ocr_port).await.map_err(|e| {
        log::log("ocr_error", &serde_json::json!({"error": e.to_string()}));
        StatusCode::INTERNAL_SERVER_ERROR
    })?;
    log::log("ocr_result", &serde_json::json!({"text": &text}));

    Ok(Json(OcrResponse { text }))
}

// --- Chat endpoint: OCR strokes → text → Claude → response ---

#[derive(Deserialize)]
struct PreClassifiedRegion {
    #[serde(rename = "type")]
    region_type: String,
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    world_bbox: Option<[f64; 4]>,
}

#[derive(Deserialize)]
struct AnnotationContext {
    #[serde(default)]
    original_response: Option<String>,
    #[serde(default)]
    original_image_b64: Option<String>,
}

#[derive(Deserialize)]
struct ChatRequest {
    strokes: Vec<Vec<StrokePoint>>,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    regions: Option<Vec<PreClassifiedRegion>>,
    #[serde(default)]
    annotation_context: Option<AnnotationContext>,
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

    log::log("chat_request", &serde_json::json!({"stroke_count": req.strokes.len(), "session_id": &req.session_id}));

    // Render strokes to image
    let render = render::strokes_to_image(&req.strokes);

    // Detect text vs image regions via bbox model
    let regions = ocr::detect(&render.image, state.ocr_port).await.map_err(|e| {
        log::log("chat_detect_error", &serde_json::json!({"error": e.to_string()}));
        // Fallback: try pure OCR if detect fails
        e
    });

    // Build message parts based on detected regions
    let (parts, ocr_text) = if let Ok(regions) = regions {
        let mut parts = Vec::new();
        let mut all_text = String::new();

        let has_images = regions.iter().any(|r| r.region_type == "image");
        log::log("chat_detect_result", &serde_json::json!({
            "region_count": regions.len(),
            "has_images": has_images,
            "regions": regions.iter().map(|r| &r.region_type).collect::<Vec<_>>(),
        }));

        for region in &regions {
            match region.region_type.as_str() {
                "text" => {
                    if let Some(ref text) = region.content {
                        if !text.is_empty() {
                            all_text.push_str(text);
                            all_text.push(' ');
                            parts.push(claude::ContentPart::Text(text.clone()));
                        }
                    }
                }
                "image" => {
                    if let Some(bbox) = &region.bbox {
                        // Crop the image region and encode as base64 PNG
                        let cropped = render::crop_image(&render.image, bbox[0], bbox[1], bbox[2], bbox[3]);
                        let mut buf = Vec::new();
                        use std::io::Cursor;
                        if cropped.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png).is_ok() {
                            let b64 = base64::Engine::encode(
                                &base64::engine::general_purpose::STANDARD, &buf
                            );
                            parts.push(claude::ContentPart::Text(
                                "[The user drew a diagram/image here:]".into()
                            ));
                            parts.push(claude::ContentPart::ImageBase64 {
                                media_type: "image/png".into(),
                                data: b64,
                            });
                        }
                    }
                }
                _ => {}
            }
        }

        if parts.is_empty() {
            return Err((StatusCode::BAD_REQUEST, "No content detected".into()));
        }

        (parts, all_text.trim().to_string())
    } else {
        // Fallback to pure OCR
        let ocr_text = ocr::recognize(&render.image, state.ocr_port).await.map_err(|e| {
            log::log("chat_ocr_error", &serde_json::json!({"error": e.to_string()}));
            (StatusCode::INTERNAL_SERVER_ERROR, format!("OCR failed: {e}"))
        })?;
        log::log("chat_ocr_fallback", &serde_json::json!({"text": &ocr_text}));
        if ocr_text.is_empty() {
            return Err((StatusCode::BAD_REQUEST, "OCR returned empty".into()));
        }
        (vec![claude::ContentPart::Text(ocr_text.clone())], ocr_text)
    };

    log::log("chat_ocr_result", &serde_json::json!({"text": &ocr_text}));

    // Session management
    let session_id = req
        .session_id
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    let mut sessions = state.sessions.lock().await;
    let history = sessions.entry(session_id.clone()).or_default();

    // Build the mixed-content message
    let user_msg = claude::build_multipart_message(&parts);

    let model = req.model.as_deref().unwrap_or(claude::DEFAULT_MODEL);

    // Call Claude with history + new mixed message
    let response_text = claude::chat_mixed(&state.anthropic_key, history, user_msg, model)
        .await
        .map_err(|e| {
            log::log("chat_claude_error", &serde_json::json!({"error": e.to_string()}));
            (StatusCode::INTERNAL_SERVER_ERROR, format!("Claude failed: {e}"))
        })?;
    log::log("chat_claude_response", &serde_json::json!({"text": &response_text, "session_id": &session_id}));

    // Store text summary in history for future context
    history.push(ClaudeMessage {
        role: "user".into(),
        content: if ocr_text.is_empty() { "[sent an image]".into() } else { ocr_text.clone() },
    });
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

// --- Streaming Chat endpoint ---

async fn chat_stream_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<ChatRequest>,
) -> Result<Sse<impl Stream<Item = Result<Event, std::convert::Infallible>>>, (StatusCode, String)> {
    check_auth(&state, &headers).map_err(|s| (s, "Unauthorized".into()))?;

    if req.strokes.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "No strokes".into()));
    }

    log::log("chat_stream_request", &serde_json::json!({"stroke_count": req.strokes.len(), "session_id": &req.session_id}));

    // Render strokes to image
    let render = render::strokes_to_image(&req.strokes);

    let mut region_info: Vec<serde_json::Value> = Vec::new();

    let (mut parts, ocr_text) = if let Some(pre_regions) = &req.regions {
        // Use pre-classified regions from client (user reviewed/modified)
        log::log("chat_stream_preclassified", &serde_json::json!({
            "region_count": pre_regions.len(),
        }));
        let mut parts = Vec::new();
        let mut all_text = String::new();

        for region in pre_regions {
            match region.region_type.as_str() {
                "text" => {
                    if let Some(ref text) = region.content {
                        if !text.is_empty() {
                            all_text.push_str(text);
                            all_text.push(' ');
                            parts.push(claude::ContentPart::Text(text.clone()));
                        }
                    }
                }
                "image" => {
                    if let Some(ref wb) = region.world_bbox {
                        region_info.push(serde_json::json!({
                            "type": "image",
                            "world_bbox": wb,
                        }));
                        let pixel_bbox = render.world_to_pixel(wb);
                        let cropped = render::crop_image(
                            &render.image, pixel_bbox[0], pixel_bbox[1], pixel_bbox[2], pixel_bbox[3]
                        );
                        let mut buf = Vec::new();
                        use std::io::Cursor;
                        if cropped.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png).is_ok() {
                            let b64 = base64::Engine::encode(
                                &base64::engine::general_purpose::STANDARD, &buf
                            );
                            parts.push(claude::ContentPart::Text(
                                "[The user drew a diagram/image here:]".into()
                            ));
                            parts.push(claude::ContentPart::ImageBase64 {
                                media_type: "image/png".into(),
                                data: b64,
                            });
                        }
                    }
                }
                _ => {}
            }
        }

        if parts.is_empty() {
            return Err((StatusCode::BAD_REQUEST, "No content in regions".into()));
        }
        (parts, all_text.trim().to_string())
    } else {
        // Auto-detect regions (original flow)
        let regions = ocr::detect(&render.image, state.ocr_port).await.map_err(|e| {
            log::log("chat_detect_error", &serde_json::json!({"error": e.to_string()}));
            e
        });

        if let Ok(regions) = regions {
            let mut parts = Vec::new();
            let mut all_text = String::new();

            log::log("chat_detect_result", &serde_json::json!({
                "region_count": regions.len(),
                "regions": regions.iter().map(|r| &r.region_type).collect::<Vec<_>>(),
            }));

            for region in &regions {
                match region.region_type.as_str() {
                    "text" => {
                        if let Some(ref text) = region.content {
                            if !text.is_empty() {
                                all_text.push_str(text);
                                all_text.push(' ');
                                parts.push(claude::ContentPart::Text(text.clone()));
                            }
                        }
                    }
                    "image" => {
                        if let Some(bbox) = &region.bbox {
                            region_info.push(serde_json::json!({
                                "type": "image",
                                "world_bbox": render.pixel_to_world(bbox),
                            }));
                            let cropped = render::crop_image(&render.image, bbox[0], bbox[1], bbox[2], bbox[3]);
                            let mut buf = Vec::new();
                            use std::io::Cursor;
                            if cropped.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png).is_ok() {
                                let b64 = base64::Engine::encode(
                                    &base64::engine::general_purpose::STANDARD, &buf
                                );
                                parts.push(claude::ContentPart::Text(
                                    "[The user drew a diagram/image here:]".into()
                                ));
                                parts.push(claude::ContentPart::ImageBase64 {
                                    media_type: "image/png".into(),
                                    data: b64,
                                });
                            }
                        }
                    }
                    _ => {}
                }
            }

            if parts.is_empty() {
                return Err((StatusCode::BAD_REQUEST, "No content detected".into()));
            }
            (parts, all_text.trim().to_string())
        } else {
            let ocr_text = ocr::recognize(&render.image, state.ocr_port).await.map_err(|e| {
                (StatusCode::INTERNAL_SERVER_ERROR, format!("OCR failed: {e}"))
            })?;
            if ocr_text.is_empty() {
                return Err((StatusCode::BAD_REQUEST, "OCR returned empty".into()));
            }
            (vec![claude::ContentPart::Text(ocr_text.clone())], ocr_text)
        }
    };

    // Session management
    let session_id = req
        .session_id
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    let history = {
        let sessions = state.sessions.lock().await;
        sessions.get(&session_id).cloned().unwrap_or_default()
    };

    // Prepend annotation context if present
    if let Some(ref ctx) = req.annotation_context {
        let mut annotation_parts = Vec::new();

        if let Some(ref original) = ctx.original_response {
            annotation_parts.push(claude::ContentPart::Text(format!(
                "[The user is annotating your previous response. They drew on or near it with their stylus to give feedback.]\n\n\
                 Your previous response:\n\"\"\"\n{}\n\"\"\"",
                original
            )));
        }

        if let Some(ref img_b64) = ctx.original_image_b64 {
            annotation_parts.push(claude::ContentPart::Text(
                "[The user annotated your previously rendered diagram (shown below).]".into()
            ));
            annotation_parts.push(claude::ContentPart::ImageBase64 {
                media_type: "image/png".into(),
                data: img_b64.clone(),
            });
        }

        annotation_parts.push(claude::ContentPart::Text(
            "The user's annotation (handwriting image + OCR text):".into()
        ));
        // Always include the full rendered strokes image so arrows/drawings aren't lost
        {
            let mut buf = Vec::new();
            use std::io::Cursor;
            if render.image.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png).is_ok() {
                let b64 = base64::Engine::encode(
                    &base64::engine::general_purpose::STANDARD, &buf
                );
                annotation_parts.push(claude::ContentPart::ImageBase64 {
                    media_type: "image/png".into(),
                    data: b64,
                });
            }
        }
        annotation_parts.extend(parts);
        parts = annotation_parts;

        log::log("annotation_send", &serde_json::json!({
            "has_original_response": ctx.original_response.is_some(),
            "has_original_image": ctx.original_image_b64.is_some(),
        }));
    }

    let user_msg = claude::build_multipart_message(&parts);

    // SSE output channel
    let (sse_tx, sse_rx) = tokio::sync::mpsc::channel::<Result<Event, std::convert::Infallible>>(64);

    let init_event = Event::default()
        .event("metadata")
        .data(serde_json::json!({
            "session_id": &session_id,
            "ocr_text": &ocr_text,
            "regions": region_info,
        }).to_string());
    let _ = sse_tx.send(Ok(init_event)).await;

    // Spawn task to call Claude with tool use loop
    let api_key = state.anthropic_key.clone();
    let model = req.model.as_deref().unwrap_or(claude::DEFAULT_MODEL).to_string();
    let session_id_clone = session_id.clone();
    let ocr_text_clone = ocr_text.clone();
    let state_clone = state.clone();
    tokio::spawn(async move {
        let result = run_claude_with_tools(
            &api_key,
            &history,
            user_msg,
            &model,
            &sse_tx,
        ).await;

        match result {
            Ok(full_text) => {
                log::log("chat_stream_response", &serde_json::json!({
                    "text": &full_text, "session_id": &session_id_clone
                }));
                let mut sessions = state_clone.sessions.lock().await;
                let hist = sessions.entry(session_id_clone).or_default();
                hist.push(ClaudeMessage {
                    role: "user".into(),
                    content: if ocr_text_clone.is_empty() { "[sent an image]".into() } else { ocr_text_clone },
                });
                hist.push(ClaudeMessage {
                    role: "assistant".into(),
                    content: full_text,
                });
                let _ = sse_tx.send(Ok(Event::default().event("done").data(""))).await;
            }
            Err(e) => {
                log::log("chat_stream_error", &serde_json::json!({"error": &e}));
                let _ = sse_tx.send(Ok(Event::default().event("error").data(e))).await;
            }
        }
    });

    let stream = ReceiverStream::new(sse_rx);
    Ok(Sse::new(stream))
}

// --- Claude tool use loop ---

const SYSTEM_PROMPT: &str = "\
You are an AI assistant on an e-ink tablet. The user writes with a stylus and you see their handwriting via OCR text and/or images of their drawings.

IMPORTANT: When you need to show any mathematical notation, equations, typing rules, diagrams, plots, or structured visual content, you MUST use the render_diagram tool. Never include LaTeX, SVG, or code blocks containing visual/mathematical content inline in your text response. Your text should only contain prose — all visual content goes through render_diagram.

Keep responses concise — this is an e-ink display with limited space.";

fn render_diagram_tool() -> serde_json::Value {
    serde_json::json!({
        "name": "render_diagram",
        "description": "Render LaTeX or SVG content as a PNG image displayed on the user's e-ink canvas. Use this for ALL mathematical notation, equations, typing rules, diagrams, plots, tikz pictures, or any structured visual content. Never include such content inline as text.",
        "input_schema": {
            "type": "object",
            "properties": {
                "type": {
                    "type": "string",
                    "enum": ["latex", "svg"],
                    "description": "The content type to render"
                },
                "content": {
                    "type": "string",
                    "description": "The LaTeX or SVG content. For LaTeX: provide the body only (no \\documentclass or \\begin{document}). Packages amsmath, amssymb, mathtools, tikz, pgfplots, bussproofs are available."
                }
            },
            "required": ["type", "content"]
        }
    })
}

/// Execute a render_diagram tool call. Returns PNG bytes.
fn execute_render_tool(input: &serde_json::Value) -> Result<Vec<u8>, String> {
    let render_type = input["type"].as_str().unwrap_or("latex");
    let content = input["content"].as_str().unwrap_or("");

    match render_type {
        "latex" => render::render_latex(content),
        "svg" => render::render_svg(content),
        _ => Err(format!("Unknown render type: {render_type}")),
    }
}

/// Run Claude with the render_diagram tool, handling the tool use loop.
async fn run_claude_with_tools(
    api_key: &str,
    history: &[ClaudeMessage],
    user_msg: claude::ClaudeRawMessage,
    model: &str,
    sse_tx: &tokio::sync::mpsc::Sender<Result<Event, std::convert::Infallible>>,
) -> Result<String, String> {
    let tools = vec![render_diagram_tool()];
    let (text_tx, mut text_rx) = tokio::sync::mpsc::channel::<String>(64);

    // Forward text deltas to SSE
    let sse_fwd = sse_tx.clone();
    let fwd_task = tokio::spawn(async move {
        while let Some(delta) = text_rx.recv().await {
            let event = Event::default().event("delta").data(delta);
            if sse_fwd.send(Ok(event)).await.is_err() {
                break;
            }
        }
    });

    // Build initial messages
    let mut messages: Vec<claude::ClaudeRawMessage> =
        history.iter().map(|m| m.to_raw()).collect();
    messages.push(user_msg);

    let mut full_text = String::new();

    // Tool use loop (max 5 rounds to prevent infinite loops)
    for round in 0..5 {
        let result = claude::stream_request(
            api_key,
            messages.clone(),
            model,
            Some(SYSTEM_PROMPT),
            Some(&tools),
            &text_tx,
        ).await?;

        full_text.push_str(&result.text);

        if result.tool_calls.is_empty() {
            break;
        }

        log::log("tool_use_round", &serde_json::json!({
            "round": round,
            "tool_calls": result.tool_calls.len(),
        }));

        // Build assistant message with all content blocks
        messages.push(claude::ClaudeRawMessage {
            role: "assistant".into(),
            content: serde_json::Value::Array(result.assistant_blocks),
        });

        // Execute each tool call and build tool results
        let mut tool_results = Vec::new();
        for tc in &result.tool_calls {
            if tc.name == "render_diagram" {
                log::log("render_tool_call", &serde_json::json!({
                    "type": tc.input["type"],
                    "content_len": tc.input["content"].as_str().map(|s| s.len()),
                }));

                match tokio::task::spawn_blocking({
                    let input = tc.input.clone();
                    move || execute_render_tool(&input)
                }).await {
                    Ok(Ok(png_bytes)) => {
                        log::log("render_tool_success", &serde_json::json!({
                            "png_bytes": png_bytes.len(),
                        }));

                        // Send image to client via SSE
                        let b64 = base64::Engine::encode(
                            &base64::engine::general_purpose::STANDARD, &png_bytes
                        );
                        let _ = sse_tx.send(Ok(
                            Event::default().event("image").data(b64)
                        )).await;

                        tool_results.push(serde_json::json!({
                            "type": "tool_result",
                            "tool_use_id": tc.id,
                            "content": "Image rendered and displayed to user successfully."
                        }));
                    }
                    Ok(Err(e)) => {
                        log::log("render_tool_error", &serde_json::json!({"error": &e}));

                        // Notify client about the error (truncate for display)
                        let snippet = if e.len() > 120 { &e[..120] } else { &e };
                        let _ = sse_tx.send(Ok(
                            Event::default().event("render_error").data(
                                serde_json::json!({"error": snippet, "round": round}).to_string()
                            )
                        )).await;

                        tool_results.push(serde_json::json!({
                            "type": "tool_result",
                            "tool_use_id": tc.id,
                            "is_error": true,
                            "content": format!("Render failed: {e}")
                        }));
                    }
                    Err(e) => {
                        tool_results.push(serde_json::json!({
                            "type": "tool_result",
                            "tool_use_id": tc.id,
                            "is_error": true,
                            "content": format!("Spawn error: {e}")
                        }));
                    }
                }
            }
        }

        // Add tool results as user message
        messages.push(claude::ClaudeRawMessage {
            role: "user".into(),
            content: serde_json::Value::Array(tool_results),
        });
    }

    drop(text_tx);
    let _ = fwd_task.await;

    Ok(full_text)
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

// --- Render endpoint (LaTeX/SVG → PNG) ---

#[derive(Deserialize)]
struct RenderRequest {
    #[serde(rename = "type")]
    render_type: String,
    content: String,
}

async fn render_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<RenderRequest>,
) -> Result<Bytes, (StatusCode, String)> {
    check_auth(&state, &headers).map_err(|s| (s, "Unauthorized".into()))?;

    log::log("render_request", &serde_json::json!({"type": &req.render_type, "content_len": req.content.len()}));

    let png_bytes = match req.render_type.as_str() {
        "latex" => tokio::task::spawn_blocking(move || render::render_latex(&req.content))
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("spawn: {e}")))?,
        "svg" => tokio::task::spawn_blocking(move || render::render_svg(&req.content))
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("spawn: {e}")))?,
        _ => Err(format!("Unknown render type: {}", req.render_type)),
    }
    .map_err(|e| {
        log::log("render_error", &serde_json::json!({"error": &e}));
        (StatusCode::INTERNAL_SERVER_ERROR, e)
    })?;

    log::log("render_success", &serde_json::json!({"type": &req.render_type, "png_bytes": png_bytes.len()}));
    Ok(Bytes::from(png_bytes))
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

    let render = render::strokes_to_image(&req.strokes);
    let regions = ocr::detect(&render.image, state.ocr_port).await.map_err(|e| {
        eprintln!("Detect error: {e}");
        (StatusCode::INTERNAL_SERVER_ERROR, format!("Detect failed: {e}"))
    })?;

    let result = serde_json::json!({
        "regions": regions.iter().map(|r| {
            let mut obj = serde_json::json!({"type": r.region_type});
            if let Some(ref content) = r.content {
                obj["content"] = serde_json::json!(content);
            }
            if let Some(ref bbox) = r.bbox {
                obj["bbox"] = serde_json::json!(bbox);
                obj["world_bbox"] = serde_json::json!(render.pixel_to_world(bbox));
            }
            obj
        }).collect::<Vec<_>>(),
        "image_width": render.image.width(),
        "image_height": render.image.height(),
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
        .route("/chat/stream", post(chat_stream_handler))
        .route("/detect", post(detect_handler))
        .route("/render", post(render_handler))
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
