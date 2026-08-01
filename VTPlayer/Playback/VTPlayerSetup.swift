import SwiftUI
import AVFoundation
import VideoToolbox

extension VTPlayerViewModel {
    func setupPlayer(with url: URL) {
        pendingResumePTS = nil
        ignoreAutomaticTimeJumpsUntil = nil
        // Capability probing is asynchronous. Clear the previous video's
        // scale set immediately so its enabled menu items cannot leak into
        // the new video's loading window.
        srIsSupported = false
        srSupportedScales = "None"
        frameInterpolationIsSupported = false
        availableSuperResolutionScales.removeAll()
        availableQualitySuperResolutionScales.removeAll()
        readyQualitySuperResolutionScales.removeAll()
        useSequentialSRFIFallback = false
        let asset = AVURLAsset(url: url)
        let setupGeneration = playbackGeneration
        
        Task {
            do {
                // Load metadata asynchronously using Swift 6 friendly API
                let durationTime = try await asset.load(.duration)
                let durationSecs = CMTimeGetSeconds(durationTime)
                
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    return
                }
                
                // Get the encoded pixel dimensions used by AVAssetReader and
                // VideoToolbox. `naturalSize` is display geometry and can be
                // altered by rotation or a clean aperture, which can make a
                // capability probe disagree with the actual pixel buffers.
                let descriptions = try await videoTrack.load(.formatDescriptions)
                let encodedDimensions: CMVideoDimensions?
                if let firstDesc = descriptions.first {
                    encodedDimensions = CMVideoFormatDescriptionGetDimensions(firstDesc)
                } else {
                    encodedDimensions = nil
                }
                let naturalSize = try await videoTrack.load(.naturalSize)
                let width = Int(encodedDimensions?.width ?? Int32(naturalSize.width))
                let height = Int(encodedDimensions?.height ?? Int32(naturalSize.height))
                
                // Get framerate
                let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
                let frameRate = Double(nominalFrameRate)
                let frameInterpolationSupported = VTFrameProcessorCoordinator
                    .isFrameInterpolationSupported(width: width, height: height)
                
                // Get format description
                var formatStr = "Unknown"
                if let firstDesc = descriptions.first {
                    let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
                    formatStr = "\(fourCharCodeString(subType))"
                }
                
                // Perform SR support checks
                let supported = VTFrameProcessorCoordinator.isSuperResolutionSupported()
                let scales = VTFrameProcessorCoordinator.supportedSuperResolutionScaleFactors(width: width, height: height)
                let scalesStr = scales.isEmpty ? "None" : scales.map { String(format: "%.1fx", $0) }.joined(separator: ", ")
                // Probe each selectable LL SR mode at the dimensions it will
                // actually process. A 4x cascade needs a second supported 2x
                // processor at the first-stage output size; do not advertise
                // it merely because the source-resolution stage works.
                let ll2SessionSupported = await VTFrameProcessorCoordinator
                    .canStartLowLatencyPipeline(width: width, height: height, scale: 2)
                let ll4SessionSupported: Bool
                if ll2SessionSupported {
                    ll4SessionSupported = VTFrameProcessorCoordinator
                        .isLowLatencySuperResolutionSupported(width: width * 2, height: height * 2, scale: 2.0)
                } else {
                    ll4SessionSupported = false
                }
                var availableSRScales: Set<Float> = []
                for scale in scales where scale > 0 && scale != 4 {
                    if await VTFrameProcessorCoordinator
                        .canStartLowLatencyPipeline(width: width, height: height, scale: scale) {
                        availableSRScales.insert(scale)
                    }
                }
                if ll4SessionSupported {
                    availableSRScales.insert(4)
                }
                let availableScalesStr = availableSRScales.isEmpty
                    ? "None"
                    : availableSRScales.sorted().map { String(format: "%.1fx", $0) }.joined(separator: ", ")
                var availableQualityScales: Set<Int> = []
                var readyQualityScales: Set<Int> = []
                #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
                if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
                   VTSuperResolutionScalerConfiguration.isSupported {
                    // Check both the global scale list and this video's
                    // dimensions. A machine can expose the processor while a
                    // particular resolution still cannot create a session.
                    for scale in VTSuperResolutionScalerConfiguration.supportedScaleFactors where scale == 2 || scale == 4 {
                        if VTFrameProcessorCoordinator.isQualitySuperResolutionSupported(
                            width: width, height: height, scale: scale
                        ) {
                            availableQualityScales.insert(scale)
                            if let modelConfig = VTSuperResolutionScalerConfiguration(
                                frameWidth: width, frameHeight: height,
                                scaleFactor: scale, inputType: .video,
                                usePrecomputedFlow: false, qualityPrioritization: .normal,
                                revision: .revision1
                            ), modelConfig.configurationModelStatus == .ready {
                                readyQualityScales.insert(scale)
                            }
                        }
                    }
                }
                #endif

                NSLog("CAPABILITY: video=\(width)x\(height) FI=\(frameInterpolationSupported) LL reported=\(scalesStr) LL session2=\(ll2SessionSupported) LL menu=\(availableSRScales.sorted()) QL menu=\(availableQualityScales.sorted()) QL ready=\(readyQualityScales.sorted())")

                // Quality SR has a second availability dimension: the
                // per-resolution configuration may exist while its neural
                // network weights are still unavailable. Check the model for
                // this video's first supported quality scale so the main
                // enhancement menu cannot start a guaranteed fallback.
                if let modelScale = availableQualityScales.sorted().first,
                   #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
                   let modelConfig = VTSuperResolutionScalerConfiguration(
                       frameWidth: width, frameHeight: height,
                       scaleFactor: modelScale, inputType: .video,
                       usePrecomputedFlow: false, qualityPrioritization: .normal,
                       revision: .revision1
                   ) {
                    self.modelManager.checkStatus(for: modelConfig)
                }
                
                // AVPlayer owns audio and native fallback presentation. Enhanced
                // video frames are decoded independently by VTFrameSequence.
                let item = AVPlayerItem(asset: asset)

                let newPlayer = AVPlayer(playerItem: item)
                newPlayer.automaticallyWaitsToMinimizeStalling = false
                #if os(iOS)
                configureAudioSessionForPlayback()
                #endif
                
                // Update properties on @MainActor
                await MainActor.run {
                    guard setupGeneration == self.playbackGeneration,
                          self.videoURL == url else { return }

                    #if os(macOS)
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    self.recordRecentDateIfNeeded(for: url)
                    self.addRecentVideoMac(url)
                    #endif
                    
                    self.duration = durationSecs
                    self.videoWidth = width
                    self.videoHeight = height
                    self.sourceFrameRate = frameRate
                    self.videoFormat = formatStr
                    self.frameInterpolationIsSupported = frameInterpolationSupported
                    self.srIsSupported = supported && !availableSRScales.isEmpty
                    self.srSupportedScales = availableScalesStr
                    self.availableSuperResolutionScales = availableSRScales
                    self.availableQualitySuperResolutionScales = availableQualityScales
                    self.readyQualitySuperResolutionScales = readyQualityScales
                    
                    self.player = newPlayer
                    #if os(iOS)
                    self.publishNowPlayingArtwork(for: url, duration: durationSecs)
                    #endif

                    let timeObserver = newPlayer.addPeriodicTimeObserver(
                        forInterval: CMTime(value: 1, timescale: 30),
                        queue: .main
                    ) { [self] time in
                        let seconds = CMTimeGetSeconds(time)
                        guard seconds.isFinite else { return }
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.videoURL == url else { return }
                            if let pendingResumePTS = self.pendingResumePTS,
                               abs(seconds - CMTimeGetSeconds(pendingResumePTS)) < 0.25 {
                                self.pendingResumePTS = nil
                            }
                            self.publishCurrentTime(seconds)
                        }
                    }
                    self.timeObserverToken = timeObserver
                    
                    // Observe play ending to auto-rewind
                    let observer = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: item,
                        queue: .main
                    ) { [self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.pause()
                            self.seek(to: 0)
                            self.startPlaybackLoop()
                        }
                    }
                    self.playerItemObserver = observer
                    
                    // Observe time jumps (seeks) to sync pipeline iterator
                    let jumpObserver = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemTimeJumped,
                        object: item,
                        queue: .main
                    ) { [self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.handleTimeJump()
                        }
                    }
                    self.timeJumpedObserver = jumpObserver
                    
                    // Observe AVPlayer's timeControlStatus to sync player state with isPaused
                    self.rateObserver = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [self] player, change in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            switch player.timeControlStatus {
                            case .paused:
                                if !self.isInitializingPipeline,
                                   !self.isBuffering,
                                   self.isPlaying,
                                   !self.isPaused {
                                    // Native iOS controls pause AVPlayer
                                    // directly. Mirror that action through
                                    // the enhancement lifecycle so Metal and
                                    // the independent audio transport stop too.
                                    self.pause()
                                }
                            case .playing:
                                if !self.isInitializingPipeline,
                                   self.isPlaying,
                                   self.isPaused {
                                    self.play()
                                }
                            case .waitingToPlayAtSpecifiedRate:
                                break
                            @unknown default:
                                break
                            }
                        }
                    }
                    
                    // Restore per-video enhancement settings
                    self.loadVideoSettings(for: url)
                    self.validateEnhancementSelections()
                    #if os(macOS)
                    self.setNativeVideoEnabled(!self.isPipelineActive)
                    #endif

                    let savedProgress = UserDefaults.standard.double(forKey: "VTPlaybackProgress_\(url.lastPathComponent)")
                    let resumeTime: CMTime?
                    if self.shouldContinueVideoPlayback,
                       savedProgress > 0,
                       savedProgress < durationSecs {
                        self.currentTime = savedProgress
                        resumeTime = CMTime(seconds: savedProgress, preferredTimescale: 600)
                    } else {
                        self.currentTime = 0.0
                        resumeTime = nil
                    }

                    // Start processing only after the initial seek completes
                    // and AVPlayer reports the requested position. Otherwise
                    // the producer can prebuffer from the saved position while
                    // the player clock still briefly reports zero.
                    guard let resumeTime else {
                        self.play()
                        return
                    }
                    let completionViewModel = self
                    self.pendingResumePTS = resumeTime
                    Task { @MainActor [weak completionViewModel] in
                        var settled = false
                        for _ in 0..<20 {
                            let completed = await newPlayer.seek(
                                to: resumeTime,
                                toleranceBefore: .zero,
                                toleranceAfter: .zero
                            )
                            let observedTime = CMTimeGetSeconds(newPlayer.currentTime())
                            if completed, observedTime.isFinite,
                               abs(observedTime - CMTimeGetSeconds(resumeTime)) < 0.25 {
                                settled = true
                                break
                            }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        guard settled,
                              let completionViewModel,
                              completionViewModel.player === newPlayer,
                              completionViewModel.videoURL == url else { return }
                        completionViewModel.currentTime = CMTimeGetSeconds(newPlayer.currentTime())
                        completionViewModel.pendingResumePTS = nil
                        completionViewModel.ignoreAutomaticTimeJumpsUntil = DispatchTime(
                            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                        )
                        completionViewModel.play()
                    }
                }
            } catch {
                print("Error loading video properties: \(error.localizedDescription)")
                #if os(iOS)
                if isManagedImportedVideo(url),
                   let idx = self.recentVideos.firstIndex(of: url) {
                    self.deleteRecentVideoIOS(at: IndexSet(integer: idx))
                }
                #endif
            }
        }
    }
    
}
