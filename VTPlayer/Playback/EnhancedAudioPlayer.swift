import AVFoundation
import Foundation

/// Audio transport driven by the enhanced renderer's media timeline.
@MainActor
final class EnhancedAudioPlayer {
    private var player: AVAudioPlayer?
    private var started = false
    private var paused = false
    private var playbackRate = 1.0
    private var volume: Float = 1.0

    func prepare(url: URL, initialRate: Double) -> Bool {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.enableRate = true
        player.rate = Float(initialRate)
        player.volume = volume
        guard player.prepareToPlay() else { return false }
        self.player = player
        playbackRate = initialRate
        return true
    }

    func frameRendered(at pts: CMTime) {
        guard let player else { return }

        guard started else {
            started = true
            player.currentTime = min(max(0, CMTimeGetSeconds(pts)), player.duration)
            player.rate = Float(playbackRate)
            if !paused {
                player.play()
            }
            return
        }

        // Keep the audio transport at the user's selected rate. Continuously
        // modulating AVAudioPlayer.rate from rendered-frame timing introduces
        // audible pitch/rate artifacts and makes enhanced audio sound worse
        // than native playback. The first rendered PTS anchors the transport;
        // seeks and pipeline restarts explicitly re-anchor it when needed.
    }

    func pause() {
        paused = true
        player?.pause()
    }

    func setVolume(_ volume: Float) {
        self.volume = min(max(volume, 0), 1)
        player?.volume = self.volume
    }

    func setRate(_ rate: Double) {
        playbackRate = min(2.0, max(0.5, rate))
        if let player, started, !paused {
            player.rate = Float(playbackRate)
        }
    }

    func resume() {
        paused = false
        guard started, let player else { return }
        player.rate = Float(playbackRate)
        player.play()
    }

    func seek(to time: CMTime, shouldPlay: Bool) {
        guard let player else { return }
        player.currentTime = min(max(0, CMTimeGetSeconds(time)), player.duration)
        if shouldPlay && !paused {
            player.rate = Float(playbackRate)
            player.play()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        started = false
        paused = false
    }
}
