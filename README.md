# Quire

E-ink AI interface for Boox Go 10.3 2Lumi. Handwriting in, Claude out.

![Quire screenshot](assets/screenshot.png)

## Design

Infinite canvas with an elegant pen-and-paper aesthetic, optimised for e-ink stylus input.

### Tools

| Tool | Stylus | Touch |
|------|--------|-------|
| **Pen** | Draw strokes | Pan / pinch-zoom |
| **Select** | Draw selection rectangle / drag to move | Pan / pinch-zoom |
| **Claude** | Write → debounce (2.5s) → OCR → Claude → streaming response below | Pan / pinch-zoom |

### Claude Pen

Write with the stylus. After a 2.5s pause, strokes are batched and sent to the server. The server renders strokes to an image, runs CRAFT text detection + connected component analysis to separate text from drawings, OCR's the text via LightOnOCR-2-1B, and sends text + any detected drawing images to Claude. The response streams back word-by-word via SSE.

- **Streaming**: responses appear incrementally as Claude generates them
- **Session tracking**: writing near an existing response continues the same conversation
- **Parallel conversations**: write far enough apart horizontally to start a separate thread
- **Conversation labels**: each thread gets a letter tag (A, B, C...) shown on responses
- **Canvas annotations**: OCR'd text shown in light italic above your handwriting; detected drawing regions outlined with a bounding box
- **Model picker**: choose between Sonnet, Opus, or Haiku in Settings
- **Phantom stroke filter**: rejects EMR digitizer noise (extremely horizontal strokes)

### Selection

Draw a rectangle with the select tool, or drag inside an existing selection to move objects. Context menu:

- **To Text** — OCR selected strokes, replace with text object
- **Move** — enter move mode for stylus drag
- **Delete** — remove selected objects

Tap a Claude response to view the OCR'd source text.

### Architecture

```
Flutter App (Boox)
  ↕ SSE over HTTP/USB (adb reverse)
Rust Server (axum, :8080)
  ↕ HTTP (:8090)
Python OCR Sidecar (LightOnOCR-2-1B + CRAFT, persistent daemon)
  ↕ HTTPS
Claude API (Anthropic)
```

**Detection pipeline** (per Claude pen request):
1. Render strokes to image (Rust, `render.rs`)
2. CRAFT text detection → text region bounding boxes (Python, easyocr)
3. Connected component analysis on ink pixels (scipy)
4. Components inside CRAFT boxes or on the same horizontal line → text
5. Remaining components → drawing/image regions
6. LightOnOCR-2-1B → OCR text (Python)
7. Text sent as text to Claude, drawing regions cropped and sent as base64 images
8. Response streamed back via SSE with metadata (session ID, OCR text, detected regions with world-space bounding boxes)

### Coordinate system

Strokes stored in world space. Transform: `world = (screen - offset) / scale`. The render pipeline tracks coordinate mapping (`RenderResult` struct) so image-space bounding boxes from detection can be converted back to world coordinates for canvas annotations. Early pointer events captured in `Listener.onPointerDown` before gesture recognizer to prevent stroke start clipping.

## Structure

```
app/lib/
  main.dart                      # Entry, init Onyx SDK + settings
  theme/eink_theme.dart          # Serif, thin borders, pen-and-paper aesthetic
  models/canvas_object.dart      # StrokeObject, TextObject, ThinkingObject, ConversationThread,
                                 # OcrAnnotationObject, ImageBboxObject
  screens/
    canvas_screen.dart           # Infinite canvas, tools, selection, Claude pen, annotations
    settings_screen.dart         # Backend config, model picker, debug toggle
    calibration_screen.dart      # OCR data collection (temporary scaffolding)
  services/
    settings_service.dart        # SharedPreferences persistence (incl. Claude model selection)
    ocr_service.dart             # HTTP client for /ocr
    chat_service.dart            # SSE streaming client for /chat/stream, fallback /chat
    debug_service.dart           # Trace logging, screenshots, canvas dumps

server/
  src/main.rs                    # Axum server: /ocr, /chat, /chat/stream, /detect, /debug, /screenshot, /canvas-dump
  src/ocr.rs                     # OCR sidecar client (recognize + detect)
  src/claude.rs                  # Claude API client (sync + streaming)
  src/render.rs                  # Stroke-to-image rendering with coordinate mapping (RenderResult)
  src/log.rs                     # Structured JSON logging to file
  ocr/server.py                  # OCR sidecar: LightOnOCR + CRAFT text detection + image region detection
  ocr/requirements.txt           # Python deps

ocr_benchmark/                   # OCR model benchmarking scripts
```

## Dev

```bash
# 1. Start OCR sidecar (stays running, keeps models in memory)
cd server && source ocr/.venv/bin/activate
python3 ocr/server.py --preload

# 2. Start Rust server (in another terminal)
cd server && ANTHROPIC_API_KEY=sk-... cargo run --release

# 3. Build and deploy Flutter app
cd app
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb reverse tcp:8080 tcp:8080
adb shell am start -n com.example.quire/.MainActivity
```

### Debug mode

Enable in Settings. The app pushes trace events on every interaction (tool switch, stroke, OCR, Claude response) to `POST /debug`. Screenshot button captures canvas + state dump. Server logs everything to `quire_server.log`.

## TODO

- [ ] Annotations on Claude responses: write near/over responses, local OCR, send as feedback for iteration
- [ ] LaTeX/SVG/HTML rendering in responses
- [ ] Code execution blocks: runnable Python sandbox on server, Run button, stdout/stderr display, draggable
- [ ] Pre-send grouping preview: show bounding box around pending strokes, auto-partition text vs diagrams, contextual menu to adjust, postpone send until resolved
- [ ] Prompt buttons: render Claude confirmations as tappable buttons on canvas
- [ ] Conversation trees: branch conversations with drawn lines between threads
- [ ] Agentic SDK integration for tool use
- [ ] Modular/extensible UI architecture

## Dependencies

### Flutter
- `perfect_freehand` — pressure-sensitive stroke rendering
- `onyxsdk_pen` — Boox hardware pen acceleration
- `shared_preferences` — settings persistence
- `http` — HTTP client (SSE streaming)
- `path_provider` — device storage

### Server
- `axum` — HTTP server (incl. SSE)
- `reqwest` — HTTP client (Claude API, OCR sidecar)
- `futures` / `tokio-stream` — streaming support
- `image` — stroke rendering
- `serde` / `serde_json` — serialization
- `uuid` — session IDs
- `chrono` — timestamps

### OCR Sidecar
- `transformers` >= 5.0 — LightOnOCR model
- `torch` — inference
- `easyocr` — CRAFT text detection
- `scipy` — connected component analysis
- `Pillow` / `numpy` — image processing
