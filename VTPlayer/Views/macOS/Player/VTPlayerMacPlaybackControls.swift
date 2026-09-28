import SwiftUI
import AVKit
import AVFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif
#if os(macOS)
import AppKit
#endif
#if canImport(PhotosUI)
import PhotosUI
import UniformTypeIdentifiers
#endif


extension VTPlayerView {
    #if os(macOS)
    @ViewBuilder
    var playPauseButton: some View {
        Button(action: { viewModel.togglePlayPause() }) {
            Image(systemName: (viewModel.isPlaying && !viewModel.isPaused) ? "pause.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.glass)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(viewModel.playbackPhase == .loading || viewModel.enhancedCachePreparationState == .prerolling)
        .help(playPauseButtonHelp)
    }

    private var playPauseButtonHelp: String {
        if viewModel.isPlaying && !viewModel.isPaused {
            return "Pause playback"
        }
        if viewModel.isPreparingEnhancedCache && viewModel.enhancedCachePreparationState != .prerolling {
            return "Watch the original video during setup; VTPlayer switches to enhanced playback when ready"
        }
        if viewModel.hasUnappliedPipelineChanges {
            return "Play using the settings currently in use. Apply the selected settings first to use them."
        }
        return viewModel.isPipelineActive
            ? "Start enhanced playback. VTPlayer verifies on-screen playback and prepares a cache automatically only if live presentation misses the target."
            : "Play video with native presentation"
    }

    @ViewBuilder
    var playbackStatusLabel: some View {
        let status = playbackStatusText
        Text(status)
            .font(.caption.weight(.medium))
            .foregroundStyle(viewModel.hasUnappliedPipelineChanges ? .orange : .secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Playback status: \(status)")
            .help(status)
    }

    private var playbackStatusText: String {
        let isPlaying = viewModel.isPlaying && !viewModel.isPaused
        if viewModel.hasUnappliedPipelineChanges {
            let currentPlayback: String
            if isPlaying {
                currentPlayback = viewModel.isPipelineActive ? "Playing · Enhanced" : "Playing · Native"
            } else if viewModel.isPlaying {
                currentPlayback = viewModel.isPipelineActive ? "Paused · Enhanced" : "Paused · Native"
            } else {
                currentPlayback = viewModel.isPipelineActive ? "Enhanced selected" : "Ready · paused"
            }
            return "\(currentPlayback) · edits pending"
        }

        switch viewModel.playbackPhase {
        case .empty:
            return "No video"
        case .loading:
            return "Loading video…"
        case .readyPaused:
            return viewModel.isPipelineActive ? "Enhanced playback ready · press Play" : "Ready · paused"
        case .playingNative:
            return "Playing · Native"
        case .benchmarking:
            return isPlaying ? "Checking settings · video continues" : "Checking settings · press Play to watch"
        case .prerollingEnhanced:
            return "Starting enhanced playback…"
        case .monitoringEnhanced:
            return "Enhanced · verifying display"
        case .preparingCache:
            return isPlaying ? "Preparing playback · video continues" : "Preparing playback · press Play to watch"
        case .playingEnhanced:
            return "Playing · Enhanced"
        case .paused:
            if viewModel.isPipelineActive {
                return viewModel.isPlaying ? "Paused · Enhanced" : "Enhanced playback ready · press Play"
            }
            return viewModel.isPlaying ? "Paused · Native" : "Ready · paused"
        case .ended:
            return "Ended · press Play to replay"
        case .failed:
            return "Playback issue · see details"
        }
    }

    @ViewBuilder
    var pendingEnhancementControls: some View {
        if !viewModel.isPreparingEnhancedCache && viewModel.hasUnappliedPipelineChanges {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Settings not applied", systemImage: "circle.dotted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("In use: \(viewModel.appliedEnhancementSummary)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button("Apply & Prepare") {
                    viewModel.applyPipelineEnhancements()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Apply these settings and prepare enhanced playback. The video stays paused; press Play when it is ready.")

                Button("Revert") {
                    viewModel.dismissPendingEnhancementChanges()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Restore the settings currently in use for this video")
            }
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    var playbackSpeedControl: some View {
        Button(action: { showPlaybackSpeedPopover.toggle() }) {
            compactPlaybackControlLabel(
                systemImage: "speedometer",
                value: viewModel.playbackSpeed == 1
                    ? nil
                    : String(format: "%.2fx", viewModel.playbackSpeed),
                isActive: viewModel.playbackSpeed != 1
            )
        }
        .buttonStyle(.plain)
        .help("Adjust playback speed (0.5x - 2x)")
        .popover(isPresented: $showPlaybackSpeedPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Speed: \(String(format: "%.2fx", viewModel.playbackSpeed))")
                    .font(.headline)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: viewModel.playbackSpeed)
                Slider(value: Binding(
                    get: { viewModel.playbackSpeed },
                    set: { newValue in withAnimation(.snappy(duration: 0.18)) { viewModel.playbackSpeed = newValue } }
                ), in: 0.5...2.0, step: 0.25)

            }
            .padding(16)
            .frame(width: 220)
        }
    }

    @ViewBuilder
    var volumeControl: some View {
        Button(action: { showVolumePopover.toggle() }) {
            compactPlaybackControlLabel(
                systemImage: volumeSymbolName,
                value: viewModel.volume == 1
                    ? nil
                    : "\(Int((viewModel.volume * 100).rounded()))%",
                isActive: viewModel.volume != 1
            )
        }
        .buttonStyle(.plain)
        .help("Adjust volume (0–100 percent)")
        .popover(isPresented: $showVolumePopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Volume: %@", defaultValue: "Volume: \(viewModel.volume.formatted(.percent.precision(.fractionLength(0))))", comment: "Current volume"))
                    .font(.headline)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: viewModel.volume)
                Slider(value: Binding(
                    get: { viewModel.volume },
                    set: { newValue in
                        withAnimation(.snappy(duration: 0.18)) { viewModel.volume = newValue }
                    }
                ), in: 0...1, step: 0.05)
            }
            .padding(16)
            .frame(width: 220)
        }
    }

    @ViewBuilder
    private func compactPlaybackControlLabel(
        systemImage: String,
        value: String?,
        isActive: Bool
    ) -> some View {
        HStack(spacing: value == nil ? 0 : 5) {
            Image(systemName: systemImage)
            if let value {
                Text(value)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isActive ? .primary : .secondary)
        .padding(.vertical, 5)
        .padding(.horizontal, value == nil ? 7 : 9)
        .background(isActive ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var volumeSymbolName: String {
        switch viewModel.volume {
        case 0: return "speaker.slash.fill"
        case 0..<0.5: return "speaker.wave.1.fill"
        case 0..<0.8: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    @ViewBuilder
    func enhancementControlLabel(_ title: String, isActive: Bool) -> some View {
        let isPending = viewModel.hasUnappliedPipelineChanges
        HStack(spacing: 4) {
            Text(title)
            if isPending {
                Image(systemName: "circle.dotted")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isPending ? .orange : (isActive ? .primary : .secondary))
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            // Use the adaptive primary color so active controls remain
            // distinguishable on the light appearance without changing the
            // existing dark-appearance contrast.
            .background(
                isPending
                    ? Color.orange.opacity(0.12)
                    : Color.primary.opacity(isActive ? 0.12 : 0.04)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isPending ? Color.orange.opacity(0.45) : Color.clear,
                        lineWidth: 1
                    )
            )
            .accessibilityLabel(
                isPending ? "\(title), selected but not active" : title
            )
    }

    @ViewBuilder
    var fullscreenButton: some View {
        #if os(macOS)
        Button(action: {
            if let window = NSApp.mainWindow ?? NSApp.keyWindow {
                window.toggleFullScreen(nil)
            }
        }) {
            Image(systemName: viewModel.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.glass)
        .keyboardShortcut("f", modifiers: [])
        .help(viewModel.isFullScreen ? "Exit Fullscreen (F)" : "Enter Fullscreen (F)")
        #else
        EmptyView()
        #endif
    }

#endif
}
