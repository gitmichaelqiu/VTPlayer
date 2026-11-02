import Foundation
import MetalKit
import CoreVideo
import CoreImage
import QuartzCore
import Synchronization

struct RendererPerformanceSnapshot: Equatable {
    let drawAttempts: Int
    let drawableAcquisitions: Int
    let drawableAcquisitionFailures: Int
    let encodedFrames: Int
    let totalDrawableAcquisitionNanoseconds: UInt64
    let totalCPUEncodeNanoseconds: UInt64
    let completedGPUFrames: Int
    let totalGPUNanoseconds: UInt64
    let presentedFrames: Int
    let droppedPresentations: Int
    let duplicatePresentations: Int
    let presentationIntervalSamples: Int
    let totalPresentationIntervalNanoseconds: UInt64
    let presentationIntervalsNanoseconds: [UInt64]

    var averageDrawableAcquisitionMilliseconds: Double {
        guard drawableAcquisitions > 0 else { return 0 }
        return Double(totalDrawableAcquisitionNanoseconds) / Double(drawableAcquisitions) / 1_000_000.0
    }

    var averageCPUEncodeMilliseconds: Double {
        guard encodedFrames > 0 else { return 0 }
        return Double(totalCPUEncodeNanoseconds) / Double(encodedFrames) / 1_000_000.0
    }

    var averageGPUMilliseconds: Double {
        guard completedGPUFrames > 0 else { return 0 }
        return Double(totalGPUNanoseconds) / Double(completedGPUFrames) / 1_000_000.0
    }

    var averagePresentationIntervalMilliseconds: Double {
        guard presentationIntervalSamples > 0 else { return 0 }
        return Double(totalPresentationIntervalNanoseconds) /
            Double(presentationIntervalSamples) / 1_000_000.0
    }

    var p50PresentationIntervalMilliseconds: Double {
        percentilePresentationInterval(0.50)
    }

    var p95PresentationIntervalMilliseconds: Double {
        percentilePresentationInterval(0.95)
    }

    var maximumPresentationGapMilliseconds: Double {
        Double(presentationIntervalsNanoseconds.max() ?? 0) / 1_000_000.0
    }

    var presentationIntervalStandardDeviationMilliseconds: Double {
        guard presentationIntervalsNanoseconds.count > 1 else { return 0 }
        let sampleCount = Double(presentationIntervalsNanoseconds.count)
        let mean = Double(presentationIntervalsNanoseconds.reduce(UInt64(0), +)) / sampleCount
        let squaredDeviation = presentationIntervalsNanoseconds.reduce(into: 0.0) { total, interval in
            let deviation = Double(interval) - mean
            total += deviation * deviation
        }
        return sqrt(squaredDeviation / sampleCount) / 1_000_000.0
    }

    private func percentilePresentationInterval(_ percentile: Double) -> Double {
        guard !presentationIntervalsNanoseconds.isEmpty else { return 0 }
        let sorted = presentationIntervalsNanoseconds.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * percentile).rounded(.up)))
        )
        return Double(sorted[index]) / 1_000_000.0
    }
}

nonisolated private struct RendererPerformanceStorage: Sendable {
    var drawAttempts = 0
    var drawableAcquisitions = 0
    var drawableAcquisitionFailures = 0
    var encodedFrames = 0
    var totalDrawableAcquisitionNanoseconds: UInt64 = 0
    var totalCPUEncodeNanoseconds: UInt64 = 0
}

final class RendererPerformanceAggregate: @unchecked Sendable {
    private let storage = Mutex(RendererPerformanceStorage())

    nonisolated func recordDrawAttempt() {
        storage.withLock { $0.drawAttempts += 1 }
    }

    nonisolated func recordDrawableAcquisition(start: DispatchTime, end: DispatchTime = .now()) {
        storage.withLock { storage in
            storage.drawableAcquisitions += 1
            guard end.uptimeNanoseconds >= start.uptimeNanoseconds else { return }
            storage.totalDrawableAcquisitionNanoseconds += end.uptimeNanoseconds - start.uptimeNanoseconds
        }
    }

    nonisolated func recordDrawableAcquisitionFailure() {
        storage.withLock { $0.drawableAcquisitionFailures += 1 }
    }

    nonisolated func recordCPUEncode(start: DispatchTime, end: DispatchTime = .now()) {
        storage.withLock { storage in
            storage.encodedFrames += 1
            guard end.uptimeNanoseconds >= start.uptimeNanoseconds else { return }
            storage.totalCPUEncodeNanoseconds += end.uptimeNanoseconds - start.uptimeNanoseconds
        }
    }

    nonisolated func consumeSnapshot(
        completedGPU: RendererGPUPerformanceSnapshot,
        presentation: RendererPresentationPerformanceSnapshot
    ) -> RendererPerformanceSnapshot {
        storage.withLock { storage in
            let snapshot = RendererPerformanceSnapshot(
                drawAttempts: storage.drawAttempts,
                drawableAcquisitions: storage.drawableAcquisitions,
                drawableAcquisitionFailures: storage.drawableAcquisitionFailures,
                encodedFrames: storage.encodedFrames,
                totalDrawableAcquisitionNanoseconds: storage.totalDrawableAcquisitionNanoseconds,
                totalCPUEncodeNanoseconds: storage.totalCPUEncodeNanoseconds,
                completedGPUFrames: completedGPU.completedFrames,
                totalGPUNanoseconds: completedGPU.totalNanoseconds,
                presentedFrames: presentation.presentedFrames,
                droppedPresentations: presentation.droppedPresentations,
                duplicatePresentations: presentation.duplicatePresentations,
                presentationIntervalSamples: presentation.intervalSamples,
                totalPresentationIntervalNanoseconds: presentation.totalIntervalNanoseconds,
                presentationIntervalsNanoseconds: presentation.intervalsNanoseconds
            )
            storage = RendererPerformanceStorage()
            return snapshot
        }
    }
}

struct RendererPresentationPerformanceSnapshot: Equatable, Sendable {
    let presentedFrames: Int
    let droppedPresentations: Int
    let duplicatePresentations: Int
    let intervalSamples: Int
    let totalIntervalNanoseconds: UInt64
    let intervalsNanoseconds: [UInt64]
}

private struct RendererPresentationPerformanceStorage: Sendable {
    var presentedFrames = 0
    var totalPresentedFrames = 0
    var droppedPresentations = 0
    var duplicatePresentations = 0
    var intervalSamples = 0
    var totalIntervalNanoseconds: UInt64 = 0
    var intervalsNanoseconds: [UInt64] = []
    var previousPresentedTime: CFTimeInterval?
}

final class RendererPresentationPerformanceRecorder: @unchecked Sendable {
    private let storage = Mutex(RendererPresentationPerformanceStorage())

    nonisolated func record(presentedTime: CFTimeInterval) {
        storage.withLock { storage in
            guard presentedTime.isFinite, presentedTime > 0 else {
                storage.droppedPresentations += 1
                return
            }
            if let previous = storage.previousPresentedTime {
                if presentedTime == previous {
                    storage.duplicatePresentations += 1
                    return
                }
                guard presentedTime > previous else {
                    storage.droppedPresentations += 1
                    return
                }
                let interval = (presentedTime - previous) * 1_000_000_000
                if interval <= Double(UInt64.max) {
                    let intervalNanoseconds = UInt64(interval)
                    storage.totalIntervalNanoseconds += intervalNanoseconds
                    storage.intervalSamples += 1
                    if storage.intervalsNanoseconds.count >= 2_048 {
                        storage.intervalsNanoseconds.removeFirst(1_024)
                    }
                    storage.intervalsNanoseconds.append(intervalNanoseconds)
                }
            }
            storage.presentedFrames += 1
            storage.totalPresentedFrames += 1
            storage.previousPresentedTime = presentedTime
        }
    }

    nonisolated func consumeSnapshot() -> RendererPresentationPerformanceSnapshot {
        storage.withLock { storage in
            let snapshot = RendererPresentationPerformanceSnapshot(
                presentedFrames: storage.presentedFrames,
                droppedPresentations: storage.droppedPresentations,
                duplicatePresentations: storage.duplicatePresentations,
                intervalSamples: storage.intervalSamples,
                totalIntervalNanoseconds: storage.totalIntervalNanoseconds,
                intervalsNanoseconds: storage.intervalsNanoseconds
            )
            storage.presentedFrames = 0
            storage.droppedPresentations = 0
            storage.duplicatePresentations = 0
            storage.intervalSamples = 0
            storage.totalIntervalNanoseconds = 0
            storage.intervalsNanoseconds.removeAll(keepingCapacity: true)
            storage.previousPresentedTime = nil
            return snapshot
        }
    }

    nonisolated func totalPresentedFrames() -> Int {
        storage.withLock { $0.totalPresentedFrames }
    }
}

struct RendererGPUPerformanceSnapshot: Equatable, Sendable {
    let completedFrames: Int
    let totalNanoseconds: UInt64
}

struct RendererSchedulingSnapshot: Equatable {
    let preferredFramesPerSecond: Int
    let presentsWithTransaction: Bool
    let displaySyncEnabled: Bool
    let screenMaximumFramesPerSecond: Int
    let screenMinimumRefreshInterval: TimeInterval
    let screenMaximumRefreshInterval: TimeInterval
    let displayModeRefreshRate: Double
}

private struct RendererGPUPerformanceStorage: Sendable {
    var completedFrames = 0
    var totalNanoseconds: UInt64 = 0
}

final class RendererGPUPerformanceRecorder: @unchecked Sendable {
    private let storage = Mutex(RendererGPUPerformanceStorage())

    func recordCompletion(durationNanoseconds: UInt64) {
        storage.withLock { storage in
            storage.completedFrames += 1
            storage.totalNanoseconds += durationNanoseconds
        }
    }

    func consumeSnapshot() -> RendererGPUPerformanceSnapshot {
        storage.withLock { storage in
            let snapshot = RendererGPUPerformanceSnapshot(
                completedFrames: storage.completedFrames,
                totalNanoseconds: storage.totalNanoseconds
            )
            storage = RendererGPUPerformanceStorage()
            return snapshot
        }
    }
}

