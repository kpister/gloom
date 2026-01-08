# LoomClone AGENTS Guide

Quick orientation for humans and coding agents working in this repo.

Overview
- macOS SwiftUI app that records screen + camera + mic (Loom clone).
- Screen capture uses ScreenCaptureKit; camera + mic via AVFoundation.
- Outputs are saved to `~/Movies/LoomClone` as `screen_*.mov`, `camera_*.mov`, `meta_*.json`.

Key entry points
- `LoomClone/LoomCloneApp.swift`: app entry, launches `ContentView`.
- `LoomClone/ContentView.swift`: circular UI, window styling, controls, timer rim animation.
- `LoomClone/CaptureEngine.swift`: recording state machine, capture pipeline, asset writers.

Recording pipeline (CaptureEngine.swift)
- `AppViewModel` orchestrates start/pause/resume/stop.
- `ScreenRecorder` wraps `SCStream` and feeds `ScreenAssetWriter`.
- `MicAudioCapture` captures mic samples; now prefers built-in mic to avoid Bluetooth encoder failures.
- `CameraController` captures camera samples to `CameraAssetWriter`.
- `PauseController` tracks pause offsets; used to adjust sample timing so A/V stays monotonic.
- `ScreenAssetWriter` waits briefly for audio format; after timeout can start video-only.

Encoder notes / pitfalls
- Screen capture uses `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` and forces even width/height.
- H.264 fails for very large frames; the writer auto-falls back to HEVC when max dimension > 4096.
- If `AVFoundationErrorDomain -11861` appears, check mic device and permissions; Bluetooth input can break the audio encoder.
- Logging uses `os.Logger` category `Capture` (search in Xcode console).

UI / window behavior
- Window is borderless, circular, and resizable; `CircleHitTestView` restricts clicks to the circle.
- `WindowAccessor` configures the `NSWindow` and keeps aspect ratio square.
- Plus/minus buttons resize the window; `resolveWindowForResize()` handles missing window refs.
- Timer rim: `TimelineView(.animation)` drives a dot around the rim once per minute with a faint trailing arc.
- Color smoothly interpolates through red → orange → yellow → green → teal → blue → purple, cycling each minute.

Permissions
- Screen Recording permission is required; app prompts and shows an overlay on failure.
- Camera and microphone permissions are requested on use.
- If Screen Recording is granted while running, the app must be restarted.

Where to add changes
- New capture features or output formats: `LoomClone/CaptureEngine.swift`.
- UI/UX changes for the circular overlay and controls: `LoomClone/ContentView.swift`.
- App-wide setup: `LoomClone/LoomCloneApp.swift`.

Testing
- No automated tests are wired for recording behavior.
- Validate by recording a short clip and confirming the `.mov` files play in QuickTime.
