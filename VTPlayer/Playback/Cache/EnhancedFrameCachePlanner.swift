import Foundation
import CoreMedia

/// The persisted portion of a processing configuration. Renderer-only
/// controls deliberately do not participate in this value.
nonisolated struct AppliedPipelineConfiguration: Codable, Equatable, Hashable, Sendable {
    var superResolutionLevel: Float
    var qualitySuperResolutionScaleFactor: Int
    var frameInterpolationLevel: Int
    var denoiseStrength: Double
    var motionBlurStrength: Int

    var requiresSequentialSRFIFallback: Bool {
        #if os(macOS)
        superResolutionLevel == 2 && frameInterpolationLevel == 2
        #else
        false
        #endif
    }

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

nonisolated struct EnhancedPipelineBenchmark: Equatable, Sendable {
    var p50GroupSeconds: Double
    var p95GroupSeconds: Double
    var sourceFramesPerSecond: Double
    var requestedOutputFramesPerSecond: Double
    var measuredDisplayFramesPerSecond: Double
    var outputFramesPerGroup: Double
    var averageOutputBytesPerGroup: Int64
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

nonisolated enum EnhancedCachePlaybackMode: String, Codable, Equatable, Sendable {
    case realTime
    case sparse
    case full
}

nonisolated struct SparseCachePlan: Equatable, Sendable {
    var mode: EnhancedCachePlaybackMode
    var coveragePercent: Int
    var coverageBitmap: [Bool]

    var cachedGroupCount: Int {
        coverageBitmap.lazy.filter { $0 }.count
    }
}

nonisolated enum SparseCachePlanner {
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

nonisolated struct EnhancedFrameDisplayCadenceSelector: Sendable {
    private let displayInterval: CMTime
    private var nextPresentationTime: CMTime?
    private var lastSelectedTime: CMTime?

    init(displayFrameRate: Double) {
        let safeRate = displayFrameRate.isFinite ? max(1, displayFrameRate) : 60
        displayInterval = CMTime(seconds: 1 / safeRate, preferredTimescale: 60_000)
    }

    mutating func select(_ frames: [VTFrame]) -> [VTFrame] {
        guard !frames.isEmpty else { return [] }
        let ordered = frames.sorted {
            CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0
        }
        var selected: [VTFrame] = []
        selected.reserveCapacity(ordered.count)

        for frame in ordered {
            let time = frame.presentationTimeStamp
            guard time.isValid, time.isNumeric else { continue }
            if nextPresentationTime == nil {
                selected.append(frame)
                lastSelectedTime = time
                nextPresentationTime = CMTimeAdd(time, displayInterval)
                continue
            }
            if let lastSelectedTime, CMTimeCompare(time, lastSelectedTime) <= 0 {
                continue
            }
            guard let nextPresentationTime,
                  CMTimeCompare(time, nextPresentationTime) >= 0 else {
                continue
            }

            selected.append(frame)
            lastSelectedTime = time
            let lateness = CMTimeGetSeconds(CMTimeSubtract(time, nextPresentationTime))
            let intervalSeconds = CMTimeGetSeconds(displayInterval)
            let slotsToAdvance = max(1, Int((lateness / intervalSeconds).rounded(.down)) + 1)
            self.nextPresentationTime = CMTimeAdd(
                nextPresentationTime,
                CMTimeMultiply(displayInterval, multiplier: Int32(min(slotsToAdvance, Int(Int32.max))))
            )
        }
        return selected
    }
}

nonisolated enum EnhancedFrameCacheSizing {
    static let chunkDuration = CMTime(value: 5, timescale: 1)
    static let bitsPerPixelPerFrame = 0.022
    static let preflightSafetyFactor = 1.25

    static func chunkIndex(for presentationTime: CMTime) -> Int {
        let seconds = CMTimeGetSeconds(presentationTime)
        guard seconds.isFinite else { return 0 }
        return max(0, Int(floor(seconds / CMTimeGetSeconds(chunkDuration))))
    }

    static func targetBitRate(width: Int, height: Int, frameRate: Double) -> Int {
        guard width > 0, height > 0, frameRate.isFinite, frameRate > 0 else {
            return 2_000_000
        }
        let estimate = Double(width) * Double(height) * frameRate * bitsPerPixelPerFrame
        guard estimate.isFinite, estimate < Double(Int.max) else { return Int.max }
        return Int(max(2_000_000, estimate).rounded())
    }

    static func estimatedBytes(
        width: Int,
        height: Int,
        frameRate: Double,
        durationSeconds: Double
    ) -> Int64 {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        let bitRate = Double(targetBitRate(width: width, height: height, frameRate: frameRate))
        let estimate = (bitRate / 8) * durationSeconds * preflightSafetyFactor
        guard estimate.isFinite, estimate < Double(Int64.max) else { return Int64.max }
        return Int64(max(0, estimate).rounded(.up))
    }
}

nonisolated enum EnhancedFrameCachePlaybackPolicy {
    static func usesPrecomputedVideo(
        cacheMode: EnhancedCachePlaybackMode?,
        cacheFormatVersion: Int?
    ) -> Bool {
        cacheMode == .full && (cacheFormatVersion ?? 0) >= 2
    }
}
