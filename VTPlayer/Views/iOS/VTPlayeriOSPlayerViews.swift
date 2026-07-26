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
                Section("Video metadata") {
                    LabeledContent("Resolution", value: "\(viewModel.videoWidth)×\(viewModel.videoHeight)")
                    LabeledContent("Source rate") {
                        Text(String(format: "%.2f fps", viewModel.sourceFrameRate))
                            .monospacedDigit()
                    }
                    let scale = viewModel.frameInterpolationLevel > 0 ? Double(viewModel.frameInterpolationLevel) : 1.0
                    LabeledContent("Target rate") {
                        Text(String(format: "%.2f fps", viewModel.sourceFrameRate * scale))
                            .monospacedDigit()
                    }
                    LabeledContent("Codec", value: viewModel.videoFormat)
                }

                Section("Super resolution") {
                    LabeledContent("SR supported", value: viewModel.srIsSupported ? "Yes" : "No")
                    let isQL = viewModel.qualitySuperResolutionScaleFactor > 0
                    let activeScale = max(viewModel.superResolutionLevel, viewModel.qualitySuperResolutionScaleFactor)
                    LabeledContent("Active mode", value: activeScale > 0 ? "\(isQL ? "Quality" : "Low Latency") \(activeScale)x" : "Off")
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
        .presentationDetents([.medium])
    }

    func formatDateOpened(for url: URL) -> String {
        let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDates") as? [String: Double] ?? [:]
        guard let timeInterval = dates[url.lastPathComponent] else {
            return "Opened recently"
        }
        let date = Date(timeIntervalSince1970: timeInterval)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Opened " + formatter.string(from: date)
    }
    #endif

}
