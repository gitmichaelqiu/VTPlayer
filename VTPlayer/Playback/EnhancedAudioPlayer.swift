import AVFoundation
import Foundation

/// Plays an audio-only composition whose timeline follows enhanced frames.
@MainActor
final class EnhancedAudioPlayer {
    private let player = AVPlayer()
    private var started = false
    private var paused = false
    private var lastPTS: CMTime?
    private var lastWall = DispatchTime.now()
    private var smoothedRate = 1.0

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func prepare(url: URL, initialRate: Double) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return false
        }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        guard duration > .zero,
              let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            return false
        }

        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceTrack,
            at: .zero
        )
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        smoothedRate = initialRate
        return true
    }

    func frameRendered(at pts: CMTime) {
        let now = DispatchTime.now()
        guard started else {
            started = true
            lastPTS = pts
            lastWall = now
            start(at: pts, rate: smoothedRate)
            return
        }

        defer {
            lastPTS = pts
            lastWall = now
        }
        guard let lastPTS else { return }
        let mediaDelta = CMTimeGetSeconds(CMTimeSubtract(pts, lastPTS))
        let wallNanoseconds = now.uptimeNanoseconds >= lastWall.uptimeNanoseconds
            ? now.uptimeNanoseconds - lastWall.uptimeNanoseconds
            : 0
        let wallDelta = Double(wallNanoseconds) / 1_000_000_000.0
        guard mediaDelta > 0, wallDelta > 0 else { return }

        let observedRate = min(2.0, max(0.5, mediaDelta / wallDelta))
        smoothedRate = smoothedRate * 0.85 + observedRate * 0.15
        let lead = CMTimeGetSeconds(CMTimeSubtract(player.currentTime(), pts))
        let correction = min(0.12, max(-0.12, lead * 0.35))
        player.rate = Float(min(2.0, max(0.5, smoothedRate - correction)))
    }

    func pause() {
        paused = true
        player.pause()
    }

    func resume() {
        paused = false
        guard started else { return }
        player.rate = Float(smoothedRate)
    }

    func seek(to time: CMTime, shouldPlay: Bool) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        lastPTS = time
        lastWall = .now()
        if shouldPlay {
            player.rate = Float(smoothedRate)
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        started = false
        paused = false
        lastPTS = nil
    }

    private func start(at time: CMTime, rate: Double) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.paused else { return }
                self.player.rate = Float(rate)
            }
        }
    }
}
