import XCTest
import AVFoundation
@testable import VTPlayer

final class EnhancedFrameCachePlannerTests: XCTestCase {
    @MainActor
    func testMacOSDraftDoesNotChangeAppliedPipelineUntilApply() {
        let viewModel = VTPlayerViewModel()
        let original = viewModel.appliedPipelineConfiguration
        viewModel.availableSuperResolutionScales = [1.5]
        viewModel.frameInterpolationIsSupported = true
        viewModel.superResolutionLevel = 1.5
        viewModel.frameInterpolationLevel = 2

        viewModel.updateEnhancements()

        #if os(macOS)
        XCTAssertTrue(viewModel.hasUnappliedPipelineChanges)
        XCTAssertEqual(viewModel.appliedPipelineConfiguration, original)
        #endif

        viewModel.applyPipelineEnhancements()

        XCTAssertEqual(
            viewModel.appliedPipelineConfiguration,
            AppliedPipelineConfiguration(
                superResolutionLevel: 1.5,
                qualitySuperResolutionScaleFactor: 0,
                frameInterpolationLevel: 2,
                denoiseStrength: 0,
                motionBlurStrength: 0
            )
        )
    }

    @MainActor
    func testMacOSTransportApplyActionReplacesPlayForEveryTransportState() {
        let viewModel = VTPlayerViewModel()
        viewModel.availableSuperResolutionScales = [1.5]
        viewModel.superResolutionLevel = 1.5

        #if os(macOS)
        XCTAssertTrue(viewModel.shouldShowTransportApplyAction)

        viewModel.isPlaying = true
        viewModel.isPaused = false
        XCTAssertTrue(viewModel.shouldShowTransportApplyAction)

        viewModel.isPaused = true
        XCTAssertTrue(viewModel.shouldShowTransportApplyAction)
        #endif
    }

    @MainActor
    func testMacOSRestoringSpeedCannotStartAStoppedPlayer() {
        #if os(macOS)
        let viewModel = VTPlayerViewModel()
        let player = AVPlayer()
        viewModel.player = player
        viewModel.isPlaying = false
        viewModel.isPaused = false // the post-stop compatibility state

        viewModel.playbackSpeed = 1.5

        XCTAssertEqual(player.rate, 0)
        #endif
    }

    @MainActor
    func testMacOSRendererEnhancementsAreStagedUntilApplyOrRevert() {
        #if os(macOS)
        let viewModel = VTPlayerViewModel()
        viewModel.sharpness = 0.8
        viewModel.hdrStrength = 0.4
        viewModel.hdrColorfulness = 0.2
        viewModel.updateEnhancements()

        XCTAssertTrue(viewModel.hasUnappliedPipelineChanges)
        XCTAssertEqual(viewModel.appliedSharpness, 0)
        XCTAssertEqual(viewModel.appliedHDRStrength, 0)
        XCTAssertEqual(viewModel.appliedHDRColorfulness, 0)

        viewModel.dismissPendingEnhancementChanges()
        XCTAssertEqual(viewModel.sharpness, 0)
        XCTAssertEqual(viewModel.hdrStrength, 0)
        XCTAssertEqual(viewModel.hdrColorfulness, 0)
        XCTAssertFalse(viewModel.hasUnappliedPipelineChanges)

        viewModel.sharpness = 0.6
        viewModel.hdrStrength = 0.3
        viewModel.hdrColorfulness = 0.1
        viewModel.applyPipelineEnhancements()
        XCTAssertEqual(viewModel.appliedSharpness, 0.6)
        XCTAssertEqual(viewModel.appliedHDRStrength, 0.3)
        XCTAssertEqual(viewModel.appliedHDRColorfulness, 0.1)
        XCTAssertFalse(viewModel.hasUnappliedPipelineChanges)
        #endif
    }

    @MainActor
    func testMacOSSavedPipelineSettingsRequireInitialApply() {
        #if os(macOS)
        let viewModel = VTPlayerViewModel()
        let url = URL(fileURLWithPath: "/tmp/VTPlayerSavedPipelineSettings.mov")
        let key = VTPlayerViewModel.videoSettingsKey(for: url.lastPathComponent)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set([
            "superResolutionLevel": 1.5,
            "frameInterpolationLevel": 2,
            "qualitySuperResolutionScaleFactor": 0,
            "motionBlurStrength": 0,
            "denoiseStrength": 0.0
        ], forKey: key)

        viewModel.loadVideoSettings(for: url)

        XCTAssertEqual(viewModel.appliedPipelineConfiguration, .disabled)
        XCTAssertTrue(viewModel.hasUnappliedPipelineChanges)
        XCTAssertTrue(viewModel.shouldShowTransportApplyAction)
        #endif
    }

    func testRequiredCoverageUsesP95AndRoundsUpWithSafetyMargin() {
        XCTAssertEqual(
            SparseCachePlanner.requiredCoveragePercent(
                p95GroupSeconds: 0.035,
                sourceFramesPerSecond: 59.94
            ),
            58
        )
        XCTAssertEqual(
            SparseCachePlanner.requiredCoveragePercent(
                p95GroupSeconds: 1 / 59.94,
                sourceFramesPerSecond: 59.94
            ),
            0
        )
    }

    func testCoverageBitmapIsUniformAndHasRequestedDensity() {
        let bitmap = SparseCachePlanner.coverageBitmap(totalGroupCount: 100, coveragePercent: 37)

        XCTAssertEqual(bitmap.filter { $0 }.count, 37)
        let cachedPositions = bitmap.indices.filter { bitmap[$0] }
        let gaps = zip(cachedPositions, cachedPositions.dropFirst()).map { next, previous in
            previous - next
        }
        XCTAssertLessThanOrEqual((gaps.max() ?? 0) - (gaps.min() ?? 0), 1)
    }

    func testTimestampCadenceSelectionCapsFourTimesInterpolationAt120Hz() {
        let sourceRate = CMTime(value: 1_001, timescale: 60_000)
        let quarterFrame = CMTimeMultiplyByFloat64(sourceRate, multiplier: 0.25)
        let frames = (0..<16).map { index in
            makeCadenceFrame(
                time: CMTimeMultiply(quarterFrame, multiplier: Int32(index)),
                interpolated: index.isMultiple(of: 4) == false
            )
        }
        var selector = EnhancedFrameDisplayCadenceSelector(displayFrameRate: 120)

        let selected = selector.select(frames)

        XCTAssertEqual(selected.count, 8)
        XCTAssertTrue(zip(selected, selected.dropFirst()).allSatisfy { pair in
            CMTimeCompare(pair.0.presentationTimeStamp, pair.1.presentationTimeStamp) < 0
        })
        XCTAssertEqual(
            CMTimeGetSeconds(CMTimeSubtract(selected[1].presentationTimeStamp, selected[0].presentationTimeStamp)),
            1.0 / 120.0,
            accuracy: 0.00001
        )
    }

    func testCacheEstimateScalesWithEncodedDisplayRateInsteadOfRawPixelCount() {
        let estimate = EnhancedFrameCacheSizing.estimatedBytes(
            width: 1_920,
            height: 1_080,
            frameRate: 120,
            durationSeconds: 90 * 60
        )

        XCTAssertGreaterThan(estimate, 0)
        XCTAssertLessThan(estimate, 20 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(EnhancedFrameCacheSizing.chunkIndex(for: CMTime(value: 150, timescale: 30)), 1)
    }

    func testCacheEstimateSaturatesInsteadOfTrappingOnExtremeInputs() {
        XCTAssertEqual(
            EnhancedFrameCacheSizing.targetBitRate(
                width: Int.max,
                height: Int.max,
                frameRate: .greatestFiniteMagnitude
            ),
            Int.max
        )
        XCTAssertEqual(
            EnhancedFrameCacheSizing.estimatedBytes(
                width: Int.max,
                height: Int.max,
                frameRate: .greatestFiniteMagnitude,
                durationSeconds: 100
            ),
            Int64.max
        )
    }

    func testRequestedEnhancementScenariosFitConfiguredCacheBudgetEstimate() {
        let displayTarget = 120.0
        let duration = 162 * 60.0
        let sourceWidth = 1_280
        let sourceHeight = 720
        let twentyFiveFPS = EnhancedFrameCacheSizing.estimatedBytes(
            width: sourceWidth * 2,
            height: sourceHeight * 2,
            frameRate: min(displayTarget, 25 * 4),
            durationSeconds: duration
        )
        let fiftyNineNinetyFourFPS = EnhancedFrameCacheSizing.estimatedBytes(
            width: sourceWidth * 3 / 2,
            height: sourceHeight * 3 / 2,
            frameRate: min(displayTarget, 59.94 * 4),
            durationSeconds: duration
        )
        let fourK120 = EnhancedFrameCacheSizing.estimatedBytes(
            width: 3_840,
            height: 2_160,
            frameRate: min(displayTarget, 59.94 * 4),
            durationSeconds: duration
        )

        XCTAssertLessThan(twentyFiveFPS, 20 * 1_024 * 1_024 * 1_024)
        XCTAssertLessThan(fiftyNineNinetyFourFPS, 20 * 1_024 * 1_024 * 1_024)
        XCTAssertGreaterThan(fourK120, 20 * 1_024 * 1_024 * 1_024)
    }

    func testFullEncodedCacheUsesPrecomputedFramesWithoutProcessorSession() {
        XCTAssertTrue(EnhancedFrameCachePlaybackPolicy.usesPrecomputedVideo(
            cacheMode: .full,
            cacheFormatVersion: 2
        ))
        XCTAssertFalse(EnhancedFrameCachePlaybackPolicy.usesPrecomputedVideo(
            cacheMode: .full,
            cacheFormatVersion: 1
        ))
        XCTAssertFalse(EnhancedFrameCachePlaybackPolicy.usesPrecomputedVideo(
            cacheMode: .realTime,
            cacheFormatVersion: 2
        ))
    }

    private func makeCadenceFrame(time: CMTime, interpolated: Bool) -> VTFrame {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard let buffer else { fatalError("Unable to allocate cadence-test frame") }
        return VTFrame(
            buffer: buffer,
            presentationTimeStamp: time,
            isInterpolated: interpolated
        )
    }

    func testUnsupportedTemporalConfigurationUsesFullCache() {
        let benchmark = EnhancedPipelineBenchmark(
            p50GroupSeconds: 0.025,
            p95GroupSeconds: 0.035,
            sourceFramesPerSecond: 59.94,
            requestedOutputFramesPerSecond: 119.88,
            measuredDisplayFramesPerSecond: 118,
            outputFramesPerGroup: 2,
            averageOutputBytesPerGroup: 1,
            diskWriteBytesPerSecond: 1
        )
        var configuration = AppliedPipelineConfiguration.disabled
        configuration.denoiseStrength = 0.1

        let plan = SparseCachePlanner.makePlan(
            benchmark: benchmark,
            configuration: configuration,
            totalGroupCount: 100
        )

        XCTAssertEqual(plan.mode, .full)
        XCTAssertEqual(plan.coveragePercent, 100)
        XCTAssertTrue(plan.coverageBitmap.allSatisfy { $0 })
    }

    func testEligibleConfigurationUsesSparseCacheBelowFullThreshold() {
        let benchmark = EnhancedPipelineBenchmark(
            p50GroupSeconds: 0.025,
            p95GroupSeconds: 0.035,
            sourceFramesPerSecond: 59.94,
            requestedOutputFramesPerSecond: 119.88,
            measuredDisplayFramesPerSecond: 118,
            outputFramesPerGroup: 2,
            averageOutputBytesPerGroup: 1,
            diskWriteBytesPerSecond: 1
        )
        let configuration = AppliedPipelineConfiguration(
            superResolutionLevel: 1.5,
            qualitySuperResolutionScaleFactor: 0,
            frameInterpolationLevel: 2,
            denoiseStrength: 0,
            motionBlurStrength: 0
        )

        let plan = SparseCachePlanner.makePlan(
            benchmark: benchmark,
            configuration: configuration,
            totalGroupCount: 100
        )

        XCTAssertEqual(plan.mode, .sparse)
        XCTAssertEqual(plan.coveragePercent, 58)
        XCTAssertEqual(plan.cachedGroupCount, 58)
    }

    func testFourTimesInterpolationWithSuperResolutionUsesFullCache() {
        let benchmark = EnhancedPipelineBenchmark(
            p50GroupSeconds: 0.05,
            p95GroupSeconds: 0.06,
            sourceFramesPerSecond: 59.94,
            requestedOutputFramesPerSecond: 239.76,
            measuredDisplayFramesPerSecond: 120,
            outputFramesPerGroup: 4,
            averageOutputBytesPerGroup: 1,
            diskWriteBytesPerSecond: 1
        )
        let configuration = AppliedPipelineConfiguration(
            superResolutionLevel: 1.5,
            qualitySuperResolutionScaleFactor: 0,
            frameInterpolationLevel: 4,
            denoiseStrength: 0,
            motionBlurStrength: 0
        )

        let plan = SparseCachePlanner.makePlan(
            benchmark: benchmark,
            configuration: configuration,
            totalGroupCount: 600
        )

        XCTAssertEqual(plan.mode, .full)
        XCTAssertEqual(plan.coveragePercent, 100)
        XCTAssertTrue(plan.coverageBitmap.allSatisfy { $0 })
    }

    func testPresentationGateUsesPhysicalDisplayCeiling() {
        XCTAssertTrue(EnhancedPresentationGate.passes(
            measuredFramesPerSecond: 116.5,
            physicalFramesPerSecond: 120,
            requestedFramesPerSecond: 239.76,
            renderedTimelineRatio: 1.0
        ))
        XCTAssertFalse(EnhancedPresentationGate.passes(
            measuredFramesPerSecond: 110,
            physicalFramesPerSecond: 120,
            requestedFramesPerSecond: 239.76,
            renderedTimelineRatio: 1.0
        ))
        XCTAssertFalse(EnhancedPresentationGate.passes(
            measuredFramesPerSecond: 119,
            physicalFramesPerSecond: 120,
            requestedFramesPerSecond: 119.88,
            renderedTimelineRatio: 0.96
        ))
    }

    @MainActor
    func testVideoIdentityKeysDoNotCollideForSameFilename() {
        let first = URL(fileURLWithPath: "/tmp/one/video.mp4")
        let second = URL(fileURLWithPath: "/tmp/two/video.mp4")

        XCTAssertNotEqual(
            VTPlayerViewModel.videoSettingsKey(for: first),
            VTPlayerViewModel.videoSettingsKey(for: second)
        )
        XCTAssertNotEqual(
            VTPlayerViewModel.videoProgressKey(for: first),
            VTPlayerViewModel.videoProgressKey(for: second)
        )
    }

    func testPlaybackPhaseLabelsDescribeTransportState() {
        #if os(macOS)
        XCTAssertEqual(PlaybackPhase.readyPaused.label, "Ready · Paused")
        XCTAssertEqual(PlaybackPhase.ended.label, "Ended")
        XCTAssertEqual(PlaybackPhase.monitoringEnhanced.label, "Playing · Checking smoothness")
        #endif
    }
}
