# VTPlayer

**Hardware-accelerated real-time video enhancement player for Apple Silicon.**

VTPlayer uses Apple's VideoToolbox frame processing APIs to upscale, interpolate, denoise, and enhance video in real time on the Apple Neural Engine (ANE) and GPU.

App available for all Apple platforms.

## Features

| Enhancement | Range | Description |
|-------------|-------|-------------|
| **Super Resolution** | Off, 2x, 4x | Low-latency spatial upscaling via `VTLowLatencySuperResolutionScaler`. 4x cascades two 2x stages with `VTPixelTransferSession` fallback. |
| **Quality SR** | Off, 2x, 4x | Higher-quality ML-based upscaling via `VTSuperResolutionScaler` (requires model download). |
| **Frame Interpolation** | Off, 2x, 4x | Temporal interpolation via `VTLowLatencyFrameInterpolation`. Increases perceived framerate. |
| **Combined Mode** | SR2 + FI2 | Single-pass 2x spatial + 2x temporal via `VTLowLatencyFrameInterpolationConfiguration(spatialScaleFactor:)`. |
| **Motion Blur** | Off, 1–30 | Post-process cinematic motion blur via `VTMotionBlur`. |
| **Denoise** | Off, 0.0–1.0 | Temporal noise filter via `VTTemporalNoiseFilter` using 2 previous reference frames. |
| **Sharpness** | Off, 0.0–2.0 | `CIUnsharpMask` applied in the Metal renderer (radius 0.5). Interpolated frames receive boosted sharpness. |
| **SDR-to-HDR Boost** | Off, 0.0–2.0 | `CIExposureAdjust` + `CIColorControls` push luminance into display EDR headroom. |

## License

VTPlayer is licensed under [MIT License](LICENSE).
