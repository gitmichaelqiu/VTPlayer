//
//  VTFrameProcessorCoordinator.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import Foundation
@preconcurrency import VideoToolbox
import CoreMedia
@preconcurrency import CoreVideo

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)

/// Ordered pipeline stages for frame processing.
public enum PipelineStage: Int, Comparable, CaseIterable {
    case denoise    // Temporal noise filter (VTTemporalNoiseFilter)
    case spatial    // Super resolution (LL SR or Quality SR)
    case temporal   // Frame interpolation or frame rate conversion
    case motionBlur // Motion blur post-process (VTMotionBlur)

    public static func < (lhs: PipelineStage, rhs: PipelineStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A live processor instance at a specific pipeline stage.
nonisolated struct StageInstance {
    let stage: PipelineStage
    let processor: VTFrameProcessor
    let pixelBufferPool: CVPixelBufferPool?
    let outputWidth: Int
    let outputHeight: Int
}

/// A coordinator actor that manages the VideoToolbox processing pipeline.
public actor VTFrameProcessorCoordinator {

    // MARK: - Static Support Checks

    public static func isSuperResolutionSupported() -> Bool {
        VTLowLatencySuperResolutionScalerConfiguration.isSupported
    }

    public static func supportedSuperResolutionScaleFactors(width: Int, height: Int) -> [Float] {
        VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height)
    }

    public static func isFrameInterpolationSupported(width: Int, height: Int) -> Bool {
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
              VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                numberOfInterpolatedFrames: 1
              ) != nil else {
            return false
        }
        if #available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, *) {
            let maximumDimension = VTLowLatencyFrameInterpolationConfiguration
                .maximumDimension(forSpatialScaleFactor: 1)
            let maximumPixelCount = VTLowLatencyFrameInterpolationConfiguration
                .maximumPixelCount(forSpatialScaleFactor: 1)
            return maximumDimension > 0 && maximumPixelCount > 0 &&
                width <= maximumDimension && height <= maximumDimension &&
                Int64(width) * Int64(height) <= Int64(maximumPixelCount)
        }
        return true
    }

    /// Tests the exact LL SR session used by the pipeline. The advertised
    /// scale-factor list is useful diagnostics, but on some OS/device
    /// combinations it does not agree with whether a concrete processor
    /// session can actually be started for the requested dimensions.
    public static func isLowLatencySuperResolutionSupported(width: Int, height: Int, scale: Float) -> Bool {
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: width,
            frameHeight: height,
            scaleFactor: scale
        )
        guard !configuration.sourcePixelBufferAttributes.isEmpty,
              !configuration.destinationPixelBufferAttributes.isEmpty else {
            return false
        }
        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
            processor.endSession()
            return true
        } catch {
            processor.endSession()
            return false
        }
    }

    /// Validates the complete LL SR pipeline rather than only VideoToolbox's
    /// bare processor session. Capability lists and a successful bare session
    /// can still disagree with the pixel-buffer pools and presentation
    /// conversion required by real playback on macOS.
    public static func canStartLowLatencyPipeline(width: Int, height: Int, scale: Float) async -> Bool {
        let coordinator = VTFrameProcessorCoordinator(superResolutionLevel: scale)
        do {
            try await coordinator.startSession(width: width, height: height)
            await coordinator.endSession()
            return true
        } catch {
            await coordinator.endSession()
            return false
        }
    }

    /// Validates Quality SR at the same boundary that playback uses. The
    /// configuration initializer can succeed even when a processor session
    /// cannot be created for a particular resolution/scale on this machine.
    public static func isQualitySuperResolutionSupported(width: Int, height: Int, scale: Int) -> Bool {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
              VTSuperResolutionScalerConfiguration.isSupported,
              let configuration = VTSuperResolutionScalerConfiguration(
                  frameWidth: width,
                  frameHeight: height,
                  scaleFactor: scale,
                  inputType: .video,
                  usePrecomputedFlow: false,
                  qualityPrioritization: .normal,
                  revision: .revision1
              ) else {
            return false
        }

        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
            processor.endSession()
            return true
        } catch {
            processor.endSession()
            return false
        }
    }

    // MARK: - Configuration

    // Existing
    public let superResolutionLevel: Float     // 0, 1.5, 2, 4 (LL SR)
    public let frameInterpolationLevel: Int    // 0, 2, 4 (LL FI)
    public let useHighQualityDownsampling: Bool
    public let useRealTimePriority: Bool
    /// Uses the separate temporal-then-spatial implementation only after the
    /// combined LL2 SR/FI processor rejects this device or resolution.
    public let preferSequentialSRFI: Bool

    // New: Quality SR (alternative to LL SR)
    public let qualitySuperResolutionScaleFactor: Int  // 0=off, 2, 4

    // New: Motion blur
    public let motionBlurStrength: Int         // 0=off, 1-100

    // New: Temporal denoise
    public let denoiseStrength: Double         // 0.0=off, 0.0-1.0

    // New: Quality prioritization
    public let qualityPrioritization: Int      // 0=normal, 1=quality

    // MARK: - Pipeline State

    var stages: [PipelineStage: StageInstance] = [:]
    var isSessionActive = false
    var activeProcessCount = 0
    var endRequested = false
    var endWaiters: [CheckedContinuation<Void, Never>] = []

    // Source dimensions for the pipeline
    var sourceWidth = 0
    var sourceHeight = 0
    var targetWidth = 0
    var targetHeight = 0
    var sourceExtendedPixelsRight = 0
    var sourceExtendedPixelsBottom = 0

    // Reference frame ring buffer (newest first)
    var frameHistory: [VTFrameProcessorFrame] = []
    var outputHistory: [VTFrameProcessorFrame] = []
    var upscaledFrameHistory: [VTFrameProcessorFrame] = []
    let maxHistoryLength = 8

    // Fallback transfer session (for unsupported 2nd stage SR scaler)
    var fallbackTransferSession: VTPixelTransferSession?

    #if os(macOS)
    // Convert processed Y'CbCr output before handing it to Core Image/Metal.
    var rendererTransferSession: VTPixelTransferSession?
    var rendererPixelBufferPool: CVPixelBufferPool?
    #endif

    // FI must run at source resolution when it is paired with LL SR. Running
    // the temporal processor after 4x SR makes it operate on sixteen times
    // as many pixels and cannot sustain the generated-frame cadence.
    var temporalFirstForSRInterpolation = false

    // Bicubic upscale for interpolated frames in temporal-first mode.
    // LL SR is trained on real video and produces softer output on
    // synthetically interpolated frames.
    var interpolatedTransferSession: VTPixelTransferSession?
    var interpolatedTransferPool: CVPixelBufferPool?

    // Second spatial stage for 4x LL SR cascading (2x → 2x)
    var secondSpatialProcessor: VTFrameProcessor?
    var secondSpatialPool: CVPixelBufferPool?
    // MARK: - Init

    public init(
        superResolutionLevel: Float = 0,
        frameInterpolationLevel: Int = 0,
        useHighQualityDownsampling: Bool = true,
        useRealTimePriority: Bool = true,
        preferSequentialSRFI: Bool = false,
        qualitySuperResolutionScaleFactor: Int = 0,
        motionBlurStrength: Int = 0,
        denoiseStrength: Double = 0.0,
        qualityPrioritization: Int = 1
    ) {
        self.superResolutionLevel = superResolutionLevel
        self.frameInterpolationLevel = frameInterpolationLevel
        self.useHighQualityDownsampling = useHighQualityDownsampling
        self.useRealTimePriority = useRealTimePriority
        self.preferSequentialSRFI = preferSequentialSRFI
        self.qualitySuperResolutionScaleFactor = qualitySuperResolutionScaleFactor
        self.motionBlurStrength = motionBlurStrength
        self.denoiseStrength = denoiseStrength
        self.qualityPrioritization = qualityPrioritization
    }

}
#else
public enum PipelineStage: Int, Comparable, CaseIterable {
    case denoise
    case spatial
    case temporal
    case motionBlur

    public static func < (lhs: PipelineStage, rhs: PipelineStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public actor VTFrameProcessorCoordinator {
    public static func isSuperResolutionSupported() -> Bool {
        return false
    }

    public static func supportedSuperResolutionScaleFactors(width: Int, height: Int) -> [Float] {
        return []
    }

    public static func isFrameInterpolationSupported(width: Int, height: Int) -> Bool {
        false
    }

    public static func canStartLowLatencyPipeline(width: Int, height: Int, scale: Float) async -> Bool {
        return false
    }

    public let superResolutionLevel: Float
    public let frameInterpolationLevel: Int
    public let useHighQualityDownsampling: Bool
    public let useRealTimePriority: Bool
    public let qualitySuperResolutionScaleFactor: Int
    public let motionBlurStrength: Int
    public let denoiseStrength: Double
    public let qualityPrioritization: Int

    public init(
        superResolutionLevel: Float,
        frameInterpolationLevel: Int,
        useHighQualityDownsampling: Bool = true,
        useRealTimePriority: Bool = true,
        preferSequentialSRFI: Bool = false,
        qualitySuperResolutionScaleFactor: Int = 0,
        motionBlurStrength: Int = 0,
        denoiseStrength: Double = 0.0,
        qualityPrioritization: Int = 1
    ) {
        self.superResolutionLevel = superResolutionLevel
        self.frameInterpolationLevel = frameInterpolationLevel
        self.useHighQualityDownsampling = useHighQualityDownsampling
        self.useRealTimePriority = useRealTimePriority
        self.preferSequentialSRFI = preferSequentialSRFI
        self.qualitySuperResolutionScaleFactor = qualitySuperResolutionScaleFactor
        self.motionBlurStrength = motionBlurStrength
        self.denoiseStrength = denoiseStrength
        self.qualityPrioritization = qualityPrioritization
    }

    public func startSession(width: Int, height: Int) async throws {}

    public func processFrame(_ frame: VTFrame) async throws -> [VTFrame] {
        return [frame]
    }

    public func endSession() async {}

    public func sourceFramePadding() -> (right: Int, bottom: Int) { (0, 0) }

    public func clearHistory() {}
}
#endif
