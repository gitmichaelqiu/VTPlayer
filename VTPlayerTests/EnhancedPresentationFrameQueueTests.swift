import CoreMedia
import CoreVideo
import XCTest
@testable import VTPlayer

final class EnhancedPresentationFrameQueueTests: XCTestCase {
    func testDisplaySchedulingWaitsForPreroll() {
        XCTAssertFalse(EnhancedDisplaySchedulingPolicy.shouldStart(
            isPlaying: true,
            isPaused: false,
            isBuffering: true,
            fullCacheFrameCount: 8
        ))
        XCTAssertFalse(EnhancedDisplaySchedulingPolicy.shouldStart(
            isPlaying: true,
            isPaused: false,
            isBuffering: false,
            fullCacheFrameCount: 0
        ))
        XCTAssertTrue(EnhancedDisplaySchedulingPolicy.shouldStart(
            isPlaying: true,
            isPaused: false,
            isBuffering: false,
            fullCacheFrameCount: 8
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
