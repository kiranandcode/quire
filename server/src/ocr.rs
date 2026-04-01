use image::{ImageBuffer, Rgb};
use serde::Deserialize;
use std::io::Cursor;

/// OCR via LightOnOCR sidecar running on localhost.
pub async fn recognize(img: &ImageBuffer<Rgb<u8>, Vec<u8>>, sidecar_port: u16) -> Result<String, String> {
    let png_bytes = encode_png(img)?;

    // Save debug copy
    let _ = img.save("quire_render_debug.png");

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("http://127.0.0.1:{sidecar_port}/ocr"))
        .body(png_bytes)
        .send()
        .await
        .map_err(|e| format!("OCR sidecar request failed: {e}"))?;

    let status = resp.status();
    let body = resp.text().await.map_err(|e| format!("Read OCR response failed: {e}"))?;

    if !status.is_success() {
        return Err(format!("OCR sidecar error {status}: {body}"));
    }

    let parsed: OcrResponse = serde_json::from_str(&body)
        .map_err(|e| format!("Parse OCR response failed: {e}"))?;

    Ok(parsed.text)
}

#[derive(Deserialize)]
struct OcrResponse {
    text: String,
}

#[derive(Deserialize)]
pub struct DetectRegion {
    #[serde(rename = "type")]
    pub region_type: String,
    pub content: Option<String>,
    pub bbox: Option<[u32; 4]>,
}

#[derive(Deserialize)]
struct DetectResponse {
    regions: Vec<DetectRegion>,
}

/// Detect text vs image regions via LightOnOCR-bbox sidecar.
pub async fn detect(img: &ImageBuffer<Rgb<u8>, Vec<u8>>, sidecar_port: u16) -> Result<Vec<DetectRegion>, String> {
    let png_bytes = encode_png(img)?;

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("http://127.0.0.1:{sidecar_port}/detect"))
        .body(png_bytes)
        .send()
        .await
        .map_err(|e| format!("Detect sidecar request failed: {e}"))?;

    let status = resp.status();
    let body = resp.text().await.map_err(|e| format!("Read detect response failed: {e}"))?;

    if !status.is_success() {
        return Err(format!("Detect sidecar error {status}: {body}"));
    }

    let parsed: DetectResponse = serde_json::from_str(&body)
        .map_err(|e| format!("Parse detect response failed: {e}"))?;

    Ok(parsed.regions)
}

fn encode_png(img: &ImageBuffer<Rgb<u8>, Vec<u8>>) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    img.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png)
        .map_err(|e| format!("Failed to encode PNG: {e}"))?;
    Ok(buf)
}
