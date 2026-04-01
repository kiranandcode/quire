#!/usr/bin/env python3
"""LightOnOCR sidecar server. Keeps model in memory, serves via HTTP.

Endpoints:
  POST /ocr     - OCR only (LightOnOCR-2-1B), returns {"text": "..."}
  POST /detect  - Layout detection (LightOnOCR-2-1B-bbox), returns {"regions": [...]}
  GET  /health  - Health check

Both endpoints accept multipart form with 'image' file field.

Usage: python3 server.py [--port 8090]
"""

import argparse
import io
import json
import os
import re
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Lock

import torch
from PIL import Image
from transformers import LightOnOcrForConditionalGeneration, LightOnOcrProcessor

# Globals
ocr_model = None
ocr_processor = None
bbox_model = None
bbox_processor = None
model_lock = Lock()

DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"
DTYPE = torch.float32  # MPS needs float32


def load_ocr_model():
    global ocr_model, ocr_processor
    if ocr_model is not None:
        return
    print("[ocr] Loading LightOnOCR-2-1B...", flush=True)
    t = time.time()
    ocr_processor = LightOnOcrProcessor.from_pretrained("lightonai/LightOnOCR-2-1B")
    ocr_model = LightOnOcrForConditionalGeneration.from_pretrained(
        "lightonai/LightOnOCR-2-1B", dtype=DTYPE
    ).to(DEVICE)
    ocr_model.eval()
    print(f"[ocr] Loaded in {time.time()-t:.1f}s on {DEVICE}", flush=True)


def load_bbox_model():
    global bbox_model, bbox_processor
    if bbox_model is not None:
        return
    print("[bbox] Loading LightOnOCR-2-1B-bbox...", flush=True)
    t = time.time()
    bbox_processor = LightOnOcrProcessor.from_pretrained("lightonai/LightOnOCR-2-1B-bbox")
    bbox_model = LightOnOcrForConditionalGeneration.from_pretrained(
        "lightonai/LightOnOCR-2-1B-bbox", dtype=DTYPE
    ).to(DEVICE)
    bbox_model.eval()
    print(f"[bbox] Loaded in {time.time()-t:.1f}s on {DEVICE}", flush=True)


def _run_model(model, processor, img, max_tokens=512):
    """Run a LightOnOCR model on a PIL image."""
    # Save image to temp file — LightOnOCR uses file URLs in conversation
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        img.save(f, "PNG")
        tmp_path = f.name

    conversation = [{"role": "user", "content": [{"type": "image", "url": tmp_path}]}]
    inputs = processor.apply_chat_template(
        conversation, add_generation_prompt=True, tokenize=True,
        return_dict=True, return_tensors="pt",
    )
    inputs = {k: v.to(device=DEVICE, dtype=DTYPE) if v.is_floating_point() else v.to(DEVICE) for k, v in inputs.items()}
    with torch.no_grad():
        output_ids = model.generate(**inputs, max_new_tokens=max_tokens)
    generated = output_ids[0, inputs["input_ids"].shape[-1]:]
    text = processor.decode(generated, skip_special_tokens=True).strip()

    os.unlink(tmp_path)
    return text


def run_ocr(image_bytes: bytes) -> str:
    load_ocr_model()
    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    text = _run_model(ocr_model, ocr_processor, img)
    # Strip LaTeX wrappers that LightOnOCR sometimes adds
    text = re.sub(r'\$\\text\{([^}]*)\}\$', r'\1', text)
    text = re.sub(r'^\$|\$$', '', text).strip()
    return text


def run_detect(image_bytes: bytes) -> dict:
    load_bbox_model()
    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    w, h = img.size
    raw = _run_model(bbox_model, bbox_processor, img, max_tokens=2048)

    # Parse regions: text lines + image bounding boxes
    regions = []
    # Image boxes: [image](image_N.png) x1,y1,x2,y2
    for m in re.finditer(r'\[image\]\([^)]+\)\s*(\d+),(\d+),(\d+),(\d+)', raw):
        x1 = int(m.group(1)) * w // 1000
        y1 = int(m.group(2)) * h // 1000
        x2 = int(m.group(3)) * w // 1000
        y2 = int(m.group(4)) * h // 1000
        regions.append({"type": "image", "bbox": [x1, y1, x2, y2]})

    # Everything else is text
    text = re.sub(r'\[image\]\([^)]+\)\s*\d+,\d+,\d+,\d+', '', raw).strip()
    if text:
        # Clean LaTeX wrappers
        text = re.sub(r'\$\\text\{([^}]*)\}\$', r'\1', text)
        text = re.sub(r'^\$|\$$', '', text).strip()
        regions.insert(0, {"type": "text", "content": text})

    return {"regions": regions, "raw": raw}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_error(404)

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        # Accept raw PNG body
        try:
            with model_lock:
                if self.path == "/ocr":
                    text = run_ocr(body)
                    resp = json.dumps({"text": text}).encode()
                elif self.path == "/detect":
                    result = run_detect(body)
                    resp = json.dumps(result).encode()
                else:
                    self.send_error(404)
                    return

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(resp)
        except Exception as e:
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())

    def log_message(self, format, *args):
        print(f"[http] {args[0]}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--preload", action="store_true", help="Load models at startup")
    args = parser.parse_args()

    if args.preload:
        load_ocr_model()
        load_bbox_model()

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[ocr-sidecar] listening on 127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
