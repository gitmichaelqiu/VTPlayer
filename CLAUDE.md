# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build (Debug)
xcodebuild -project VTPlayer.xcodeproj -scheme VTPlayer -configuration Debug build

# Build (Release)
xcodebuild -project VTPlayer.xcodeproj -scheme VTPlayer -configuration Release build

# Run from Xcode (requires GUI)
open VTPlayer.xcodeproj
```

No third-party dependencies — pure Apple SDKs (SwiftUI, VideoToolbox, Metal, CoreImage, AVFoundation).

## Project Architecture

macOS app that uses Apple's `VTLowLatencySuperResolution` and `VTLowLatencyFrameInterpolation` (VideoToolbox) to upscale and interpolate video in real time on Apple Silicon Neural Engine.

### File Layout

| File | Role |
|------|------|
| `VTPlayerApp.swift` | `@main` entry point, SwiftUI `WindowGroup` |
| `ContentView.swift` | Root view, hosts `VTPlayerView` |
| `VTPlayerView.swift` | Main UI + ViewModel (~1136 lines). **Should be split**: ViewModel, views, helpers all in one file. |
| `VTFramePipeline.swift` | AsyncSequence-based video frame reader (AVAssetReader). Yields `VTFrame` (CVPixelBuffer + CMTime). |
| `VTFrameProcessorCoordinator.swift` | `actor` that orchestrates VideoToolbox sessions. Manages chained processing: temporal interpolation → spatial upscaling (2x → 4x). Creates pixel buffer pools for each stage. |
| `VTMetalRenderer.swift` | `MTKView` subclass that renders CVPixelBuffer via Core Image → Metal texture pipeline. Aspect-ratio-locked scaling with black letterboxing. |
| `VTModelManager.swift` | `@Observable` class for downloading ML model weights. **Not wired into main playback flow.** |

### Video Processing Pipeline

```
VTFrameSequence (AVAssetReader) → VTFrameProcessorCoordinator (actor)
                                                       ↓
                                            Pipeline stages (ordered):
                                            1. Denoise (VTTemporalNoiseFilter)
                                            2. Temporal (LL FI / Combined)
                                            3. Spatial (LL SR / Quality SR)
                                            4. Motion Blur (VTMotionBlur)
                                                       ↓
                                            VTMetalRenderer (MTKView + CIContext)
```

Processing runs in three `Task`s on `@MainActor`:
- **Producer**: Reads frames from VTFrameSequence (AVAssetReader — decodes faster than real-time), processes through the VideoToolbox pipeline stages in order, populates the frame cache
- **Consumer**: Reads processed frames from the cache in PTS order, renders via Metal, with PTS-aware pacing (wakes just before the next frame is due)
- **Audio Sync**: Monitors the gap between AVPlayer time and last rendered frame PTS; pauses AVPlayer when latency exceeds 100ms, resumes when 5+ frames are buffered

The `VTFrameProcessorCoordinator` is an `actor`, so its methods run on its own executor.

### Configuration Modes

- **Super Resolution**: 0 (off), 2 (2x), 4 (4x cascaded: 2x → 2x) — LL SR via `VTLowLatencySuperResolutionScaler`
- **Quality Super Resolution**: 0 (off), 2, 4 — Quality SR via `VTSuperResolutionScaler` (requires model download)
- **Frame Interpolation**: 0 (off), 2 (2x = 1 interpolated frame), 4 (4x = 3 interpolated frames) — LL FI via `VTLowLatencyFrameInterpolation`
- **Combined mode**: SR=2/FI=2 uses `VTLowLatencyFrameInterpolationConfiguration(spatialScaleFactor:)` for single-pass 2x spatial + 2x temporal. SR=4/FI=2 adds a second spatial stage.
- **Motion Blur**: 0 (off), 1-30 — VTMotionBlur post-process (capped at 30 to avoid extreme darkening)
- **Denoise**: 0.0-1.0 — VTTemporalNoiseFilter, uses 2 previous frames as reference
- **Sharpness**: 0.0-2.0 — CIUnsharpMask applied in the Metal renderer
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

## Known Issues & Gotchas

- **ANE usage not measurable**: No public API to query ANE utilization; `aneUsagePercent` is a placeholder at 0
- **VTModelManager unused**: Class exists but is never called from the playback flow
- **Large file**: `VTPlayerView.swift` bundles ViewModel + all views + helpers (~1300 lines)
- **Project targets**: Build settings include iOS/visionOS SDKs but UI is macOS-only (AppKit-based)
- **Consumer polling**: The consumer uses PTS-aware pacing, falling back to 4ms poll when cache is empty. Not ideal for power, but acceptable for real-time video
- **Audio sync**: `audioSyncTask` pauses AVPlayer when frame processing latency exceeds 100ms. Resets on seek. May interact poorly with `playbackSpeed` changes
- **Motion Blur darkening**: VTMotionBlur blends frames which darkens output. Capped to max 30 in UI to limit effect
- **FRC removed**: VTFrameRateConversion was removed — requires frame lookahead unavailable in frame-at-a-time pipeline
- **VTFrameSequence seeks**: Producer recreates VTFrameSequence iterator on seek (checks `lastPulledTime` changes). Rapid seeks may briefly re-read frames
- **Per-video settings**: Saved on pause/stop, loaded on video open. Not saved on window close (deinit is nonisolated)

## Pending Features

- **SDR-to-HDR tone mapping**: Requires custom Metal shaders for luminance range expansion into display EDR capability. No VTFrameProcessor API exists for this. Vue: defer until SR, FI, MB, DN, and performance are stable.
