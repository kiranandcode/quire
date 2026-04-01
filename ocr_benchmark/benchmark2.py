#!/usr/bin/env python3
"""OCR benchmark round 2: 2026 models.

Usage: python3 benchmark2.py ../ocr_dataset/
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
    import difflib
    s = difflib.SequenceMatcher(None, truth, pred)
    errors = 0
    for op, i1, i2, j1, j2 in s.get_opcodes():
        if op != 'equal':
            errors += max(i2 - i1, j2 - j1)
    return errors / max(len(truth), 1)

def run_model(name, dataset, infer_fn):
    print(f"\n{'='*60}")
    print(f"Testing: {name}")
    print(f"{'='*60}")
    results = []
    total_time = 0
    for img_path, truth in dataset:
        start = time.time()
        try:
            pred = infer_fn(img_path).strip()
        except Exception as e:
            pred = f"ERROR: {e}"
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

# --- Model implementations ---

def make_glm_ocr():
    """GLM-OCR via transformers"""
    from transformers import AutoModel, AutoTokenizer
    from PIL import Image
    model_name = "zai-org/GLM-OCR"
    tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
    model = AutoModel.from_pretrained(model_name, trust_remote_code=True, device_map="cpu", torch_dtype="auto")
    model.eval()
    def infer(img_path):
        img = Image.open(img_path).convert("RGB")
        messages = [{"role": "user", "content": [{"type": "image", "image": img}, {"type": "text", "text": "Read the handwritten text. Return ONLY the text."}]}]
        inputs = tokenizer.apply_chat_template(messages, return_tensors="pt", add_generation_prompt=True, tokenize=True, return_dict=True)
        outputs = model.generate(**inputs, max_new_tokens=256)
        return tokenizer.decode(outputs[0][inputs['input_ids'].shape[1]:], skip_special_tokens=True)
    return infer

def make_lightonocr():
    """LightOnOCR-2-1B"""
    from transformers import AutoProcessor, AutoModelForImageTextToText
    from PIL import Image
    model_name = "lightonai/LightOnOCR-2-1B"
    processor = AutoProcessor.from_pretrained(model_name)
    model = AutoModelForImageTextToText.from_pretrained(model_name, device_map="cpu", torch_dtype="auto")
    model.eval()
    def infer(img_path):
        img = Image.open(img_path).convert("RGB")
        inputs = processor(images=img, text="Read the handwritten text in this image. Return ONLY the text, nothing else.", return_tensors="pt")
        outputs = model.generate(**inputs, max_new_tokens=256)
        return processor.decode(outputs[0], skip_special_tokens=True)
    return infer

def make_nanonets():
    """Nanonets-OCR-s"""
    from transformers import AutoProcessor, AutoModelForImageTextToText
    from PIL import Image
    model_name = "nanonets/Nanonets-OCR-s"
    processor = AutoProcessor.from_pretrained(model_name, trust_remote_code=True)
    model = AutoModelForImageTextToText.from_pretrained(model_name, trust_remote_code=True, device_map="cpu", torch_dtype="auto")
    model.eval()
    def infer(img_path):
        img = Image.open(img_path).convert("RGB")
        inputs = processor(images=img, text="Read the handwritten text. Return ONLY the text.", return_tensors="pt")
        outputs = model.generate(**inputs, max_new_tokens=256)
        return processor.decode(outputs[0], skip_special_tokens=True)
    return infer

def make_paddleocr():
    """PaddleOCR v5"""
    os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
    from paddleocr import PaddleOCR
    ocr = PaddleOCR(lang='en', show_log=False)
    def infer(img_path):
        raw = ocr.ocr(img_path)
        texts = []
        if raw and raw[0]:
            for line in raw[0]:
                if line and len(line) >= 2:
                    texts.append(line[1][0])
        return " ".join(texts)
    return infer

def make_claude_vision():
    """Claude Sonnet Vision (baseline)"""
    import base64, requests
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        return None
    def infer(img_path):
        with open(img_path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        resp = requests.post(
            "https://api.anthropic.com/v1/messages",
            headers={"x-api-key": api_key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
            json={"model": "claude-sonnet-4-20250514", "max_tokens": 256,
                  "messages": [{"role": "user", "content": [
                      {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64}},
                      {"type": "text", "text": "Read the handwritten text in this image. Return ONLY the text, nothing else. No quotes, no explanation."}
                  ]}]}
        )
        if resp.status_code == 200:
            return resp.json()["content"][0]["text"]
        return f"ERROR: {resp.status_code}"
    return infer

def main():
    dataset = load_dataset()
    print(f"Loaded {len(dataset)} samples from {DATASET_DIR}")
    all_results = []

    models = [
        ("PaddleOCR v5", make_paddleocr),
        ("GLM-OCR (0.9B)", make_glm_ocr),
        ("LightOnOCR-2-1B", make_lightonocr),
        ("Nanonets-OCR-s (3B)", make_nanonets),
        ("Claude Sonnet Vision", make_claude_vision),
    ]

    for name, make_fn in models:
        try:
            infer = make_fn()
            if infer is None:
                print(f"\n  SKIPPED: {name} (not configured)")
                continue
            r = run_model(name, dataset, infer)
            all_results.append(r)
        except Exception as e:
            print(f"\n  {name} FAILED: {e}")
            import traceback; traceback.print_exc()

    # Summary
    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    print(f"{'Model':<30} {'Similarity':>10} {'CER':>8} {'Time':>8}")
    print("-" * 60)
    for r in sorted(all_results, key=lambda x: -x["avg_sim"]):
        print(f"{r['model']:<30} {r['avg_sim']:>10.3f} {r['avg_cer']:>8.3f} {r['avg_time']:>7.1f}s")

    with open("benchmark2_results.json", "w") as f:
        json.dump(all_results, f, indent=2)
    print("\nResults saved to benchmark2_results.json")

if __name__ == "__main__":
    main()
