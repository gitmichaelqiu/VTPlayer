import AVFoundation
import CoreMedia
import XCTest
@testable import VTPlayer

final class EnhancedFrameCachePreparerIntegrationTests: XCTestCase {
    func testQualitySuperResolutionBenchmarkCompletesWithMeasuredSamples() async throws {
        let url = URL(fileURLWithPath: "/Users/michaelqiu/Projects/03_App_macOS/VTPlayer_Resources/Demo/145907-787718807_medium.mp4")
        guard FileManager.default.fileExists(atPath: url.path),
              VTFrameProcessorCoordinator.isQualitySuperResolutionSupported(width: 1280, height: 720, scale: 4) else {
            throw XCTSkip("Quality SR fixture or device support is unavailable.")
        }
        var configuration = AppliedPipelineConfiguration.disabled
        configuration.qualitySuperResolutionScaleFactor = 4
        let preparer = EnhancedFrameCachePreparer(diskCache: .shared)
        let start = DispatchTime.now()
        let result = try await preparer.benchmark(
            url: url, width: 1280, height: 720, sourceFramesPerSecond: 59.94,
            configuration: configuration, qualityPrioritization: 1, preferSequentialSRFI: false
        )
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        print("Quality SR benchmark completed in \(seconds) seconds")
        XCTAssertGreaterThan(result.p95GroupSeconds, 0)
        XCTAssertGreaterThan(result.averageOutputBytesPerGroup, 0)
    }

    func testQualitySuperResolutionProducesVisiblePixels() async throws {
        let url = URL(fileURLWithPath: "/Users/michaelqiu/Projects/03_App_macOS/VTPlayer_Resources/Demo/145907-787718807_medium.mp4")
        guard FileManager.default.fileExists(atPath: url.path),
              VTFrameProcessorCoordinator.isQualitySuperResolutionSupported(width: 1280, height: 720, scale: 4) else {
            throw XCTSkip("Quality SR fixture or device support is unavailable.")
        }
        let coordinator = VTFrameProcessorCoordinator(qualitySuperResolutionScaleFactor: 4)
        try await coordinator.startSession(width: 1280, height: 720)
        let iterator = VTFrameSequence(url: url, startTime: CMTime(seconds: 2, preferredTimescale: 600)).makeAsyncIterator()
        let next = try await iterator.next()
        let source = try XCTUnwrap(next)
        let output = try await coordinator.processFrame(source)
        let frame = try XCTUnwrap(output.first)
        XCTAssertEqual(CVPixelBufferGetWidth(frame.buffer), 5120)
        XCTAssertEqual(CVPixelBufferGetHeight(frame.buffer), 2880)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(frame.buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(frame.buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame.buffer, 0))
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(frame.buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(frame.buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(frame.buffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let samples = stride(from: 0, to: height, by: max(1, height / 16)).flatMap { y in
            stride(from: 0, to: width, by: max(1, width / 16)).map { x in pixels[y * rowBytes + x] }
        }
        XCTAssertGreaterThan(samples.max() ?? 0, 32, "format=\(CVPixelBufferGetPixelFormatType(frame.buffer)) size=\(width)x\(height) samples=\(samples.count)")
        await coordinator.endSession()
    }

    func testCancelledFrameReaderThrowsCancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VTFrameSequence(url: URL(fileURLWithPath: "/tmp/unused.mov"))
                .makeAsyncIterator().next()
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled reading must not look like end of video")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFrameReaderReportsUnreadableVideo() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let iterator = VTFrameSequence(url: url).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("An unreadable video should report a reader error")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

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
        guard plan.mode == .sparse else {
            throw XCTSkip("This machine does not require sparse caching for the fixture.")
        }

        let result = try await preparer.prepareCache(
            url: url,
            width: 1280,
            height: 720,
            sourceFramesPerSecond: sourceRate,
            displayTargetFrameRate: 120,
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
