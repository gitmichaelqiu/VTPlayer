import AVFoundation
import XCTest
@testable import VTPlayer

final class EnhancedAudioOperationGateTests: XCTestCase {
    func testStopInvalidatesAnInFlightAnchor() {
        var gate = EnhancedAudioOperationGate()
        gate.armFrameAnchor(shouldPlay: true)
        let operation = try! XCTUnwrap(gate.beginFrameAnchor())

        gate.disarm()

        XCTAssertFalse(gate.accepts(operation))
        XCTAssertFalse(gate.isAwaitingFrameAnchor)
    }

    func testNewerAnchorInvalidatesAnOlderCompletion() {
        var gate = EnhancedAudioOperationGate()
        gate.armFrameAnchor(shouldPlay: true)
        let firstOperation = try! XCTUnwrap(gate.beginFrameAnchor())

        gate.armFrameAnchor(shouldPlay: true)
        let secondOperation = try! XCTUnwrap(gate.beginFrameAnchor())

        XCTAssertFalse(gate.accepts(firstOperation))
        XCTAssertTrue(gate.accepts(secondOperation))
    }

    func testPausedReanchorWaitsForResumeAndFrame() {
        var gate = EnhancedAudioOperationGate()
        gate.armFrameAnchor(shouldPlay: false)

        XCTAssertFalse(gate.isAwaitingFrameAnchor)
        XCTAssertNil(gate.beginFrameAnchor())

        gate.armFrameAnchor(shouldPlay: true)

        XCTAssertTrue(gate.isAwaitingFrameAnchor)
        XCTAssertNotNil(gate.beginFrameAnchor())
    }

    func testPipelineSnapshotRejectsStaleGenerationAndPlayer() {
        let originalPlayer = AVPlayer()
        let replacementPlayer = AVPlayer()
        let originalURL = URL(fileURLWithPath: "/tmp/original.mov")
        let replacementURL = URL(fileURLWithPath: "/tmp/replacement.mov")
        let snapshot = PlaybackPipelineSnapshot(
            generation: 7,
            videoURL: originalURL,
            player: originalPlayer
        )

        XCTAssertTrue(snapshot.matches(
            activeGeneration: 7,
            activeVideoURL: originalURL,
            activePlayer: originalPlayer
        ))
        XCTAssertFalse(snapshot.matches(
            activeGeneration: 8,
            activeVideoURL: originalURL,
            activePlayer: originalPlayer
        ))
        XCTAssertFalse(snapshot.matches(
            activeGeneration: 7,
            activeVideoURL: replacementURL,
            activePlayer: originalPlayer
        ))
        XCTAssertFalse(snapshot.matches(
            activeGeneration: 7,
            activeVideoURL: originalURL,
            activePlayer: replacementPlayer
        ))
    }

    func testRendererPerformanceAggregateConsumesAndResetsMetrics() {
        var aggregate = RendererPerformanceAggregate()
        let start = DispatchTime(uptimeNanoseconds: 1_000_000)
        let end = DispatchTime(uptimeNanoseconds: 3_500_000)

        aggregate.recordDrawAttempt()
        aggregate.recordDrawAttempt()
        aggregate.recordDrawableAcquisition(start: start, end: end)
        aggregate.recordCPUEncode(start: start, end: end)

        let completedGPU = RendererGPUPerformanceSnapshot(
            completedFrames: 1,
            totalNanoseconds: 1_250_000
        )
        let presentation = RendererPresentationPerformanceSnapshot(
            presentedFrames: 1,
            droppedPresentations: 0,
            intervalSamples: 0,
            totalIntervalNanoseconds: 0
        )
        let snapshot = aggregate.consumeSnapshot(
            completedGPU: completedGPU,
            presentation: presentation
        )

        XCTAssertEqual(snapshot.drawAttempts, 2)
        XCTAssertEqual(snapshot.drawableAcquisitions, 1)
        XCTAssertEqual(snapshot.encodedFrames, 1)
        XCTAssertEqual(snapshot.averageDrawableAcquisitionMilliseconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageCPUEncodeMilliseconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageGPUMilliseconds, 1.25, accuracy: 0.001)
        XCTAssertEqual(snapshot.presentedFrames, 1)
        XCTAssertEqual(aggregate.consumeSnapshot(completedGPU: RendererGPUPerformanceSnapshot(
            completedFrames: 0,
            totalNanoseconds: 0
        ), presentation: RendererPresentationPerformanceSnapshot(
            presentedFrames: 0,
            droppedPresentations: 0,
            intervalSamples: 0,
            totalIntervalNanoseconds: 0
        )), RendererPerformanceSnapshot(
            drawAttempts: 0,
            drawableAcquisitions: 0,
            drawableAcquisitionFailures: 0,
            encodedFrames: 0,
            totalDrawableAcquisitionNanoseconds: 0,
            totalCPUEncodeNanoseconds: 0,
            completedGPUFrames: 0,
            totalGPUNanoseconds: 0,
            presentedFrames: 0,
            droppedPresentations: 0,
            presentationIntervalSamples: 0,
            totalPresentationIntervalNanoseconds: 0
        ))
    }
}
