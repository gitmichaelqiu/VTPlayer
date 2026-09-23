import CoreMedia
import CoreVideo
import XCTest
@testable import VTPlayer

final class EnhancedPresentationFrameQueueTests: XCTestCase {
    func testHighRateLiveInterpolationUsesDedicatedPresentation() {
        XCTAssertTrue(MacDedicatedPresentationPolicy.shouldUseLiveQueue(
            sourceFramesPerSecond: 25,
            frameInterpolationLevel: 4,
            screenMaximumFramesPerSecond: 120
        ))
        XCTAssertFalse(MacDedicatedPresentationPolicy.shouldUseLiveQueue(
            sourceFramesPerSecond: 25,
            frameInterpolationLevel: 2,
            screenMaximumFramesPerSecond: 120
        ))
        XCTAssertFalse(MacDedicatedPresentationPolicy.shouldUseLiveQueue(
            sourceFramesPerSecond: 25,
            frameInterpolationLevel: 4,
            screenMaximumFramesPerSecond: 60
        ))
    }

    func testFullCachePresentationRejectsStaleGenerationAndStoppedPlayback() {
        XCTAssertTrue(FullCachePresentationGeneration.accepts(
            driverGeneration: 7,
            activeGeneration: 7,
            isPlaying: true,
            isPaused: false,
            isBuffering: false
        ))
        XCTAssertFalse(FullCachePresentationGeneration.accepts(
            driverGeneration: 7,
            activeGeneration: 8,
            isPlaying: true,
            isPaused: false,
            isBuffering: false
        ))
        XCTAssertFalse(FullCachePresentationGeneration.accepts(
            driverGeneration: 7,
            activeGeneration: 7,
            isPlaying: true,
            isPaused: true,
            isBuffering: false
        ))
        XCTAssertFalse(FullCachePresentationGeneration.accepts(
            driverGeneration: 7,
            activeGeneration: 7,
            isPlaying: true,
            isPaused: false,
            isBuffering: true
        ))
    }

    func testDisplaySchedulingWaitsForPreroll() {
        XCTAssertFalse(EnhancedDisplaySchedulingPolicy.shouldStart(
            isPlaying: true,
            isPaused: false,
            isBuffering: true,
            isInitializingPipeline: false,
            requiresFullCachePreroll: true,
            fullCacheFrameCount: 8
        ))
        XCTAssertFalse(EnhancedDisplaySchedulingPolicy.shouldStart(
            isPlaying: true,
            isPaused: false,
            isBuffering: false,
            isInitializingPipeline: false,
            requiresFullCachePreroll: true,
            fullCacheFrameCount: 0
        ))
        XCTAssertFalse(EnhancedDisplaySchedulingPolicy.shouldStart(
            isPlaying: true,
            isPaused: false,
            isBuffering: false,
            isInitializingPipeline: true,
            requiresFullCachePreroll: true,
            fullCacheFrameCount: 8
        ))
        XCTAssertFalse(EnhancedDisplaySchedulingPolicy.shouldStart(
            isPlaying: true,
            isPaused: false,
            isBuffering: false,
            isInitializingPipeline: false,
            requiresFullCachePreroll: true,
            fullCacheFrameCount: nil
        ))
        XCTAssertTrue(EnhancedDisplaySchedulingPolicy.shouldStart(
            isPlaying: true,
            isPaused: false,
            isBuffering: false,
            isInitializingPipeline: false,
            requiresFullCachePreroll: true,
            fullCacheFrameCount: 8
        ))
        XCTAssertTrue(EnhancedDisplaySchedulingPolicy.shouldStart(
            isPlaying: true,
            isPaused: false,
            isBuffering: false,
            isInitializingPipeline: false,
            requiresFullCachePreroll: false,
            fullCacheFrameCount: nil
        ))
    }

    func testDisplayTargetClockExtrapolatesToPredictedPresentation() {
        XCTAssertEqual(
            DisplayTargetClock.presentationSeconds(
                currentPresentationSeconds: 12,
                targetHostTime: 20.008,
                currentHostTime: 20,
                playbackRate: 1
            ),
            12.008,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            DisplayTargetClock.presentationSeconds(
                currentPresentationSeconds: 12,
                targetHostTime: 20.008,
                currentHostTime: 20,
                playbackRate: 2
            ),
            12.016,
            accuracy: 0.000_001
        )
    }

    func testNewestDueSelectionDropsOnlySupersededInterpolation() throws {
        let queue = EnhancedPresentationFrameQueue(
            capacityBytes: 1_000_000,
            capacityFrames: 8,
            generation: 1
        )
        let frames = try [
            makeFrame(time: .zero, interpolated: false),
            makeFrame(time: CMTime(value: 1, timescale: 120), interpolated: true),
            makeFrame(time: CMTime(value: 2, timescale: 120), interpolated: true)
        ]
        XCTAssertTrue(queue.enqueue(contentsOf: frames, generation: 1))

        let selection = queue.dequeueNewestDue(
            at: 0.02,
            after: CMTime(value: -1, timescale: 120),
            catchesUpInterpolation: true
        )
        XCTAssertEqual(selection?.frame.presentationTimeStamp, frames[2].presentationTimeStamp)
        XCTAssertEqual(selection?.droppedInterpolatedFrames, 1)
        XCTAssertEqual(queue.snapshot().frameCount, 0)
    }

    func testResetRejectsFramesFromSupersededGeneration() throws {
        let queue = EnhancedPresentationFrameQueue(
            capacityBytes: 1_000_000,
            capacityFrames: 2,
            generation: 1
        )
        let frame = try makeFrame(time: .zero, interpolated: false)
        queue.reset(generation: 2)

        XCTAssertFalse(queue.enqueue(contentsOf: [frame], generation: 1))
        XCTAssertTrue(queue.enqueue(contentsOf: [frame], generation: 2))
    }

    func testEnqueueResultDistinguishesBackpressureFromRejectedFrames() throws {
        let queue = EnhancedPresentationFrameQueue(
            capacityBytes: 1_000_000,
            capacityFrames: 1,
            generation: 1
        )
        let first = try makeFrame(time: .zero, interpolated: false)
        let second = try makeFrame(time: CMTime(value: 1, timescale: 120), interpolated: true)

        XCTAssertEqual(
            queue.enqueueResult(contentsOf: [first], generation: 1),
            .enqueued
        )
        XCTAssertEqual(
            queue.enqueueResult(contentsOf: [second], generation: 1),
            .capacityExceeded
        )
        XCTAssertEqual(
            queue.enqueueResult(contentsOf: [second], generation: 2),
            .rejected
        )
    }

    func testQueueSnapshotSeparatesSamplingStarvationAndLateDrops() throws {
        let queue = EnhancedPresentationFrameQueue(
            capacityBytes: 1_000_000,
            capacityFrames: 8,
            generation: 1
        )
        XCTAssertNil(queue.dequeueNewestDue(
            at: 0,
            after: .negativeInfinity,
            catchesUpInterpolation: true
        ))
        let frames = try [
            makeFrame(time: CMTime(value: 1, timescale: 120), interpolated: true),
            makeFrame(time: CMTime(value: 2, timescale: 120), interpolated: true)
        ]
        XCTAssertTrue(queue.enqueue(contentsOf: frames, generation: 1))
        queue.recordCacheHitGroup(generation: 1, sampledOutFrames: 2)
        _ = queue.dequeueNewestDue(
            at: 1,
            after: .zero,
            catchesUpInterpolation: true
        )

        let snapshot = queue.snapshot(consumeActivity: true)
        XCTAssertEqual(snapshot.starvationCount, 1)
        XCTAssertEqual(snapshot.intentionallySampledOutFrames, 2)
        XCTAssertEqual(snapshot.lateInterpolatedDrops, 1)
        XCTAssertEqual(snapshot.dequeueAttempts, 2)
        XCTAssertEqual(queue.snapshot().starvationCount, 0)
    }

    func testPresentationRecorderExcludesZeroPresentedTime() {
        let recorder = RendererPresentationPerformanceRecorder()
        recorder.record(presentedTime: 0)
        recorder.record(presentedTime: 1.000)
        recorder.record(presentedTime: 1.008)
        recorder.record(presentedTime: 1.017)
        recorder.record(presentedTime: 1.017)
        recorder.record(presentedTime: 1.049)

        let snapshot = recorder.consumeSnapshot()
        XCTAssertEqual(snapshot.presentedFrames, 4)
        XCTAssertEqual(snapshot.droppedPresentations, 1)
        XCTAssertEqual(snapshot.duplicatePresentations, 1)
        XCTAssertEqual(snapshot.intervalSamples, 3)
        let performance = RendererPerformanceAggregate().consumeSnapshot(
            completedGPU: RendererGPUPerformanceSnapshot(completedFrames: 0, totalNanoseconds: 0),
            presentation: snapshot
        )
        XCTAssertEqual(performance.p50PresentationIntervalMilliseconds, 9, accuracy: 0.01)
        XCTAssertEqual(performance.p95PresentationIntervalMilliseconds, 32, accuracy: 0.01)
        XCTAssertEqual(performance.maximumPresentationGapMilliseconds, 32, accuracy: 0.01)
        XCTAssertEqual(performance.presentationIntervalStandardDeviationMilliseconds, 11.09, accuracy: 0.05)
    }

    private func makeFrame(time: CMTime, interpolated: Bool) throws -> VTFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                4,
                4,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &buffer
            ),
            kCVReturnSuccess
        )
        return VTFrame(
            buffer: try XCTUnwrap(buffer),
            presentationTimeStamp: time,
            isInterpolated: interpolated
        )
    }
}
