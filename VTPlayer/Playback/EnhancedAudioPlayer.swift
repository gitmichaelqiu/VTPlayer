import AVFoundation
import Foundation

/// Audio transport driven by the enhanced renderer's media timeline.
@MainActor
final class EnhancedAudioPlayer {
    private var player: AVAudioPlayer?
    private var started = false
    private var paused = false
    private var rateReferencePTS: CMTime?
    private var rateReferenceWall = DispatchTime.now()
    private var smoothedRate = 1.0
    private var volume: Float = 1.0

    func prepare(url: URL, initialRate: Double) -> Bool {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.enableRate = true
        player.rate = Float(initialRate)
        player.volume = volume
        guard player.prepareToPlay() else { return false }
        self.player = player
        smoothedRate = initialRate
        return true
    }

    func frameRendered(at pts: CMTime) {
        let now = DispatchTime.now()
        guard let player else { return }

        guard started else {
            started = true
            rateReferencePTS = pts
            rateReferenceWall = now
            player.currentTime = min(max(0, CMTimeGetSeconds(pts)), player.duration)
            player.rate = Float(smoothedRate)
            if !paused {
                player.play()
            }
            return
        }

        guard let rateReferencePTS else { return }
        let wallNanoseconds = now.uptimeNanoseconds >= rateReferenceWall.uptimeNanoseconds
            ? now.uptimeNanoseconds - rateReferenceWall.uptimeNanoseconds
            : 0
        let wallDelta = Double(wallNanoseconds) / 1_000_000_000.0
        guard wallDelta >= 0.2 else { return }

        let mediaDelta = CMTimeGetSeconds(CMTimeSubtract(pts, rateReferencePTS))
        guard mediaDelta > 0 else { return }

        let observedRate = min(2.0, max(0.5, mediaDelta / wallDelta))
        smoothedRate = smoothedRate * 0.9 + observedRate * 0.1
        let lead = player.currentTime - CMTimeGetSeconds(pts)
        let correction = min(0.12, max(-0.12, lead * 0.35))
        let requestedRate = min(2.0, max(0.5, smoothedRate - correction))
        let currentRate = Double(player.rate)
        let boundedRate = currentRate + min(0.025, max(-0.025, requestedRate - currentRate))
        if abs(boundedRate - currentRate) >= 0.005 {
            player.rate = Float(boundedRate)
        }
        self.rateReferencePTS = pts
        rateReferenceWall = now
    }

    func pause() {
        paused = true
        player?.pause()
    }

    func setVolume(_ volume: Float) {
        self.volume = min(max(volume, 0), 1)
        player?.volume = self.volume
    }

    func resume() {
        paused = false
        guard started, let player else { return }
        player.rate = Float(smoothedRate)
        player.play()
    }

    func seek(to time: CMTime, shouldPlay: Bool) {
        guard let player else { return }
        player.currentTime = min(max(0, CMTimeGetSeconds(time)), player.duration)
        rateReferencePTS = time
        rateReferenceWall = .now()
        if shouldPlay && !paused {
            player.rate = Float(smoothedRate)
            player.play()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        started = false
        paused = false
        rateReferencePTS = nil
    }
}
