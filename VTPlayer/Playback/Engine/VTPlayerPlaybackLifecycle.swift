import SwiftUI
import AVFoundation
import VideoToolbox
import CoreVideo
import MetalKit
#if os(iOS)
import MediaPlayer
#endif

extension VTPlayerViewModel {
    func stop() {
        cancelEnhancedCachePreparation()
        stopEnhancedAudioPlayback()
        inactivityTask?.cancel()
        inactivityTask = nil
        #if os(macOS)
        pipelinePresentationReady = false
        renderer.setRenderingActive(false)
        setNativeVideoEnabled(false)
        stopDisplayLinkIfNeeded()
        #endif
        pipelineRestartTask?.cancel()
        pipelineRestartTask = nil
        playbackGeneration += 1
        seekGeneration &+= 1
        if self.currentTime > 0 {
            self.saveProgress()
        }
        saveVideoSettings()
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        let producer = producerTask
        producerTask?.cancel()
        producerTask = nil
        #if os(macOS)
        fullCacheReaderControl = nil
        fullCachePresentationQueue = nil
        #endif
        consumerTask?.cancel()
        consumerTask = nil
        endActiveCoordinator(after: producer)
        #if os(macOS)
        stopDisplayLinkIfNeeded()
        #else
        if let link = displayLink {
            link.invalidate()
            self.displayLink = nil
        }
        #endif
        if let scoped = securityScopedURL {
            scoped.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
        audioSyncTask?.cancel()
        audioSyncTask = nil
        audioSyncLatency = 0
        pipelineRestartAnchorPTS = nil
        lastRenderedPTS = .zero
        lockCache { clearProcessedFrameCache() }

        if let observer = playerItemObserver {
            NotificationCenter.default.removeObserver(observer)
            playerItemObserver = nil
        }
        if let observer = timeJumpedObserver {
            NotificationCenter.default.removeObserver(observer)
            timeJumpedObserver = nil
        }
        rateObserver?.invalidate()
        rateObserver = nil
        player?.pause()
        player = nil
        #if os(iOS)
        clearNowPlayingInfo()
        #endif

        self.isPlaying = false
        self.isPaused = false
        self.isBuffering = false
        self.currentTime = 0.0
        self.lastPublishedCurrentTime = -Double.infinity
        self.duration = 0.0
        self.fps = 0.0
        self.displayRate1PercentLow = 0.0
        self.presentedFramesCount = 0
        self.diagnosticPresentedFramesCount = 0
        self.diagnosticPresentedInterpolatedCount = 0
        self.diagnosticPresentedSourceCount = 0
        self.producedFramesCount = 0
        self.displayLinkTickCount = 0
        self.displayRateSamples.removeAll(keepingCapacity: true)
        self.displayRateMeasurementStart = .now()
        self.frameProcessingTime = 0.0
        self.aneUsagePercent = 0.0
        self.srInitializationError = nil
        self.isInitializingPipeline = false
        self.enhancementsPendingRestart = false
        self.renderer.clear()
        self.userActivityDetected()
    }

}
