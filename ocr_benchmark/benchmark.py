#!/usr/bin/env python3
"""OCR model benchmark against calibration dataset.

Usage: python3 benchmark.py ../ocr_dataset/
"""

import sys
import os
import time
import json
from pathlib import Path
from difflib import SequenceMatcher

DATASET_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("../ocr_dataset")

def load_dataset():
    pairs = []
    for txt_file in sorted(DATASET_DIR.glob("*.txt")):
        png_file = txt_file.with_suffix(".png")
        if png_file.exists():
            ground_truth = txt_file.read_text().strip()
            pairs.append((str(png_file), ground_truth))
    return pairs

def similarity(a, b):
    return SequenceMatcher(None, a.lower(), b.lower()).ratio()

def char_error_rate(pred, truth):
    """Simple CER: edit distance / len(truth)"""
    import difflib
    s = difflib.SequenceMatcher(None, truth, pred)
    errors = 0
    for op, i1, i2, j1, j2 in s.get_opcodes():
        if op != 'equal':
            errors += max(i2 - i1, j2 - j1)
    return errors / max(len(truth), 1)

# --- Models ---

def test_trocr(variant, dataset):
    from transformers import TrOCRProcessor, VisionEncoderDecoderModel
    from PIL import Image

    name = f"microsoft/trocr-{variant}-handwritten"
    print(f"\n{'='*60}")
    print(f"Testing: {name}")
    print(f"{'='*60}")

    processor = TrOCRProcessor.from_pretrained(name)
    model = VisionEncoderDecoderModel.from_pretrained(name)
    model.eval()

    results = []
    total_time = 0
    for img_path, truth in dataset:
        img = Image.open(img_path).convert("RGB")
        start = time.time()
        pixel_values = processor(images=img, return_tensors="pt").pixel_values
        generated_ids = model.generate(pixel_values, max_new_tokens=256, num_beams=5)
        pred = processor.batch_decode(generated_ids, skip_special_tokens=True)[0].strip()
        elapsed = time.time() - start
        total_time += elapsed

        sim = similarity(pred, truth)
        cer = char_error_rate(pred, truth)
        results.append({"truth": truth, "pred": pred, "sim": sim, "cer": cer, "time": elapsed})
        status = "OK" if sim > 0.8 else "BAD"
        print(f"  [{status}] '{truth}' -> '{pred}' (sim={sim:.2f}, cer={cer:.2f}, {elapsed:.1f}s)")

    avg_sim = sum(r["sim"] for r in results) / len(results)
    avg_cer = sum(r["cer"] for r in results) / len(results)
    avg_time = total_time / len(results)
    print(f"\n  AVG similarity: {avg_sim:.3f}, AVG CER: {avg_cer:.3f}, AVG time: {avg_time:.1f}s")
    return {"model": name, "avg_sim": avg_sim, "avg_cer": avg_cer, "avg_time": avg_time, "results": results}

def test_easyocr(dataset):
    import easyocr
    print(f"\n{'='*60}")
    print(f"Testing: EasyOCR")
    print(f"{'='*60}")

    reader = easyocr.Reader(['en'], gpu=False)

    results = []
    total_time = 0
    for img_path, truth in dataset:
        start = time.time()
        raw = reader.readtext(img_path, detail=0)
        pred = " ".join(raw).strip()
        elapsed = time.time() - start
        total_time += elapsed

        sim = similarity(pred, truth)
        cer = char_error_rate(pred, truth)
        results.append({"truth": truth, "pred": pred, "sim": sim, "cer": cer, "time": elapsed})
        status = "OK" if sim > 0.8 else "BAD"
        print(f"  [{status}] '{truth}' -> '{pred}' (sim={sim:.2f}, cer={cer:.2f}, {elapsed:.1f}s)")

    avg_sim = sum(r["sim"] for r in results) / len(results)
    avg_cer = sum(r["cer"] for r in results) / len(results)
    avg_time = total_time / len(results)
    print(f"\n  AVG similarity: {avg_sim:.3f}, AVG CER: {avg_cer:.3f}, AVG time: {avg_time:.1f}s")
    return {"model": "EasyOCR", "avg_sim": avg_sim, "avg_cer": avg_cer, "avg_time": avg_time, "results": results}

def test_paddleocr(dataset):
    from paddleocr import PaddleOCR
    print(f"\n{'='*60}")
    print(f"Testing: PaddleOCR")
    print(f"{'='*60}")

    ocr = PaddleOCR(use_angle_cls=True, use_gpu=False, lang='en', show_log=False)

    results = []
    total_time = 0
    for img_path, truth in dataset:
        start = time.time()
        raw = ocr.ocr(img_path, cls=True)
        # Extract text from results
        texts = []
        if raw and raw[0]:
            for line in raw[0]:
                if line and len(line) >= 2:
                    texts.append(line[1][0])
        pred = " ".join(texts).strip()
        elapsed = time.time() - start
        total_time += elapsed

        sim = similarity(pred, truth)
        cer = char_error_rate(pred, truth)
        results.append({"truth": truth, "pred": pred, "sim": sim, "cer": cer, "time": elapsed})
        status = "OK" if sim > 0.8 else "BAD"
        print(f"  [{status}] '{truth}' -> '{pred}' (sim={sim:.2f}, cer={cer:.2f}, {elapsed:.1f}s)")

    avg_sim = sum(r["sim"] for r in results) / len(results)
    avg_cer = sum(r["cer"] for r in results) / len(results)
    avg_time = total_time / len(results)
    print(f"\n  AVG similarity: {avg_sim:.3f}, AVG CER: {avg_cer:.3f}, AVG time: {avg_time:.1f}s")
    return {"model": "PaddleOCR", "avg_sim": avg_sim, "avg_cer": avg_cer, "avg_time": avg_time, "results": results}

def test_claude_vision(dataset):
    import base64, requests
    print(f"\n{'='*60}")
    print(f"Testing: Claude Sonnet Vision")
    print(f"{'='*60}")

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("  SKIPPED: ANTHROPIC_API_KEY not set")
        return None

    results = []
    total_time = 0
    for img_path, truth in dataset:
        with open(img_path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()

        start = time.time()
        resp = requests.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": "claude-sonnet-4-20250514",
                "max_tokens": 256,
                "messages": [{
                    "role": "user",
                    "content": [
                        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64}},
                        {"type": "text", "text": "Read the handwritten text in this image. Return ONLY the text, nothing else. No quotes, no explanation."}
                    ]
                }]
            }
        )
        elapsed = time.time() - start
        total_time += elapsed

        pred = ""
        if resp.status_code == 200:
            data = resp.json()
            pred = data["content"][0]["text"].strip()
        else:
            pred = f"ERROR: {resp.status_code}"

        sim = similarity(pred, truth)
        cer = char_error_rate(pred, truth)
        results.append({"truth": truth, "pred": pred, "sim": sim, "cer": cer, "time": elapsed})
        status = "OK" if sim > 0.8 else "BAD"
        print(f"  [{status}] '{truth}' -> '{pred}' (sim={sim:.2f}, cer={cer:.2f}, {elapsed:.1f}s)")

    avg_sim = sum(r["sim"] for r in results) / len(results)
    avg_cer = sum(r["cer"] for r in results) / len(results)
    avg_time = total_time / len(results)
    print(f"\n  AVG similarity: {avg_sim:.3f}, AVG CER: {avg_cer:.3f}, AVG time: {avg_time:.1f}s")
    return {"model": "Claude Sonnet Vision", "avg_sim": avg_sim, "avg_cer": avg_cer, "avg_time": avg_time, "results": results}

def main():
    dataset = load_dataset()
    print(f"Loaded {len(dataset)} samples from {DATASET_DIR}")

    all_results = []

    # TrOCR variants
    for variant in ["base", "large"]:
        try:
            r = test_trocr(variant, dataset)
            all_results.append(r)
        except Exception as e:
            print(f"  FAILED: {e}")

    # EasyOCR
    try:
        r = test_easyocr(dataset)
        all_results.append(r)
    except Exception as e:
        print(f"  EasyOCR FAILED: {e}")

    # PaddleOCR
    try:
        r = test_paddleocr(dataset)
        all_results.append(r)
    except Exception as e:
        print(f"  PaddleOCR FAILED: {e}")

    # Claude Vision
    try:
        r = test_claude_vision(dataset)
        if r:
            all_results.append(r)
    except Exception as e:
        print(f"  Claude FAILED: {e}")

    # Summary
    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    print(f"{'Model':<30} {'Similarity':>10} {'CER':>8} {'Time':>8}")
    print("-" * 60)
    for r in sorted(all_results, key=lambda x: -x["avg_sim"]):
        print(f"{r['model']:<30} {r['avg_sim']:>10.3f} {r['avg_cer']:>8.3f} {r['avg_time']:>7.1f}s")

    # Save results
    with open("benchmark_results.json", "w") as f:
        json.dump(all_results, f, indent=2)
    print("\nResults saved to benchmark_results.json")

if __name__ == "__main__":
    main()
