#!/usr/bin/env python3
"""OCR benchmark round 3: correct model-specific loading."""

import sys, os, time, json, base64
from pathlib import Path
from difflib import SequenceMatcher

DATASET_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("../ocr_dataset")

def load_dataset():
    pairs = []
    for txt_file in sorted(DATASET_DIR.glob("*.txt")):
        png_file = txt_file.with_suffix(".png")
        if png_file.exists():
            pairs.append((str(png_file), txt_file.read_text().strip()))
    return pairs

def similarity(a, b):
    return SequenceMatcher(None, a.lower(), b.lower()).ratio()

def char_error_rate(pred, truth):
    import difflib
    s = difflib.SequenceMatcher(None, truth, pred)
    errors = sum(max(i2-i1, j2-j1) for op, i1, i2, j1, j2 in s.get_opcodes() if op != 'equal')
    return errors / max(len(truth), 1)

def run_model(name, dataset, infer_fn):
    print(f"\n{'='*60}\nTesting: {name}\n{'='*60}")
    results = []
    for img_path, truth in dataset:
        start = time.time()
        try:
            pred = infer_fn(img_path).strip()
        except Exception as e:
            pred = f"ERROR: {e}"
        elapsed = time.time() - start
        sim = similarity(pred, truth)
        cer = char_error_rate(pred, truth)
        results.append({"truth": truth, "pred": pred, "sim": sim, "cer": cer, "time": elapsed})
        status = "OK" if sim > 0.8 else "BAD"
        print(f"  [{status}] '{truth}' -> '{pred}' (sim={sim:.2f}, cer={cer:.2f}, {elapsed:.1f}s)")
    avg_sim = sum(r["sim"] for r in results) / len(results)
    avg_cer = sum(r["cer"] for r in results) / len(results)
    avg_time = sum(r["time"] for r in results) / len(results)
    print(f"\n  AVG sim: {avg_sim:.3f}, CER: {avg_cer:.3f}, time: {avg_time:.1f}s")
    return {"model": name, "avg_sim": avg_sim, "avg_cer": avg_cer, "avg_time": avg_time, "results": results}

# ---- Models ----

def make_lightonocr():
    import torch
    from transformers import LightOnOcrForConditionalGeneration, LightOnOcrProcessor
    from PIL import Image

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = torch.float32  # MPS needs float32

    model = LightOnOcrForConditionalGeneration.from_pretrained(
        "lightonai/LightOnOCR-2-1B", torch_dtype=dtype
    ).to(device)
    processor = LightOnOcrProcessor.from_pretrained("lightonai/LightOnOCR-2-1B")

    def infer(img_path):
        conversation = [{"role": "user", "content": [{"type": "image", "url": img_path}]}]
        inputs = processor.apply_chat_template(
            conversation, add_generation_prompt=True, tokenize=True,
            return_dict=True, return_tensors="pt",
        )
        inputs = {k: v.to(device=device, dtype=dtype) if v.is_floating_point() else v.to(device) for k, v in inputs.items()}
        output_ids = model.generate(**inputs, max_new_tokens=512)
        generated = output_ids[0, inputs["input_ids"].shape[-1]:]
        return processor.decode(generated, skip_special_tokens=True)
    return infer

def make_glm_ocr():
    """GLM-OCR via the glmocr SDK"""
    from glmocr import GlmOcr
    ocr = GlmOcr(device="cpu")

    def infer(img_path):
        result = ocr.parse(img_path)
        return result.to_text() if hasattr(result, 'to_text') else str(result)
    return infer

def make_nanonets():
    import torch
    from transformers import AutoProcessor, AutoModelForImageTextToText
    from PIL import Image

    model_name = "nanonets/Nanonets-OCR-s"
    processor = AutoProcessor.from_pretrained(model_name, trust_remote_code=True)
    model = AutoModelForImageTextToText.from_pretrained(
        model_name, trust_remote_code=True, torch_dtype=torch.float32, device_map="cpu"
    )
    model.eval()

    def infer(img_path):
        img = Image.open(img_path).convert("RGB")
        messages = [{"role": "user", "content": [
            {"type": "image", "image": img},
            {"type": "text", "text": "Extract all the text from the image. Return only the raw text."},
        ]}]
        text_input = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        inputs = processor(text=[text_input], images=[img], return_tensors="pt", padding=True)
        output_ids = model.generate(**inputs, max_new_tokens=512)
        generated = output_ids[0, inputs["input_ids"].shape[-1]:]
        return processor.decode(generated, skip_special_tokens=True)
    return infer

def make_paddleocr():
    os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
    from paddleocr import PaddleOCR
    ocr = PaddleOCR(lang='en')

    def infer(img_path):
        raw = ocr.ocr(img_path)
        texts = []
        if raw and raw[0]:
            for line in raw[0]:
                if line and len(line) >= 2:
                    texts.append(line[1][0])
        return " ".join(texts)
    return infer

def make_trocr_large():
    from transformers import TrOCRProcessor, VisionEncoderDecoderModel
    from PIL import Image
    processor = TrOCRProcessor.from_pretrained("microsoft/trocr-large-handwritten")
    model = VisionEncoderDecoderModel.from_pretrained("microsoft/trocr-large-handwritten")
    model.eval()
    def infer(img_path):
        img = Image.open(img_path).convert("RGB")
        pv = processor(images=img, return_tensors="pt").pixel_values
        ids = model.generate(pv, max_new_tokens=256, num_beams=5)
        return processor.batch_decode(ids, skip_special_tokens=True)[0]
    return infer

def make_claude():
    import requests
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key: return None
    def infer(img_path):
        with open(img_path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        resp = requests.post("https://api.anthropic.com/v1/messages",
            headers={"x-api-key": api_key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
            json={"model": "claude-sonnet-4-20250514", "max_tokens": 256,
                  "messages": [{"role": "user", "content": [
                      {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64}},
                      {"type": "text", "text": "Read the handwritten text in this image. Return ONLY the text, nothing else."}]}]})
        if resp.status_code == 200: return resp.json()["content"][0]["text"]
        return f"ERROR: {resp.status_code}"
    return infer

def main():
    dataset = load_dataset()
    print(f"Loaded {len(dataset)} samples\n")
    all_results = []

    models = [
        ("TrOCR-large", make_trocr_large),
        ("PaddleOCR v5", make_paddleocr),
        ("LightOnOCR-2-1B", make_lightonocr),
        ("Nanonets-OCR-s (3B)", make_nanonets),
        ("Claude Sonnet Vision", make_claude),
    ]

    # Try GLM-OCR SDK
    try:
        models.insert(2, ("GLM-OCR (SDK)", make_glm_ocr))
    except:
        pass

    for name, make_fn in models:
        try:
            infer = make_fn()
            if infer is None:
                print(f"\n  SKIPPED: {name}")
                continue
            r = run_model(name, dataset, infer)
            all_results.append(r)
        except Exception as e:
            print(f"\n  {name} FAILED: {e}")
            import traceback; traceback.print_exc()

    print(f"\n{'='*60}\nSUMMARY\n{'='*60}")
    print(f"{'Model':<30} {'Sim':>6} {'CER':>6} {'Time':>7}")
    print("-" * 52)
    for r in sorted(all_results, key=lambda x: -x["avg_sim"]):
        print(f"{r['model']:<30} {r['avg_sim']:.3f} {r['avg_cer']:.3f} {r['avg_time']:>6.1f}s")
    with open("benchmark3_results.json", "w") as f:
        json.dump(all_results, f, indent=2)

if __name__ == "__main__":
    main()
