import SwiftUI
import AVKit
import AVFoundation

extension VTPlayerView {
    #if os(iOS)
    @ViewBuilder
    var iosPlayerView: some View {
        let displayTitle = viewModel.videoURL.map {
            showFileExtensions ? $0.lastPathComponent : $0.deletingPathExtension().lastPathComponent
        } ?? "Video"
        ZStack {
            // Enhanced Metal video renderer sits at the bottom of the ZStack
            if viewModel.isPipelineActive {
                VTMetalRendererView(renderer: viewModel.renderer)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
            }

            // Native AVPlayerViewController sits on top
            if let player = viewModel.player {
                NativeVideoPlayer(
                    player: player,
                    title: displayTitle,
                    isPipelineActive: viewModel.isPipelineActive,
                    showControls: $viewModel.showControls
                )
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ProgressView()
                    .tint(.white)
            }

        }
        .navigationTitle(viewModel.showControls ? displayTitle : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        // Keep toolbar visible so the frame never collapses — collapsing
        // causes the player overlay to jump upward abruptly.
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if viewModel.showControls && isPlayerNavigationReady {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: exitIOSPlayer) {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Exit player")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .labelStyle(.iconOnly)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showDiagnosticsSheet = true
                    } label: {
                        Label("Diagnostics", systemImage: "chart.bar")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
        .toolbar(isPlayerTabBarHidden ? .hidden : .visible, for: .tabBar)
        .background(IOSPlayerLifecycleObserver(
            isTabBarHidden: isPlayerTabBarHidden,
            onDidAppear: {
                isPlayerNavigationReady = true
            },
            onWillDisappear: {
                isPlayerNavigationReady = false
                withAnimation(.easeInOut(duration: 0.25)) {
                    isPlayerTabBarHidden = false
                }
            }
        ))
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettingsSheet) {
            PlaybackSettingsView(viewModel: viewModel)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showDiagnosticsSheet) {
            iosDiagnosticsSheet
        }
        .onDisappear {
            isPlayerNavigationReady = false
            withAnimation(.easeInOut(duration: 0.25)) {
                isPlayerTabBarHidden = false
            }
            viewModel.stop()
            viewModel.videoURL = nil
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.25)) {
                isPlayerTabBarHidden = true
            }
        }
    }

    func exitIOSPlayer() {
        viewModel.stop()
        viewModel.videoURL = nil
        isPlayerPresented = false
        isPlayerNavigationReady = false
        IOSPlayerTabBarController.setHidden(false, animated: true)
        withAnimation(.easeInOut(duration: 0.25)) {
            isPlayerTabBarHidden = false
        }
    }

    @ViewBuilder
    var iosDiagnosticsSheet: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    LabeledContent("State", value: String(localized: viewModel.isPaused || !viewModel.isPlaying ? "Paused" : "Playing"))
                    LabeledContent("Presentation", value: String(localized: viewModel.isPipelineActive ? "Enhanced" : "Native"))
                    LabeledContent("Playback speed") {
                        Text(String(format: "%.2f×", viewModel.playbackSpeed))
                            .monospacedDigit()
                    }
                    if viewModel.isPipelineActive {
                        LabeledContent("Submitted rate") {
                            Text(viewModel.fps > 0 ? String(format: "%.1f fps", viewModel.fps) : "—")
                                .monospacedDigit()
                        }
                        LabeledContent("Frame processing") {
                            Text(viewModel.frameProcessingTime > 0 ? String(format: "%.1f ms", viewModel.frameProcessingTime) : "—")
                                .monospacedDigit()
                        }
                        LabeledContent("Buffered frames") {
                            Text("\(viewModel.frameCacheCount)")
                                .monospacedDigit()
                        }
                        LabeledContent("Dropped frames") {
                            Text("\(viewModel.droppedFrames)")
                                .monospacedDigit()
                        }
                        LabeledContent("Rendered timeline") {
                            Text(viewModel.renderedTimelineSampleDuration > 0
                                 ? String(format: "%.0f%%", viewModel.renderedTimelineRatio * 100)
                                 : "—")
                                .monospacedDigit()
                        }
                    }
                }

                Section("Video metadata") {
                    LabeledContent("Resolution", value: "\(viewModel.videoWidth)×\(viewModel.videoHeight)")
                    LabeledContent("Source rate") {
                        Text(String(format: "%.2f fps", viewModel.sourceFrameRate))
                            .monospacedDigit()
                    }
                    LabeledContent("Target rate") {
                        Text(String(format: "%.2f fps", viewModel.isPipelineActive ? viewModel.requestedOutputFrameRate : viewModel.sourceFrameRate * viewModel.playbackSpeed))
                            .monospacedDigit()
                    }
                    LabeledContent("Codec", value: viewModel.videoFormat)
                }

                Section("Super resolution") {
                    LabeledContent("SR supported", value: String(localized: viewModel.srIsSupported ? "Yes" : "No"))
                    let isQL = viewModel.qualitySuperResolutionScaleFactor > 0
                    let activeScale = max(viewModel.superResolutionLevel, Float(viewModel.qualitySuperResolutionScaleFactor))
                    let scaleLabel = activeScale.rounded() == activeScale
                        ? String(Int(activeScale))
                        : String(format: "%.1f", activeScale)
                    let modeFormat = isQL
                        ? String(localized: "Quality %@")
                        : String(localized: "Low Latency %@")
                    LabeledContent(
                        "Active mode",
                        value: activeScale > 0
                            ? String(format: modeFormat, "\(scaleLabel)x")
                            : String(localized: "Off")
                    )
                    if let error = viewModel.srInitializationError {
                        LabeledContent("Error") {
                            Text(error)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showDiagnosticsSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    func formatDateOpened(for url: URL) -> String {
        let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDates") as? [String: Double] ?? [:]
        guard let timeInterval = dates[url.lastPathComponent] else {
            return String(localized: "Opened recently")
        }
        let date = Date(timeIntervalSince1970: timeInterval)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return String(format: String(localized: "Opened %@"), formatter.string(from: date))
    }
    #endif

}
