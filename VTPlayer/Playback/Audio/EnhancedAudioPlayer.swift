import AVFoundation
import Foundation

struct EnhancedAudioOperationGate {
    private(set) var generation: UInt64 = 0
    private(set) var isAwaitingFrameAnchor = false

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    mutating func armFrameAnchor(shouldPlay: Bool) {
        invalidate()
        isAwaitingFrameAnchor = shouldPlay
    }

    mutating func beginFrameAnchor() -> UInt64? {
        guard isAwaitingFrameAnchor else { return nil }
        isAwaitingFrameAnchor = false
        return begin()
    }

    mutating func disarm() {
        invalidate()
        isAwaitingFrameAnchor = false
    }

    func accepts(_ token: UInt64) -> Bool {
        token == generation
    }
}

/// Audio-only transport for the enhanced renderer's media timeline.
///
/// AVPlayer is used instead of AVAudioPlayer so enhanced playback uses the
/// same hardware/media decode path as native playback. The item's video track
/// is disabled; only its audio clock is driven from the first rendered frame.
@MainActor
final class EnhancedAudioPlayer {
    private var player: AVPlayer?
    private var started = false
    private var paused = false
    private var playbackRate = 1.0
    private var volume: Float = 1.0
    private var operationGate = EnhancedAudioOperationGate()

    func prepare(url: URL, initialRate: Double) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
              !audioTracks.isEmpty else { return false }
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        for track in item.tracks where track.assetTrack?.mediaType == .video {
            track.isEnabled = false
        }
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = volume
        self.player = player
        started = false
        paused = false
        operationGate.armFrameAnchor(shouldPlay: true)
        playbackRate = min(2.0, max(0.5, initialRate))
        return true
    }

    func frameRendered(at pts: CMTime) {
        guard let player, !started, !paused,
              let operation = operationGate.beginFrameAnchor() else { return }

        started = true
        let seconds = CMTimeGetSeconds(pts)
        let anchor = seconds.isFinite ? max(0, seconds) : 0
        player.seek(
            to: CMTime(seconds: anchor, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] _ in
            guard let self, let player else { return }
            Task { @MainActor in
                guard self.player === player,
                      self.operationGate.accepts(operation),
                      self.started,
                      !self.paused else { return }
                player.rate = Float(self.playbackRate)
                player.play()
            }
        }
    }

    func pause() {
        paused = true
        player?.pause()
    }

    /// Stops the independent audio clock until the display path presents a
    /// frame from the new timeline. This prevents audio from leading a slow
    /// enhanced seek or pipeline restart.
    func awaitRenderedFrameAnchor(shouldPlay: Bool) {
        player?.pause()
        started = false
        paused = !shouldPlay
        operationGate.armFrameAnchor(shouldPlay: shouldPlay)
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
        guard started, let player else {
            if !operationGate.isAwaitingFrameAnchor {
                operationGate.armFrameAnchor(shouldPlay: true)
            }
            return
        }
        player.rate = Float(playbackRate)
        player.play()
    }

    func stop() {
        operationGate.disarm()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        started = false
        paused = true
    }
}
