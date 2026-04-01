# Quire

E-ink AI interface for Boox Go 10.3 2Lumi. Handwriting in, Claude out.

## Design

Infinite canvas with an elegant pen-and-paper aesthetic, optimised for e-ink stylus input.

### Tools

| Tool | Stylus | Touch |
|------|--------|-------|
| **Pen** | Draw strokes | Pan / pinch-zoom |
| **Select** | Draw selection rectangle / drag to move | Pan / pinch-zoom |
| **Claude** | Write → debounce (2.5s) → OCR → Claude → response below | Pan / pinch-zoom |

### Claude Pen

Write with the stylus. After a 2.5s pause, strokes are batched, OCR'd locally via LightOnOCR-2-1B, sent to Claude, and the response is inserted below your handwriting. A thinking indicator (shaking star + rotating words) shows while waiting.

- **Session tracking**: writing near an existing response continues the same conversation
- **Parallel conversations**: write far enough apart horizontally to start a separate thread

### Selection

Draw a rectangle with the select tool, or drag inside an existing selection to move objects. Context menu:

- **To Text** — OCR selected strokes, replace with text object
- **Move** — enter move mode for stylus drag
- **Delete** — remove selected objects

Tap a Claude response to view the OCR'd source text.

### Architecture

```
Flutter App (Boox)
  ↕ HTTP over USB (adb reverse)
Rust Server (axum, :8080)
  ↕ HTTP (:8090)
Python OCR Sidecar (LightOnOCR-2-1B + bbox variant, persistent daemon)
  ↕ HTTPS
Claude API (Anthropic)
```

### Coordinate system

Strokes stored in world space. Transform: `world = (screen - offset) / scale`. Early pointer events captured in `Listener.onPointerDown` before gesture recognizer to prevent stroke start clipping.

## Structure

```
my_dear_watson/lib/
  main.dart                      # Entry, init Onyx SDK + settings
  theme/eink_theme.dart          # Serif, thin borders, pen-and-paper aesthetic
  models/canvas_object.dart      # StrokeObject, TextObject, ThinkingObject, ConversationThread
  screens/
    canvas_screen.dart           # Infinite canvas, tools, selection, Claude pen
    settings_screen.dart         # Backend config, debug toggle, OCR calibration
    calibration_screen.dart      # OCR data collection (temporary scaffolding)
  services/
    settings_service.dart        # SharedPreferences persistence
    ocr_service.dart             # HTTP client for /ocr
    chat_service.dart            # HTTP client for /chat
    debug_service.dart           # Trace logging, screenshots, canvas dumps

server/
  src/main.rs                    # Axum server: /ocr, /chat, /detect, /debug, /screenshot, /canvas-dump
  src/ocr.rs                     # LightOnOCR sidecar client
  src/claude.rs                  # Claude API client
  src/render.rs                  # Stroke-to-image rendering
  src/log.rs                     # Structured JSON logging to file
  ocr/server.py                  # LightOnOCR persistent sidecar daemon
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
cd my_dear_watson
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb reverse tcp:8080 tcp:8080
adb shell am start -n com.example.quire/.MainActivity
```

### Debug mode

Enable in Settings. The app pushes trace events on every interaction (tool switch, stroke, OCR, Claude response) to `POST /debug`. Screenshot button captures canvas + state dump. Server logs everything to `quire_server.log`.

## TODO

- [ ] Text vs diagram detection: use LightOnOCR-2-1B-bbox to detect image regions, show boxes on UI for user adjustment, auto-send after 2s if unambiguous
- [ ] Mixed messages to Claude: text regions as text, diagram regions as images
- [ ] Annotations on Claude responses: write near/over responses, local OCR, send as feedback for iteration
- [ ] Streaming responses: Claude output appears word by word
- [ ] Response insertion: shift content without jumping pen position when response arrives mid-writing
- [ ] LaTeX/SVG/HTML rendering in responses
- [ ] Code execution blocks: runnable Python sandbox on server, Run button, stdout/stderr display, draggable
- [ ] Image input: send diagrams/drawings as images to Claude
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
- `http` — HTTP client
- `path_provider` — device storage

### Server
- `axum` — HTTP server
- `reqwest` — HTTP client (Claude API, OCR sidecar)
- `image` — stroke rendering
- `serde` / `serde_json` — serialization
- `uuid` — session IDs
- `chrono` — timestamps

### OCR Sidecar
- `transformers` >= 5.0 — LightOnOCR model
- `torch` — inference
- `Pillow` — image processing
