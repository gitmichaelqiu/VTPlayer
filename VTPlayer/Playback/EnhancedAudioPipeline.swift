import AVFoundation
import Foundation

/// Audio output whose timebase follows rendered enhanced-video PTS without
/// influencing AVPlayer's frame scheduler.
@MainActor
final class EnhancedAudioPipeline {
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let feedQueue = DispatchQueue(label: "dev.mqiu.VTPlayer.enhanced-audio")
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var started = false
    private var finished = false
    private var lastPTS: CMTime?
    private var lastWall = DispatchTime.now()
    private var smoothedRate = 1.0

    init() {
        synchronizer.addRenderer(renderer)
        synchronizer.setRate(0, time: .zero)
    }

    func prepare(url: URL, startTime: CMTime) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return false }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        if startTime > .zero {
            let duration = try await asset.load(.duration)
            let remaining = CMTimeSubtract(duration, startTime)
            guard remaining > .zero else { return false }
            reader.timeRange = CMTimeRange(start: startTime, duration: remaining)
        }
        guard reader.startReading() else { return false }
        self.reader = reader
        self.output = output
        renderer.requestMediaDataWhenReady(on: feedQueue) { [weak self] in
            Task { @MainActor [weak self] in self?.enqueueAvailableSamples() }
        }
        return true
    }

    func frameRendered(at pts: CMTime) {
        let now = DispatchTime.now()
        guard started else {
            started = true
            lastPTS = pts
            lastWall = now
            synchronizer.setRate(1, time: pts)
            return
        }

        defer {
            lastPTS = pts
            lastWall = now
        }
        guard let previousPTS = lastPTS else { return }
        let mediaDelta = CMTimeGetSeconds(CMTimeSubtract(pts, previousPTS))
        let wallNanoseconds = now.uptimeNanoseconds >= lastWall.uptimeNanoseconds
            ? now.uptimeNanoseconds - lastWall.uptimeNanoseconds
            : 0
        let wallDelta = Double(wallNanoseconds) / 1_000_000_000.0
        guard mediaDelta > 0, wallDelta > 0 else { return }

        let observedRate = min(2.0, max(0.5, mediaDelta / wallDelta))
        smoothedRate = smoothedRate * 0.85 + observedRate * 0.15
        let audioTime = synchronizer.currentTime()
        let lead = CMTimeGetSeconds(CMTimeSubtract(audioTime, pts))
        let correction = min(0.12, max(-0.12, lead * 0.35))
        let rate = min(2.0, max(0.5, smoothedRate - correction))
        synchronizer.setRate(Float(rate), time: audioTime)
    }

    func pause() {
        synchronizer.setRate(0, time: synchronizer.currentTime())
    }

    func resume() {
        guard started else { return }
        synchronizer.setRate(Float(smoothedRate), time: synchronizer.currentTime())
    }

    func stop() {
        renderer.stopRequestingMediaData()
        synchronizer.setRate(0, time: synchronizer.currentTime())
        renderer.flush()
        reader?.cancelReading()
        reader = nil
        output = nil
        finished = true
    }

    private func enqueueAvailableSamples() {
        guard !finished, let output else { return }
        while renderer.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                renderer.stopRequestingMediaData()
                finished = true
                return
            }
            renderer.enqueue(sample)
        }
    }
}
