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
    private var anchorInProgress = false
    private var paused = false
    private var playbackRate = 1.0
    private var volume: Float = 1.0
    private var operationGate = EnhancedAudioOperationGate()
    private var latestRenderedPTS: CMTime = .invalid
    private weak var referencePlayer: AVPlayer?
    private var nextSyncCheck = 0.0

    var currentTime: CMTime? {
        guard started, !anchorInProgress, !paused, let player else { return nil }
        return player.currentTime()
    }

    func prepare(url: URL, initialRate: Double, referencePlayer: AVPlayer) async -> Bool {
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
        self.referencePlayer = referencePlayer
        started = false
        paused = false
        operationGate.armFrameAnchor(shouldPlay: true)
        playbackRate = min(2.0, max(0.5, initialRate))
        return true
    }

    func frameRendered(at pts: CMTime) {
        guard pts.isValid, pts.isNumeric else { return }
        latestRenderedPTS = pts
        if started, !anchorInProgress, !paused, let player, let referencePlayer {
            let now = CACurrentMediaTime()
            if now >= nextSyncCheck {
                nextSyncCheck = now + 1
                let referenceTime = referencePlayer.currentTime()
                let difference = CMTimeGetSeconds(CMTimeSubtract(player.currentTime(), referenceTime))
                if referencePlayer.rate != 0, difference.isFinite, abs(difference) > 0.12 {
                    player.setRate(Float(playbackRate), time: referenceTime,
                                   atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
                }
            }
        }
        guard let player, player.status == .readyToPlay, !started, !paused,
              let operation = operationGate.beginFrameAnchor() else { return }

        started = true
        anchorInProgress = true
        let seconds = CMTimeGetSeconds(pts)
        let anchor = seconds.isFinite ? max(0, seconds) : 0
        player.seek(
            to: CMTime(seconds: anchor, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] completed in
            guard let self, let player else { return }
            Task { @MainActor in
                guard self.player === player,
                      self.operationGate.accepts(operation),
                      self.started,
                      !self.paused else { return }
                guard completed, player.status == .readyToPlay else {
                    self.started = false
                    self.anchorInProgress = false
                    self.operationGate.armFrameAnchor(shouldPlay: true)
                    return
                }
                // The transport can advance while the audio seek is pending.
                let referenceTime = self.referencePlayer?.currentTime() ?? self.latestRenderedPTS
                player.setRate(
                    Float(self.playbackRate),
                    time: referenceTime.isNumeric ? referenceTime : self.latestRenderedPTS,
                    atHostTime: CMClockGetTime(CMClockGetHostTimeClock())
                )
                self.anchorInProgress = false
            }
        }
    }

    func pause() {
        paused = true
        player?.pause()
        started = false
        anchorInProgress = false
        operationGate.armFrameAnchor(shouldPlay: false)
    }

    /// Stops the independent audio clock until the display path presents a
    /// frame from the new timeline. This prevents audio from leading a slow
    /// enhanced seek or pipeline restart.
    func awaitRenderedFrameAnchor(shouldPlay: Bool) {
        player?.pause()
        started = false
        anchorInProgress = false
        paused = !shouldPlay
        operationGate.armFrameAnchor(shouldPlay: shouldPlay)
    }

    func setVolume(_ volume: Float) {
        self.volume = min(max(volume, 0), 1)
        player?.volume = self.volume
    }

    func setRate(_ rate: Double) {
        playbackRate = min(2.0, max(0.5, rate))
        if let player, started, !anchorInProgress, !paused {
            player.rate = Float(playbackRate)
        }
    }

    func resume() {
        paused = false
        if !started && !operationGate.isAwaitingFrameAnchor {
            operationGate.armFrameAnchor(shouldPlay: true)
        }
    }

    func stop() {
        operationGate.disarm()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        referencePlayer = nil
        started = false
        anchorInProgress = false
        paused = true
    }
}
