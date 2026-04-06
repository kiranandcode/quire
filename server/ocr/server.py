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
    """Detect text vs image regions.

    1. CRAFT finds text region bounding boxes
    2. Group overlapping/nearby CRAFT boxes into clusters
    3. OCR each cluster with LightOnOCR
    4. If OCR returns LaTeX → reclassify that cluster as image
    5. Ink pixels outside all CRAFT boxes → image region
    """
    load_craft()
    load_ocr_model()

    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    w, h = img.size
    print(f"[detect] {w}x{h}", flush=True)
    t = time.time()

    # Step 1: CRAFT text detection
    MARGIN = 10
    results = craft_reader.readtext(np.array(img))
    craft_boxes = []
    for (bbox, _text, _conf) in results:
        xs = [p[0] for p in bbox]
        ys = [p[1] for p in bbox]
        craft_boxes.append([
            max(0, int(min(xs)) - MARGIN), max(0, int(min(ys)) - MARGIN),
            min(w, int(max(xs)) + MARGIN), min(h, int(max(ys)) + MARGIN),
        ])

    if not craft_boxes:
        # No text detected — entire image is a drawing
        img_gray = np.array(img.convert("L"))
        ink_ys, ink_xs = np.where(img_gray < 128)
        if len(ink_xs) > 0:
            return {"regions": [{"type": "image", "bbox": [
                int(ink_xs.min()), int(ink_ys.min()),
                int(ink_xs.max()), int(ink_ys.max())
            ]}]}
        return {"regions": []}

    # Step 2: Group overlapping/nearby boxes into clusters
    LINE_GAP = 80  # merge boxes within this vertical distance
    clusters = []  # each cluster is a list of box indices
    used = set()
    for i, box in enumerate(craft_boxes):
        if i in used:
            continue
        cluster = [i]
        used.add(i)
        # Find all boxes that overlap or are on same horizontal band
        changed = True
        while changed:
            changed = False
            for j, other in enumerate(craft_boxes):
                if j in used:
                    continue
                # Check if any box in cluster overlaps or is vertically close
                for ci in cluster:
                    cb = craft_boxes[ci]
                    # Horizontal overlap and vertical proximity
                    h_overlap = cb[0] < other[2] and other[0] < cb[2]
                    v_close = abs((cb[1]+cb[3])/2 - (other[1]+other[3])/2) < LINE_GAP
                    # Or boxes just overlap directly
                    direct_overlap = (cb[0] < other[2] and other[0] < cb[2] and
                                     cb[1] < other[3] and other[1] < cb[3])
                    if direct_overlap or (h_overlap and v_close):
                        cluster.append(j)
                        used.add(j)
                        changed = True
                        break
        clusters.append(cluster)

    print(f"[detect] {len(craft_boxes)} CRAFT boxes → {len(clusters)} clusters", flush=True)

    # Step 3: OCR each cluster, reclassify if LaTeX
    regions = []
    text_mask = np.zeros((h, w), dtype=bool)  # track which pixels are covered by text

    for ci, cluster_indices in enumerate(clusters):
        # Compute bounding box of this cluster
        cx1 = min(craft_boxes[i][0] for i in cluster_indices)
        cy1 = min(craft_boxes[i][1] for i in cluster_indices)
        cx2 = max(craft_boxes[i][2] for i in cluster_indices)
        cy2 = max(craft_boxes[i][3] for i in cluster_indices)
        pad = 5
        cx1 = max(0, cx1 - pad)
        cy1 = max(0, cy1 - pad)
        cx2 = min(w, cx2 + pad)
        cy2 = min(h, cy2 + pad)

        # OCR the cluster crop
        crop = img.crop((cx1, cy1, cx2, cy2))
        raw_ocr = _run_model(ocr_model, ocr_processor, crop)

        # Check if OCR returned LaTeX/structured content
        is_latex = bool(re.search(
            r'\\frac|\\begin|\\sum|\\int|\\sqrt|\\matrix|\\align|'
            r'\\triangle|\\downarrow|\\uparrow|\\text\{|\\cdot|'
            r'\\rightarrow|\\leftarrow|\\quad|\\hline|\\end\{',
            raw_ocr
        ))
        is_html = bool(re.search(r'<table|<div|<svg|<tr|<td', raw_ocr, re.IGNORECASE))

        if is_latex or is_html:
            # Structured content → image; use generous mask padding to capture stray ink
            img_pad = 40
            mx1, my1 = max(0, cx1 - img_pad), max(0, cy1 - img_pad)
            mx2, my2 = min(w, cx2 + img_pad), min(h, cy2 + img_pad)
            regions.append({"type": "image", "bbox": [mx1, my1, mx2, my2]})
            text_mask[my1:my2, mx1:mx2] = True
            print(f"[detect] Cluster {ci}: LaTeX/HTML → image ({mx2-mx1}x{my2-my1})", flush=True)
        else:
            # Plain text
            ocr_text = re.sub(r'\$\\text\{([^}]*)\}\$', r'\1', raw_ocr)
            ocr_text = re.sub(r'^\$|\$$', '', ocr_text).strip()

            # Detect garbled/hallucinated OCR: repeated patterns → treat as image
            is_garbled = False
            if len(ocr_text) > 100:
                # Check for repeated substrings (hallucination)
                for plen in range(5, 30):
                    pattern = ocr_text[:plen]
                    if ocr_text.count(pattern) > 3:
                        is_garbled = True
                        break

            if is_garbled:
                regions.append({"type": "image", "bbox": [cx1, cy1, cx2, cy2]})
                text_mask[cy1:cy2, cx1:cx2] = True
                print(f"[detect] Cluster {ci}: garbled → image ({cx2-cx1}x{cy2-cy1})", flush=True)
            elif ocr_text:
                if len(ocr_text) > 200:
                    ocr_text = ocr_text[:200]
                regions.append({"type": "text", "content": ocr_text, "_cluster_bbox": [cx1, cy1, cx2, cy2]})
                print(f"[detect] Cluster {ci}: text ({cx2-cx1}x{cy2-cy1}): {repr(ocr_text[:60])}", flush=True)
            # Mark text cluster pixels as covered
            text_mask[cy1:cy2, cx1:cx2] = True

    # Step 4: Find drawing regions — ink pixels NOT covered by any CRAFT cluster
    img_gray = np.array(img.convert("L"))
    ink_mask = img_gray < 128
    drawing_mask = ink_mask & ~text_mask
    drawing_ys, drawing_xs = np.where(drawing_mask)

    if len(drawing_xs) > 50:  # minimum ink pixels for a drawing
        dx1, dy1 = int(drawing_xs.min()), int(drawing_ys.min())
        dx2, dy2 = int(drawing_xs.max()), int(drawing_ys.max())
        regions.append({"type": "image", "bbox": [dx1, dy1, dx2, dy2]})
        print(f"[detect] Drawing region: ({dx2-dx1}x{dy2-dy1}) from uncovered ink", flush=True)

    # Step 5: Merge overlapping/nearby image regions
    MERGE_GAP = 30
    merged = True
    while merged:
        merged = False
        image_regions = [r for r in regions if r["type"] == "image" and "bbox" in r]
        for i in range(len(image_regions)):
            for j in range(i + 1, len(image_regions)):
                a, b = image_regions[i]["bbox"], image_regions[j]["bbox"]
                h_close = a[0] < b[2] + MERGE_GAP and b[0] < a[2] + MERGE_GAP
                v_close = a[1] < b[3] + MERGE_GAP and b[1] < a[3] + MERGE_GAP
                if h_close and v_close:
                    image_regions[i]["bbox"] = [
                        min(a[0], b[0]), min(a[1], b[1]),
                        max(a[2], b[2]), max(a[3], b[3]),
                    ]
                    regions.remove(image_regions[j])
                    merged = True
                    break
            if merged:
                break

    # Step 6: Viral image absorption — text inside/overlapping drawing ink
    # becomes part of the image. Check if drawing ink surrounds the text
    # on 3+ sides (left/right/above/below). This catches labels inside diagrams
    # while leaving standalone text (like "Please convert to LATEX") alone.
    drawing_mask = ink_mask & ~text_mask  # non-text ink pixels
    absorbed = True
    while absorbed:
        absorbed = False
        image_regions = [r for r in regions if r["type"] == "image" and "bbox" in r]
        text_regions = [r for r in regions if r["type"] == "text"]
        if not image_regions:
            break
        for tr in text_regions:
            tr_bbox = tr.get("_cluster_bbox")
            if tr_bbox is None:
                continue
            tx1, ty1, tx2, ty2 = tr_bbox
            # Check how many sides have drawing ink nearby (within 20px margin)
            margin = 20
            sides = 0
            # Left: ink in a strip to the left of the text
            left_strip = drawing_mask[max(0,ty1):ty2, max(0,tx1-margin):tx1]
            if left_strip.any():
                sides += 1
            # Right: ink to the right
            right_strip = drawing_mask[max(0,ty1):ty2, tx2:min(w,tx2+margin)]
            if right_strip.any():
                sides += 1
            # Above: ink above
            above_strip = drawing_mask[max(0,ty1-margin):ty1, max(0,tx1):tx2]
            if above_strip.any():
                sides += 1
            # Below: ink below
            below_strip = drawing_mask[ty2:min(h,ty2+margin), max(0,tx1):tx2]
            if below_strip.any():
                sides += 1

            if sides >= 3:
                # Absorb into the nearest/overlapping image region
                best_ir = None
                best_dist = float('inf')
                tcx, tcy = (tx1+tx2)/2, (ty1+ty2)/2
                for ir in image_regions:
                    ib = ir["bbox"]
                    icx, icy = (ib[0]+ib[2])/2, (ib[1]+ib[3])/2
                    dist = abs(tcx-icx) + abs(tcy-icy)
                    if dist < best_dist:
                        best_dist = dist
                        best_ir = ir
                if best_ir:
                    ib = best_ir["bbox"]
                    best_ir["bbox"] = [
                        min(ib[0], tx1), min(ib[1], ty1),
                        max(ib[2], tx2), max(ib[3], ty2),
                    ]
                    regions.remove(tr)
                    absorbed = True
                    print(f"[detect] Absorbed text ({sides}/4 sides with ink): "
                          f"{repr(tr.get('content', '')[:40])}", flush=True)
                    break

    img_count = sum(1 for r in regions if r["type"] == "image")
    if img_count > 0:
        print(f"[detect] Final: {img_count} image region(s)", flush=True)

    # Strip internal fields before returning
    for r in regions:
        r.pop("_cluster_bbox", None)

    elapsed = time.time() - t
    print(f"[detect] Done in {elapsed:.1f}s: {len(craft_boxes)} CRAFT boxes, "
          f"{len(clusters)} clusters, {len(regions)} regions", flush=True)

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
