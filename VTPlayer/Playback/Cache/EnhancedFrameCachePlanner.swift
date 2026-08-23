import Foundation

/// The persisted portion of a processing configuration. Renderer-only
/// controls deliberately do not participate in this value.
struct AppliedPipelineConfiguration: Codable, Equatable, Sendable {
    var superResolutionLevel: Float
    var qualitySuperResolutionScaleFactor: Int
    var frameInterpolationLevel: Int
    var denoiseStrength: Double
    var motionBlurStrength: Int

    static let disabled = AppliedPipelineConfiguration(
        superResolutionLevel: 0,
        qualitySuperResolutionScaleFactor: 0,
        frameInterpolationLevel: 0,
        denoiseStrength: 0,
        motionBlurStrength: 0
    )

    var supportsSparseCaching: Bool {
        guard qualitySuperResolutionScaleFactor == 0,
              denoiseStrength == 0,
              motionBlurStrength == 0 else {
            return false
        }

        let isLowLatencySuperResolutionOnly =
            superResolutionLevel > 0 && frameInterpolationLevel == 0
        let isFrameInterpolationOnly =
            superResolutionLevel == 0 && frameInterpolationLevel > 0
        let isSupportedCombinedMode =
            superResolutionLevel == 1.5 && frameInterpolationLevel == 2
        return isLowLatencySuperResolutionOnly || isFrameInterpolationOnly || isSupportedCombinedMode
    }
}

struct EnhancedPipelineBenchmark: Equatable, Sendable {
    var p50GroupSeconds: Double
    var p95GroupSeconds: Double
    var sourceFramesPerSecond: Double
    var requestedOutputFramesPerSecond: Double
    var measuredDisplayFramesPerSecond: Double
    var outputFramesPerGroup: Double
    var diskWriteBytesPerSecond: Double

    var meetsRealTimeProcessingBudget: Bool {
        guard sourceFramesPerSecond > 0, p95GroupSeconds.isFinite else { return false }
        return (1 / p95GroupSeconds) >= sourceFramesPerSecond * 0.95
    }

    var meetsRealTimeDisplayBudget: Bool {
        guard requestedOutputFramesPerSecond > 0 else { return false }
        return measuredDisplayFramesPerSecond >= requestedOutputFramesPerSecond * 0.95
    }
}

enum EnhancedCachePlaybackMode: String, Codable, Equatable, Sendable {
    case realTime
    case sparse
    case full
}

struct SparseCachePlan: Equatable, Sendable {
    var mode: EnhancedCachePlaybackMode
    var coveragePercent: Int
    var coverageBitmap: [Bool]

    var cachedGroupCount: Int {
        coverageBitmap.lazy.filter { $0 }.count
    }
}

enum SparseCachePlanner {
    static let safetyMargin = 0.05
    static let fullCacheThresholdPercent = 90

    static func makePlan(
        benchmark: EnhancedPipelineBenchmark,
        configuration: AppliedPipelineConfiguration,
        totalGroupCount: Int
    ) -> SparseCachePlan {
        guard totalGroupCount > 0 else {
            return SparseCachePlan(mode: .realTime, coveragePercent: 0, coverageBitmap: [])
        }

        guard !benchmark.meetsRealTimeProcessingBudget || !benchmark.meetsRealTimeDisplayBudget else {
            return SparseCachePlan(
                mode: .realTime,
                coveragePercent: 0,
                coverageBitmap: Array(repeating: false, count: totalGroupCount)
            )
        }

        let coveragePercent = requiredCoveragePercent(
            p95GroupSeconds: benchmark.p95GroupSeconds,
            sourceFramesPerSecond: benchmark.sourceFramesPerSecond
        )
        let mode: EnhancedCachePlaybackMode =
            configuration.supportsSparseCaching && coveragePercent < fullCacheThresholdPercent
            ? .sparse
            : .full
        let effectiveCoverage = mode == .full ? 100 : coveragePercent
        return SparseCachePlan(
            mode: mode,
            coveragePercent: effectiveCoverage,
            coverageBitmap: coverageBitmap(totalGroupCount: totalGroupCount, coveragePercent: effectiveCoverage)
        )
    }

    static func requiredCoveragePercent(
        p95GroupSeconds: Double,
        sourceFramesPerSecond: Double
    ) -> Int {
        guard p95GroupSeconds.isFinite,
              sourceFramesPerSecond.isFinite,
              p95GroupSeconds > 0,
              sourceFramesPerSecond > 0 else {
            return 100
        }

        let processingLoad = p95GroupSeconds * sourceFramesPerSecond
        guard processingLoad > 1 else { return 0 }
        let coverage = 1 - (1 / processingLoad) + safetyMargin
        return min(100, max(0, Int((coverage * 100).rounded(.up))))
    }

    /// A Bresenham-style schedule with exactly the requested density. It is
    /// deterministic and spreads entries through the complete title instead
    /// of concentrating cache hits at its beginning.
    static func coverageBitmap(totalGroupCount: Int, coveragePercent: Int) -> [Bool] {
        guard totalGroupCount > 0 else { return [] }
        let cachedGroupCount = min(
            totalGroupCount,
            max(0, Int((Double(totalGroupCount) * Double(coveragePercent) / 100).rounded(.up)))
        )
        guard cachedGroupCount > 0 else { return Array(repeating: false, count: totalGroupCount) }
        guard cachedGroupCount < totalGroupCount else { return Array(repeating: true, count: totalGroupCount) }

        return (0..<totalGroupCount).map { index in
            ((index + 1) * cachedGroupCount / totalGroupCount) > (index * cachedGroupCount / totalGroupCount)
        }
    }
}
