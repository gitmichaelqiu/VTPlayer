import CoreMedia
import CoreVideo
import XCTest
@testable import VTPlayer

final class EnhancedPresentationFrameQueueTests: XCTestCase {
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
