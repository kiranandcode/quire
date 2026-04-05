#!/usr/bin/env python3
"""LightOnOCR sidecar server. Keeps model in memory, serves via HTTP.

Endpoints:
  POST /ocr     - OCR only (LightOnOCR-2-1B), returns {"text": "..."}
  POST /detect  - Layout detection (CRAFT + connected components), returns {"regions": [...]}
  GET  /health  - Health check

Both endpoints accept raw PNG body.

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

import numpy as np
import torch
from PIL import Image
from scipy import ndimage
from transformers import LightOnOcrForConditionalGeneration, LightOnOcrProcessor

# Globals
ocr_model = None
ocr_processor = None
craft_reader = None
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


def load_craft():
    global craft_reader
    if craft_reader is not None:
        return
    import easyocr
    print("[craft] Loading CRAFT text detector...", flush=True)
    t = time.time()
    craft_reader = easyocr.Reader(["en"], gpu=False)
    print(f"[craft] Loaded in {time.time()-t:.1f}s", flush=True)


def _run_model(model, processor, img, max_tokens=512):
    """Run a LightOnOCR model on a PIL image."""
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
    """Detect text vs image regions using CRAFT text detection + connected components.

    1. CRAFT finds text regions (bounding boxes)
    2. Connected component analysis finds ink blobs
    3. Components overlapping CRAFT text boxes → text
    4. Remaining components on the same horizontal line as text → text
    5. Everything else → drawing/image
    """
    load_craft()
    load_ocr_model()

    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    w, h = img.size
    print(f"[detect] CRAFT detect: {w}x{h}", flush=True)
    t = time.time()

    # Step 1: CRAFT text detection
    MARGIN = 15
    results = craft_reader.readtext(np.array(img))
    text_boxes = []
    for (bbox, _text, _conf) in results:
        xs = [p[0] for p in bbox]
        ys = [p[1] for p in bbox]
        text_boxes.append((min(xs) - MARGIN, min(ys) - MARGIN,
                           max(xs) + MARGIN, max(ys) + MARGIN))

    # Step 2: Connected component analysis on ink pixels
    img_gray = np.array(img.convert("L"))
    ink_mask = img_gray < 128
    labeled, num_features = ndimage.label(ink_mask)

    components = []
    for i in range(1, num_features + 1):
        ys, xs = np.where(labeled == i)
        if len(xs) < 5:
            continue
        cx1, cy1, cx2, cy2 = int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())
        if (cx2 - cx1) * (cy2 - cy1) < 20:
            continue
        y_center = (cy1 + cy2) / 2.0
        components.append({
            "bbox": (cx1, cy1, cx2, cy2),
            "yc": y_center,
            "pixels": len(xs),
        })

    # Step 3: Classify components — CRAFT overlap check
    craft_text = []
    uncertain = []
    for comp in components:
        cx1, cy1, cx2, cy2 = comp["bbox"]
        comp_area = max((cx2 - cx1) * (cy2 - cy1), 1)
        max_overlap = 0.0
        for tx1, ty1, tx2, ty2 in text_boxes:
            ix1, iy1 = max(cx1, tx1), max(cy1, ty1)
            ix2, iy2 = min(cx2, tx2), min(cy2, ty2)
            if ix1 < ix2 and iy1 < iy2:
                overlap = (ix2 - ix1) * (iy2 - iy1) / comp_area
                if overlap > max_overlap:
                    max_overlap = overlap
        if max_overlap > 0.3:
            craft_text.append(comp)
        else:
            uncertain.append(comp)

    # Step 4: Horizontal line grouping — uncertain components on a text line → text
    LINE_TOLERANCE = 30
    drawing_components = []
    for unc in uncertain:
        on_text_line = any(
            abs(unc["yc"] - tc["yc"]) < LINE_TOLERANCE for tc in craft_text
        )
        if not on_text_line:
            drawing_components.append(unc)

    # Step 5: Run OCR for text content
    raw_ocr = _run_model(ocr_model, ocr_processor, img)
    # If OCR returns LaTeX/SVG, treat the whole thing as an image — the content
    # is structured/mathematical and Claude should see the drawing directly.
    has_latex = bool(re.search(r'\\frac|\\begin|\\sum|\\int|\\sqrt|\\matrix|\\align', raw_ocr))
    has_svg = '<svg' in raw_ocr.lower()

    if has_latex or has_svg:
        # Entire image is structured content — send as image
        print(f"[detect] OCR returned LaTeX/SVG, treating as image", flush=True)
        iw, ih = img.size
        regions = [{"type": "image", "bbox": [0, 0, iw, ih]}]

        elapsed = time.time() - t
        print(f"[detect] Done in {elapsed:.1f}s: structured content -> full image",
              flush=True)
        return {"regions": regions}

    ocr_text = re.sub(r'\$\\text\{([^}]*)\}\$', r'\1', raw_ocr)
    ocr_text = re.sub(r'^\$|\$$', '', ocr_text).strip()

    # Build regions
    regions = []
    if ocr_text:
        regions.append({"type": "text", "content": ocr_text})
    if drawing_components:
        dx1 = min(c["bbox"][0] for c in drawing_components)
        dy1 = min(c["bbox"][1] for c in drawing_components)
        dx2 = max(c["bbox"][2] for c in drawing_components)
        dy2 = max(c["bbox"][3] for c in drawing_components)
        regions.append({"type": "image", "bbox": [dx1, dy1, dx2, dy2]})

    elapsed = time.time() - t
    print(f"[detect] Done in {elapsed:.1f}s: {len(text_boxes)} CRAFT boxes, "
          f"{len(craft_text)} text components, {len(drawing_components)} drawing components",
          flush=True)

    return {"regions": regions}


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
        load_craft()

    import socket
    HTTPServer.allow_reuse_address = True
    server = HTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[ocr-sidecar] listening on 127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
