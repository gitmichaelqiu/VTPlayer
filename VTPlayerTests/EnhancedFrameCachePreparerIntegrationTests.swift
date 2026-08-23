import AVFoundation
import CoreMedia
import XCTest
@testable import VTPlayer

final class EnhancedFrameCachePreparerIntegrationTests: XCTestCase {
    func testSparsePreparationReadsBackRealVideoToolboxOutput() async throws {
        let url = URL(fileURLWithPath: "/Users/michaelqiu/Projects/03_App_macOS/VTPlayer_Resources/Demo/145907-787718807_medium.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("The local macOS video fixture is unavailable.")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = AppliedPipelineConfiguration(
            superResolutionLevel: 1.5,
            qualitySuperResolutionScaleFactor: 0,
            frameInterpolationLevel: 2,
            denoiseStrength: 0,
            motionBlurStrength: 0
        )
        let sourceRate = 59.94
        let preparer = EnhancedFrameCachePreparer(
            diskCache: EnhancedFrameDiskCache(rootDirectory: directory)
        )
        let benchmark = try await preparer.benchmark(
            url: url,
            width: 1280,
            height: 720,
            sourceFramesPerSecond: sourceRate,
            configuration: configuration,
            qualityPrioritization: 1,
            preferSequentialSRFI: false
        )
        XCTAssertGreaterThan(benchmark.averageOutputBytesPerGroup, 0)
        XCTAssertGreaterThan(benchmark.outputFramesPerGroup, 1)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let groupCount = Int((CMTimeGetSeconds(duration) * sourceRate).rounded(.up)) + 8
        let plan = SparseCachePlanner.makePlan(
            benchmark: benchmark,
            configuration: configuration,
            totalGroupCount: groupCount
        )
        XCTAssertEqual(plan.mode, .sparse)

        let result = try await preparer.prepareCache(
            url: url,
            width: 1280,
            height: 720,
            sourceFramesPerSecond: sourceRate,
            estimatedGroupCount: groupCount,
            plan: plan,
            configuration: configuration,
            qualityPrioritization: 1,
            preferSequentialSRFI: false,
            diskBudgetBytes: 100 * 1_024 * 1_024 * 1_024,
            estimatedRequiredBytes: Int64(Double(benchmark.averageOutputBytesPerGroup * Int64(groupCount)) * 1.2),
            benchmark: benchmark
        ) { _, _ in }
        XCTAssertEqual(result.mode, .sparse)
        XCTAssertFalse(result.status.availableGroupIndices.isEmpty)

        let diskCache = EnhancedFrameDiskCache(rootDirectory: directory)
        let cachedIndex = try XCTUnwrap(result.status.availableGroupIndices.sorted().first)
        let cachedFrames = try await diskCache.readGroup(cachedIndex, for: result.key)
        let frames = try XCTUnwrap(cachedFrames)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.allSatisfy { $0.presentationTimeStamp.isValid })
    }
}
