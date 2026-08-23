import XCTest
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
}
