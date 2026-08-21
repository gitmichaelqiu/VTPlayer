# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build (Debug)
xcodebuild -project VTPlayer.xcodeproj -scheme VTPlayer -configuration Debug build

# Build (Release)
xcodebuild -project VTPlayer.xcodeproj -scheme VTPlayer -configuration Release build

# Run from Xcode (requires GUI)
open VTPlayer.xcodeproj
```

## Build Verification Order and CoreSimulator Recovery

Verify the native macOS target first; it does not require an iOS Simulator runtime:

```bash
xcodebuild -project VTPlayer.xcodeproj -scheme VTPlayer -configuration Debug \
  -sdk macosx -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

For iOS Simulator verification, first check that a runtime is installed:

```bash
xcrun simctl list runtimes
```

If no iOS runtime is listed, install the matching runtime through Xcode:

```bash
xcodebuild -downloadPlatform iOS
```

Then launch Xcode once (or `open -a Simulator` on a normal macOS installation) and retry `xcrun simctl list devices`. If it still reports `CoreSimulatorService connection became invalid`, check the launchd registration:

```bash
launchctl print gui/$(id -u)/com.apple.CoreSimulator.CoreSimulatorService
```

If the service is missing from launchd and `simdiskimaged` cannot be started, restarting the user login session or macOS is the next safe recovery step. If the service remains absent after reboot, repair or reinstall Xcode/macOS simulator components; deleting the per-user `~/Library/Developer/CoreSimulator/Devices` directory is not a first-line fix.

The app is built on Apple SDKs (SwiftUI, VideoToolbox, Metal, CoreImage, AVFoundation) and uses Sparkle for macOS update delivery.

## Project Architecture

macOS app that uses Apple's `VTLowLatencySuperResolution` and `VTLowLatencyFrameInterpolation` (VideoToolbox) to upscale and interpolate video in real time on Apple Silicon Neural Engine.

### File Layout

| File | Role |
|------|------|
| `VTPlayerApp.swift` | `@main` entry point, SwiftUI `WindowGroup` |
| `ContentView.swift` | Root view, hosts `VTPlayerView` |
| `Playback/VTPlayerViewModel.swift` | `@Observable @MainActor` playback state, enhancement selections, diagnostics, and cache policy. |
| `Playback/VTPlayerPlayback.swift` | Play/pause, seek, producer/consumer scheduling, enhancement restarts, and presentation handoff. |
| `Playback/EnhancedAudioPlayer.swift` | Audio-only AVPlayer transport anchored to the first rendered enhanced-frame PTS. |
| `Views/VTPlayerView.swift` and `Views/` subdirectories | Root view plus platform-specific macOS/iOS player, settings, diagnostics, and support views. |
| `VTFramePipeline.swift` | AsyncSequence-based video frame reader (AVAssetReader). Yields `VTFrame` (CVPixelBuffer + CMTime). Thread-safe via inner actor `StateLock`. |
| `VTFrameProcessorCoordinator.swift` | `actor` that orchestrates VideoToolbox sessions. Manages chained processing: denoise → spatial (2x → 4x) → temporal → motion blur. Creates pixel buffer pools for each stage. Has two complete implementations behind `#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)` (real) / `#else` (stub). |
| `VTMetalRenderer.swift` | `MTKView` subclass that renders CVPixelBuffer via Core Image → Metal texture pipeline. Applies CIUnsharpMask (sharpness) and CIExposureAdjust + CIColorControls (SDR-to-HDR boost). Aspect-ratio-locked scaling with black letterboxing. |
| `VTModelManager.swift` | `@Observable` Quality SR model readiness/download state used by settings and playback validation. |

### Video Processing Pipeline

```
VTFrameSequence (AVAssetReader) → VTFrameProcessorCoordinator (actor)
                                                       ↓
                                            Pipeline stages (ordered):
                                            1. Denoise (VTTemporalNoiseFilter)
                                            2. Spatial (LL SR / Quality SR)   ← BEFORE temporal
                                            3. Temporal (LL FI / Combined)    ← AFTER spatial
                                            4. Motion Blur (VTMotionBlur)
                                                       ↓
                                            VTMetalRenderer (MTKView + CIContext)
```

**Important**: Spatial stage runs BEFORE temporal. Combined mode (SR=2/FI=2) uses `VTLowLatencyFrameInterpolationConfiguration(spatialScaleFactor:)` for single-pass 2x spatial + 2x temporal in the temporal stage. SR=4 cascades a second 2x LL SR (or VTPixelTransferSession fallback) inside the spatial stage. Quality SR (`VTSuperResolutionScaler`) runs instead of LL SR in the spatial stage when `qualitySuperResolutionScaleFactor > 0`.

Processing runs in three `Task`s on `@MainActor`:
- **Producer**: Reads frames from VTFrameSequence (AVAssetReader — decodes faster than real-time), processes through the VideoToolbox pipeline stages in order, populates the frame cache
- **Consumer**: Reads processed frames from the cache in PTS order, renders via Metal, with PTS-aware pacing (wakes just before the next frame is due)
- **Audio**: Native playback uses the main AVPlayer. Enhanced playback mutes only the main player's audio and uses an audio-only AVPlayer transport anchored when the first processed frame is rendered.

The `VTFrameProcessorCoordinator` is an `actor`, so its methods run on its own executor.

### Configuration Modes

- **Super Resolution**: 0 (off), 2 (2x), 4 (4x cascaded: 2x → 2x) — LL SR via `VTLowLatencySuperResolutionScaler`
- **Quality Super Resolution**: 0 (off), 2, 4 — Quality SR via `VTSuperResolutionScaler` (requires model download)
- **Frame Interpolation**: 0 (off), 2 (2x = 1 interpolated frame), 4 (4x = 3 interpolated frames) — LL FI via `VTLowLatencyFrameInterpolation`
- **Combined mode**: SR=2/FI=2 uses `VTLowLatencyFrameInterpolationConfiguration(spatialScaleFactor:)` for single-pass 2x spatial + 2x temporal. SR=4/FI=2 adds a second spatial stage.
- **Motion Blur**: 0 (off), 1-30 in the UI — VTMotionBlur post-process with conservative limits to avoid darkening/artifacts
- **Denoise**: 0.0-1.0 — VTTemporalNoiseFilter, uses 2 previous frames as reference
- **Sharpness**: 0.0-2.0 — CIUnsharpMask applied in the Metal renderer (radius hardcoded at 0.5). Interpolated frames get boosted sharpness (`max(sharpness, 1.25)`).
- **SDR-to-HDR Boost**: 0.0-2.0 — CIExposureAdjust + CIColorControls (saturation, contrast) applied in the Metal renderer. Not a true tone map — luminance expansion into display EDR headroom requires custom Metal shaders (deferred).
- **Fallback**: When second-stage SR scaler is unsupported (certain resolutions), falls back to `VTPixelTransferSession` with configurable scaling quality.

### Key Concurrency Patterns

- `VTFrameProcessorCoordinator` is an `actor` — all state mutations are actor-isolated
- `VTPlayerViewModel` is `@MainActor` — all state updates on main thread
- Produce/consume tasks both inherit `@MainActor` (created from `@MainActor` context)
- `VTFrame` is `@unchecked Sendable` (CVPixelBuffer is not Sendable but is thread-safe via retain counting)

### VideoToolbox APIs Used

- `VTLowLatencySuperResolutionScalerConfiguration` — query support + configure
- `VTLowLatencyFrameInterpolationConfiguration` — temporal interpolation (with optional spatialScaleFactor for combined mode)
- `VTFrameProcessor` — session lifecycle + frame processing
- `VTPixelTransferSession` — fallback scaling when SR scaler unavailable for a given resolution
- `VTTemporalNoiseFilterConfiguration` / `VTTemporalNoiseFilterParameters` — temporal denoise
- `VTMotionBlurConfiguration` / `VTMotionBlurParameters` — motion blur post-process
- `VTSuperResolutionScalerConfiguration` / `VTSuperResolutionScalerParameters` — Quality SR (requires ML model download)

## Multi-Platform Architecture

The app targets **macOS** and **iOS/iPadOS** with substantial platform-specific code behind `#if os()` blocks.

### Navigation Patterns

- **macOS**: `NavigationSplitView` — left sidebar (file open, recents list) + center (video player + floating control bar) + right inspector (diagnostics, metadata, model status). Native `NSSplitView` handles column resize and animation. Fullscreen hides sidebars.
- **iOS**: `NavigationStack` → `TabView` with **Gallery** (recents grid + Browse Files + Photos Library import) and **About** tabs. Pushes to player view when a video is opened. No sidebar — settings in modal sheet.

### iOS-specific Components

- `CustomAVPlayerViewController` — transparent overlay of native `AVPlayerViewController` controls over `VTMetalRendererView`. Hides the native `AVPlayerLayer` when pipeline is active. Monitors control visibility via private UIView introspection (0.1s timer). Programmatically disables native fullscreen button.
- `NativeVideoPlayer` (`UIViewControllerRepresentable`) — wraps `CustomAVPlayerViewController`, pipes control visibility to SwiftUI.
- `VideoThumbnailView` — `AVAssetImageGenerator`-based thumbnail extraction at 1s for the recents grid.
- `PhotosMovie` (`Transferable`) — imports videos from Photos library via `PhotosPicker`, copies to temp directory.

### Platform Conditionals

- `#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)` — real VideoToolbox coordinator impl; `#else` stubs all methods returning empty/no-op
- `#if os(macOS)`: `NSVisualEffectView`, `NSDocumentController` for recents, `CVDisplayLink`, `NSCursor` hide/show, `NSWindow` fullscreen notifications
- `#if os(iOS)`: `CADisplayLink`, `PhotosUI`, `UIApplication` open settings, `UIImpactFeedbackGenerator`
- `isPipelineActive` — on both macOS and iOS it is gated on active processing enhancements (`SR`, `FI`, `QSR`, denoise, motion blur, or HDR boost). Native AVPlayer presentation remains available when all processing enhancements are off.

## Per-Video Settings Persistence

Settings (SR level, FI level, QSR level, MB, DN, sharpness, HDR boost, and HDR colorfulness) are saved to `UserDefaults` on pause/stop and loaded when a video is opened. Continue-video preference and frame-cache memory budget are also persisted.

## Pipeline Restart on Enhancement Change

`updateEnhancements()` is called whenever any enhancement slider changes. It tears down and restarts the entire processing pipeline (stops producer/consumer tasks, ends coordinator session, reconfigures, restarts). This causes a brief playback interruption (~100-300ms) on every setting change.

## Enhancement-Applied State

`VTMetalRenderer` properties (`sharpness`, `hdrStrength`) are applied immediately via `didSet` — they don't require pipeline restart. The renderer boosts sharpness for interpolated frames: `max(sharpness, 1.25)` when `isInterpolated` is true.

## Known Issues & Gotchas

- **ANE usage not measurable**: No public API to query ANE utilization; `aneUsagePercent` is a placeholder at 0
- **Capability filtering**: Unsupported SR/FI/QSR combinations are removed from menus; internal capability details are not presented as user-facing playback errors.
- **Large file**: `VTPlayerView.swift` bundles ViewModel + all views + helpers (~2958 lines)
- **Sidebar resize**: Uses NavigationSplitView with 3 columns. Column widths constrained via `.frame(minWidth:idealWidth:maxWidth:)`. Native NSSplitView handles resize and animation.
- **Project targets**: Build settings include iOS/visionOS SDKs — iOS UI is active (Gallery, About, NativeVideoPlayer overlay); visionOS is buildable but untested
- **Consumer polling**: The consumer uses PTS-aware pacing, falling back to 4ms poll when cache is empty. Not ideal for power, but acceptable for real-time video
- **Audio sync**: Enhanced audio is an independent audio-only AVPlayer anchored to rendered PTS. Native playback keeps AVPlayer's normal audio path. Explicit seeks, restarts, pause/resume, and enhancement changes re-anchor or recreate the enhanced audio transport.
- **Motion Blur darkening (fixed)**: Original bug double-weighted the same frame for next+previous references. Fixed by using sourceFP as next frame. Values capped to 30 in UI.
- **FRC removed**: VTFrameRateConversion was removed — requires frame lookahead unavailable in frame-at-a-time pipeline
- **VTFrameSequence seeks**: Producer recreates VTFrameSequence iterator on seek (checks `lastPulledTime` changes). Rapid seeks may briefly re-read frames
- **Per-video settings**: Saved on pause/stop, loaded on video open. Not saved on window close (deinit is nonisolated)
- **FI destinationFrames (fixed)**: Pure FI mode must include the source frame in `destinationFrames` array — the processor only outputs what's in `destinationFrames`, so the source frame must be listed last. Combined mode omits the source frame (the interpolated + spatially-upconverted output replaces it). The fix was added but verify if reverted.

## Pending / Deferred Features

- **SDR-to-HDR tone mapping (partial)**: Current CI-based exposure/saturation/contrast boost is a stopgap. True tone mapping requires custom Metal shaders for luminance range expansion into display EDR capability. No VTFrameProcessor API exists for this.
- **Metal adaptive sharpen**: Replace CIUnsharpMask with a per-pixel luminance-aware custom Metal shader for better quality and performance.
- **Quality/resource limits**: High-resolution FI/QSR combinations remain hardware- and memory-dependent; the cache budget is a hard cap and no quality-reducing fallback is used.
- **Contrast boost**: Dedicated contrast parameter separate from the all-in-one HDR boost slider.
- **Adjustable sharpen radius**: Sharpness radius currently hardcoded at 0.5 in CIUnsharpMask.
- **VTModelManager integration**: Quality SR readiness/download status is surfaced before playback and in diagnostics; model availability still depends on the OS and device.

## Coding Styles

For each of the work down, git commit it with conventional commits. Commit the work one by one, but not all at once. Notice that you should commit using my information, and you are not allowed to add any coauthor info. You should only commit the progress, but not push it to remote.

### Conventional Commits

- feat: A new feature introduced for the user.
- fix: A bug fix.
- docs: Documentation only changes.
- refactor: Code changes that neither fix a bug nor add a feature.
- perf: A code change that improves performance.
- test: Adding missing tests or correcting existing tests.
- chore: Changes to the build process or auxiliary tools (e.g., updating dependencies).

### Guide on Annotations

Do not write your thinking processes in the code. Do not insert too much text. Keep the annotations simple and readable. Do not repeat yourself. Only annotate when necessary.
