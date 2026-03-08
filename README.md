# Gloom

A simple, open-source macOS screen recorder with a floating camera bubble — like Loom, but local and free.

<!-- opi-badges-start -->
![claude-opus-4-6](https://img.shields.io/badge/claude--opus--4--6-31.4K_in_|_6.0K_out-blue)
![openai](https://img.shields.io/badge/openai-2.2M_total-blue)
<!-- opi-badges-end -->

Gloom records your screen, camera, and microphone into a `.mov` file. Your camera feed appears in a draggable, resizable circular bubble that floats on top of everything. No accounts, no cloud uploads — recordings stay on your machine.

## Features

- **Screen recording** via ScreenCaptureKit
- **Camera bubble** — circular, borderless, always-on-top window showing your webcam
- **Microphone capture** with smart device selection (prefers built-in mic over Bluetooth)
- **Pause / Resume** without dropping frames
- **Animated timer ring** that cycles colors each minute so you can see elapsed time at a glance
- **Adaptive codec** — uses H.264 by default, falls back to HEVC for displays wider than 4096px
- **Metadata logging** — records bubble position/size to a JSON sidecar file
- **Zero dependencies** — pure SwiftUI + native Apple frameworks

## Requirements

- macOS 15.0 (Sequoia) or later
- Xcode 13.2+ (to build from source)

## Getting Started

```bash
# Clone the repo
git clone https://github.com/kpister/gloom.git
cd gloom

# Open in Xcode and run
open Gloom.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -scheme Gloom -configuration Release build
```

On first launch the app will request three permissions:

| Permission | Why |
|---|---|
| **Screen Recording** | Required to capture your display. Must be granted in System Settings > Privacy & Security > Screen Recording. The app needs a restart after granting this. |
| **Camera** | Shows your webcam in the floating bubble. |
| **Microphone** | Records narration audio. If denied, recording continues as video-only. |

## Usage

The app appears as a small circular window. Controls are arranged around the ring:

- **Top** — Play / Pause
- **Right** — Zoom in (grow the bubble)
- **Bottom-right** — Zoom out (shrink the bubble)
- When paused, **Stop** and **Restart** buttons appear

Drag the bubble anywhere on screen. Recordings are saved to:

```
~/Movies/Gloom/
  screen_YYYYMMDD_HHmmss.mov   # the recording
  meta_YYYYMMDD_HHmmss.json    # bubble position/size events
```

## Output Format

| Property | Value |
|---|---|
| Container | QuickTime `.mov` |
| Video codec | H.264 (or HEVC for large displays) |
| Video bitrate | 12 Mbps |
| Frame rate | 30 fps |
| Audio codec | AAC, 128 kbps |

## Project Structure

```
Gloom/
  GloomApp.swift        # App entry point
  ContentView.swift      # Circular UI, window styling, controls, timer animation
  CaptureEngine.swift    # Recording state machine, capture pipeline, asset writers
```

## License

[MIT](LICENSE)
