import AVFoundation
import Foundation

/// Audio transport driven by the enhanced renderer's media timeline.
@MainActor
final class EnhancedAudioPlayer {
    private var player: AVAudioPlayer?
    private var started = false
    private var paused = false
    private var lastPTS: CMTime?
    private var lastWall = DispatchTime.now()
    private var smoothedRate = 1.0

    func prepare(url: URL, initialRate: Double) -> Bool {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.enableRate = true
        player.rate = Float(initialRate)
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
            lastPTS = pts
            lastWall = now
            player.currentTime = min(max(0, CMTimeGetSeconds(pts)), player.duration)
            player.rate = Float(smoothedRate)
            if !paused {
                player.play()
            }
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
        let lead = player.currentTime - CMTimeGetSeconds(pts)
        let correction = min(0.12, max(-0.12, lead * 0.35))
        player.rate = Float(min(2.0, max(0.5, smoothedRate - correction)))
    }

    func pause() {
        paused = true
        player?.pause()
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
        lastPTS = time
        lastWall = .now()
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
        lastPTS = nil
    }
}
