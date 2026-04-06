# Quire

E-ink AI interface for Boox Go 10.3 2Lumi. Handwriting in, Claude out.

![Quire screenshot](assets/screenshot.png)

## Design

Infinite canvas with an elegant pen-and-paper aesthetic, optimised for e-ink stylus input.

### Tools

| Tool | Stylus | Touch |
|------|--------|-------|
| **Pen** | Draw strokes → detect → preview → send to Claude | Pan / pinch-zoom |
| **Select** | Draw selection rectangle / drag to move | Pan / pinch-zoom |

### Pen Flow

Write with the stylus. After a 2.5s pause, strokes are sent to the server for detection. The server renders strokes to an image, runs CRAFT text detection + connected component analysis to separate text from drawings, and OCR's the text via LightOnOCR-2-1B. Results appear as canvas annotations (digitised text above handwriting, bounding boxes around detected drawings).

A **countdown bar** appears below your writing: "sending to claude" with a 5-second timer and a pause button.

- **Auto-send**: if the countdown completes, strokes are sent to Claude automatically
- **Pause**: press the pause button to stop the countdown. The UI hides for 10 seconds (or while you keep writing). When you stop, a review prompt appears with an explicit send button
- **Review**: in review state, you can edit the digitised OCR text (tap to edit), reclassify regions, or manually trigger send
- **Streaming**: Claude's response appears word-by-word as it's generated
- **Response annotations**: draw on/near a Claude response to annotate it. The system detects overlap with existing responses, sends the original response text + annotation strokes (including a rendered image) to Claude for iteration. Countdown/send UI appears at the thread bottom. Annotations on rendered diagrams send the diagram image.
- **Render error feedback**: when LaTeX rendering fails, a spinner + error snippet shows on canvas while Claude retries (up to 5 rounds)
- **Session tracking**: writing near an existing response continues the same conversation
- **Parallel conversations**: write far enough apart horizontally to start a separate thread
- **Conversation labels**: each thread gets a letter tag (A, B, C...) shown on responses
- **Model picker**: choose between Sonnet, Opus, or Haiku in Settings
- **LaTeX/SVG detection**: mathematical notation (typing rules, equations) is automatically sent as an image so Claude sees the drawing directly
- **Tap-to-dot**: quick stylus taps register as dots (for colons, periods, punctuation)

### Selection

Draw a rectangle with the select tool, or drag inside an existing selection to move objects. Context menu:

- **To Text** — OCR selected strokes, replace with text object
- **Send** — send selected content to Claude (in review state)
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

**Detection pipeline** (per pen stroke batch):
1. Render strokes to image (Rust, `render.rs`)
2. CRAFT text detection → text region bounding boxes (Python, easyocr)
3. Group overlapping/nearby CRAFT boxes into clusters (LINE_GAP=80)
4. OCR each cluster individually with LightOnOCR-2-1B
5. If OCR returns LaTeX/HTML or garbled/repeated text → reclassify cluster as image region
6. Remaining ink pixels outside all clusters → drawing/image region
7. Merge overlapping/nearby image regions into one
8. **Viral absorption**: text surrounded by drawing ink on 3+ sides gets absorbed into the nearest image (labels inside diagrams become part of the drawing)
9. Results returned to Flutter for preview (OCR annotations + image bboxes)
10. On send: text sent as text to Claude, drawing regions cropped and sent as base64 images
11. Response streamed back via SSE; user-reviewed regions skip server-side detection

**Response rendering**: Claude is instructed via system prompt + `render_diagram` tool to never include LaTeX/SVG inline. When Claude calls the tool, the server renders via `pdflatex`/`rsvg-convert` → PNG and streams the image to the client as a `DiagramObject` on the canvas.

**Two-phase flow**: detection runs first via `POST /detect`, user reviews, then sends via `POST /chat/stream` with pre-classified regions.

### Coordinate system

Strokes stored in world space. Transform: `world = (screen - offset) / scale`. The render pipeline tracks coordinate mapping (`RenderResult` struct with `pixel_to_world` and `world_to_pixel`) so image-space bounding boxes from detection can be converted between coordinate spaces. Early pointer events captured in `Listener.onPointerDown` before gesture recognizer; stylus taps captured via `onTapUp` for dot/punctuation input.

## Structure

```
app/lib/
  main.dart                      # Entry, init Onyx SDK + settings
  theme/eink_theme.dart          # Serif, thin borders, pen-and-paper aesthetic
  models/canvas_object.dart      # StrokeObject, TextObject, ThinkingObject, ConversationThread,
                                 # OcrAnnotationObject, ImageBboxObject, DiagramObject
  screens/
    canvas_screen.dart           # Infinite canvas, pen flow state machine, preview UI, selection
    settings_screen.dart         # Backend config, model picker, debug toggle
    calibration_screen.dart      # OCR data collection (temporary scaffolding)
  services/
    settings_service.dart        # SharedPreferences persistence (incl. Claude model selection)
    ocr_service.dart             # HTTP client for /ocr
    chat_service.dart            # SSE streaming client for /chat/stream, detection client for /detect
    render_service.dart          # HTTP client for /render (LaTeX/SVG → PNG)
    debug_service.dart           # Trace logging, screenshots, canvas dumps
  utils/
    response_parser.dart         # Split Claude responses into markdown/latex/svg segments

server/
  src/main.rs                    # Axum server: /ocr, /chat, /chat/stream, /detect, /render, /debug, /screenshot, /canvas-dump
  src/ocr.rs                     # OCR sidecar client (recognize + detect)
  src/claude.rs                  # Claude API client (sync + streaming)
  src/render.rs                  # Stroke-to-image rendering + LaTeX/SVG → PNG via pdflatex/rsvg-convert
  src/log.rs                     # Structured JSON logging to file
  ocr/server.py                  # OCR sidecar: LightOnOCR + CRAFT text detection + cluster-based classification
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

Enable in Settings. The app pushes trace events on every interaction (tool switch, stroke, OCR, Claude response) to `POST /debug`. Screenshot button captures canvas + state dump.

**Debug artifacts** (stored on the machine running the Rust server):
- `server/quire_server.log` — structured JSON log of every event: detection results, render requests/errors, tool use rounds, Claude responses, client debug traces
- `server/quire_screenshots/` — PNG screenshots captured via the debug button, named by timestamp. These show the full canvas state including strokes, responses, bounding boxes. Useful for diagnosing detection/rendering issues.
- `server/quire_dumps/` — JSON dumps of all canvas objects (strokes with bboxes, text objects with full response text, annotations, image bboxes, diagrams). Captured alongside screenshots. Useful for inspecting what objects are on canvas and their positions/content.

When debugging an issue: check the latest screenshot to see what the user saw, the dump to see the object state, and the log to trace the detection → classification → Claude → render pipeline.

## TODO

- [x] LaTeX/SVG rendering via `render_diagram` tool use (system prompt, tool loop, DiagramObject)
- [x] Per-cluster OCR detection (CRAFT box clustering, individual OCR, LaTeX auto-reclassify)
- [x] Viral image absorption (text surrounded by drawing ink on 3+ sides → absorbed into image)
- [x] Image region merging (overlapping/nearby image bboxes merged into one)
- [x] Reclassify context menu: → Text, → Image, Merge (for multiple image bboxes)
- [x] Garbled OCR detection (repeated patterns → classify as image)
- [x] Response annotations: detect strokes near responses, send with context, thread-bottom UI
- [x] Render error feedback: spinner + error snippet on canvas during retries
- [x] Buffer-aware auto-send: re-detects if user drew more strokes since last detection
- [ ] Geometry-preserving annotation composites (strikethrough, arrows, inline comments as image)
- [ ] OCR annotations as child objects: bound to parent strokes, editable via keyboard, move/delete with parent
- [ ] HTML rendering in responses
- [ ] Code execution blocks: runnable Python sandbox on server, Run button, stdout/stderr display
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
- `tempfile` — temp dirs for LaTeX/SVG rendering
- `serde` / `serde_json` — serialization
- `uuid` — session IDs
- `chrono` — timestamps

### OCR Sidecar
- `transformers` >= 5.0 — LightOnOCR model
- `torch` — inference
- `easyocr` — CRAFT text detection
- `scipy` — connected component analysis
- `Pillow` / `numpy` — image processing
