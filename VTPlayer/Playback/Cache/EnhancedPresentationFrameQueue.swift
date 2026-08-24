import AVFoundation
import CoreVideo
import Foundation
import Synchronization

nonisolated struct EnhancedPresentationQueueSnapshot: Sendable {
    let frameCount: Int
    let byteUsage: Int
    let nextPresentationSeconds: Double?
    let enqueuedFrames: Int
    let cacheHitGroups: Int
    let intentionallySampledOutFrames: Int
    let dequeueAttempts: Int
    let starvationCount: Int
    let lateInterpolatedDrops: Int
}

nonisolated struct EnhancedPresentationFrameSelection: Sendable {
    let frame: VTFrame
    let droppedInterpolatedFrames: Int
}

nonisolated private struct EnhancedPresentationFrameQueueState: Sendable {
    var frames: [VTFrame] = []
    var startIndex = 0
    var queuedByteUsage = 0
    var generation: UInt64
    var enqueuedFrames = 0
    var cacheHitGroups = 0
    var intentionallySampledOutFrames = 0
    var dequeueAttempts = 0
    var starvationCount = 0
    var lateInterpolatedDrops = 0
}

nonisolated final class EnhancedPresentationFrameQueue: @unchecked Sendable {
    private let capacityBytes: Int
    private let capacityFrames: Int
    private let state: Mutex<EnhancedPresentationFrameQueueState>

    init(capacityBytes: Int, capacityFrames: Int, generation: UInt64) {
        self.capacityBytes = capacityBytes
        self.capacityFrames = capacityFrames
        self.state = Mutex(EnhancedPresentationFrameQueueState(generation: generation))
    }

    func reset(generation: UInt64) {
        state.withLock { state in
            state.frames.removeAll(keepingCapacity: true)
            state.startIndex = 0
            state.queuedByteUsage = 0
            state.generation = generation
            state.enqueuedFrames = 0
            state.cacheHitGroups = 0
            state.intentionallySampledOutFrames = 0
            state.dequeueAttempts = 0
            state.starvationCount = 0
            state.lateInterpolatedDrops = 0
        }
    }

    func enqueue(contentsOf frames: [VTFrame], generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == generation else { return false }
            let byteCount = frames.reduce(into: 0) { total, frame in
                total += CVPixelBufferGetDataSize(frame.buffer)
            }
            guard !frames.isEmpty,
                  byteCount <= capacityBytes,
                  state.queuedByteUsage <= capacityBytes - byteCount,
                  state.frames.count - state.startIndex <= capacityFrames - frames.count else {
                return false
            }
            var previousPTS = state.frames.last?.presentationTimeStamp
            for frame in frames {
                if let previousPTS,
                   CMTimeCompare(previousPTS, frame.presentationTimeStamp) >= 0 {
                    return false
                }
                previousPTS = frame.presentationTimeStamp
            }
            state.frames.append(contentsOf: frames)
            state.queuedByteUsage += byteCount
            state.enqueuedFrames += frames.count
            return true
        }
    }

    func recordCacheHitGroup(generation: UInt64, sampledOutFrames: Int = 0) {
        state.withLock { state in
            guard state.generation == generation else { return }
            state.cacheHitGroups += 1
            state.intentionallySampledOutFrames += max(0, sampledOutFrames)
        }
    }

    func dequeueNewestDue(
        at presentationSeconds: Double,
        after lastRenderedPTS: CMTime,
        catchesUpInterpolation: Bool
    ) -> EnhancedPresentationFrameSelection? {
        state.withLock { state in
            state.dequeueAttempts += 1
            if state.startIndex >= state.frames.count {
                state.starvationCount += 1
            }
            var selected: VTFrame?
            var droppedInterpolatedFrames = 0

            func consumeNext() {
                let frame = state.frames[state.startIndex]
                state.queuedByteUsage = max(
                    0,
                    state.queuedByteUsage - CVPixelBufferGetDataSize(frame.buffer)
                )
                state.startIndex += 1
            }

            while state.startIndex < state.frames.count {
                let candidate = state.frames[state.startIndex]
                if CMTimeCompare(candidate.presentationTimeStamp, lastRenderedPTS) <= 0 {
                    if candidate.isInterpolated {
                        droppedInterpolatedFrames += 1
                    }
                    consumeNext()
                    continue
                }
                let candidateSeconds = CMTimeGetSeconds(candidate.presentationTimeStamp)
                guard candidateSeconds <= presentationSeconds + 0.005 else { break }

                selected = candidate
                consumeNext()
                if !catchesUpInterpolation {
                    break
                }
                if candidate.isInterpolated {
                    droppedInterpolatedFrames += 1
                }
            }

            guard let selected else {
                compactConsumedFrames(&state)
                return nil
            }
            if selected.isInterpolated, droppedInterpolatedFrames > 0 {
                droppedInterpolatedFrames -= 1
            }
            state.lateInterpolatedDrops += droppedInterpolatedFrames
            compactConsumedFrames(&state)
            return EnhancedPresentationFrameSelection(
                frame: selected,
                droppedInterpolatedFrames: droppedInterpolatedFrames
            )
        }
    }

    func snapshot(consumeActivity: Bool = false) -> EnhancedPresentationQueueSnapshot {
        state.withLock { state in
            let snapshot = EnhancedPresentationQueueSnapshot(
                frameCount: state.frames.count - state.startIndex,
                byteUsage: state.queuedByteUsage,
                nextPresentationSeconds: state.startIndex < state.frames.count
                    ? CMTimeGetSeconds(state.frames[state.startIndex].presentationTimeStamp)
                    : nil,
                enqueuedFrames: state.enqueuedFrames,
                cacheHitGroups: state.cacheHitGroups,
                intentionallySampledOutFrames: state.intentionallySampledOutFrames,
                dequeueAttempts: state.dequeueAttempts,
                starvationCount: state.starvationCount,
                lateInterpolatedDrops: state.lateInterpolatedDrops
            )
            if consumeActivity {
                state.enqueuedFrames = 0
                state.cacheHitGroups = 0
                state.intentionallySampledOutFrames = 0
                state.dequeueAttempts = 0
                state.starvationCount = 0
                state.lateInterpolatedDrops = 0
            }
            return snapshot
        }
    }

    private func compactConsumedFrames(_ state: inout EnhancedPresentationFrameQueueState) {
        guard state.startIndex > 0,
              state.startIndex >= 64 || state.startIndex * 2 >= state.frames.count else {
            return
        }
        state.frames.removeFirst(state.startIndex)
        state.startIndex = 0
    }
}

nonisolated final class EnhancedPresentationReaderControl: @unchecked Sendable {
    nonisolated struct Request: Sendable {
        var generation: UInt64
        var seconds: Double
    }

    private let state: Mutex<Request>

    init(startTime: CMTime, generation: UInt64) {
        self.state = Mutex(Request(generation: generation, seconds: CMTimeGetSeconds(startTime)))
    }

    func requestSeek(to time: CMTime) {
        let seconds = CMTimeGetSeconds(time)
        state.withLock { request in
            request.generation &+= 1
            request.seconds = seconds.isFinite ? max(0, seconds) : 0
        }
    }

    func request() -> Request {
        state.withLock { $0 }
    }
}
