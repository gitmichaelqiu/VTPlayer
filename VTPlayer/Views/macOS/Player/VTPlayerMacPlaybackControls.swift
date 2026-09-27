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
            return "Resume native playback while enhancement preparation continues"
        }
        if viewModel.hasUnappliedPipelineChanges {
            return "Play using the applied settings. Prepare pending changes first to use them."
        }
        return viewModel.isPipelineActive
            ? "Start enhanced playback using the applied settings. VTPlayer may preroll frames or switch to a cache if live playback misses the display target."
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
            return viewModel.isPipelineActive ? "Applied · press Play for enhanced playback" : "Ready · paused"
        case .playingNative:
            return "Playing · Native"
        case .benchmarking:
            return isPlaying ? "Measuring · native playback continues" : "Measuring · playback paused"
        case .prerollingEnhanced:
            return "Starting enhanced playback…"
        case .monitoringEnhanced:
            return "Playing · Enhanced · checking smoothness"
        case .preparingCache:
            return isPlaying ? "Preparing cache · native playback continues" : "Preparing cache · playback paused"
        case .playingEnhanced:
            return "Playing · Enhanced"
        case .paused:
            if viewModel.isPipelineActive {
                return viewModel.isPlaying ? "Paused · Enhanced" : "Applied · press Play for enhanced playback"
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
        if viewModel.isPreparingEnhancedCache {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preparationProgressTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(preparationProgressDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") {
                    if viewModel.enhancedCachePreparationState == .prerolling {
                        viewModel.cancelEnhancedPlaybackPreroll()
                    } else {
                        viewModel.cancelEnhancedCachePreparation()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 6)
        } else if viewModel.hasUnappliedPipelineChanges {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Changes pending", systemImage: "circle.dotted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Applied settings: \(viewModel.appliedEnhancementSummary)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button(pendingChangesAreRendererOnly ? "Apply Adjustments" : "Prepare Enhanced Playback") {
                    viewModel.applyPipelineEnhancements()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(pendingChangesAreRendererOnly
                    ? "Apply the image adjustments now. They do not rerun the processing benchmark or rebuild the frame cache."
                    : "Commit these processing settings and measure processing speed once. VTPlayer builds a cache only if needed. Play then starts enhanced output and checks display smoothness.")

                Button("Discard Changes") {
                    viewModel.dismissPendingEnhancementChanges()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Discard the pending settings and keep the active settings")
            }
            .padding(.horizontal, 6)
        }
    }

    private var pendingChangesAreRendererOnly: Bool {
        viewModel.draftPipelineConfiguration == viewModel.appliedPipelineConfiguration &&
            !viewModel.forceFullCachePreparation
    }

    private var preparationProgressTitle: String {
        switch viewModel.enhancedCachePreparationState {
        case .benchmarking:
            "Measuring processing speed"
        case .prerolling:
            "Starting enhanced playback"
        case .preparing:
            "Preparing enhanced cache"
        case .idle, .monitoring, .ready, .failed:
            "Preparing enhancement"
        }
    }

    private var preparationProgressDescription: String {
        switch viewModel.enhancedCachePreparationState {
        case .benchmarking:
            viewModel.isPlaying && !viewModel.isPaused
                ? "Native playback continues during measurement"
                : "Playback is paused during measurement"
        case .prerolling:
            "Waiting for the first enhanced frame"
        case .preparing:
            viewModel.isPlaying && !viewModel.isPaused
                ? "Native playback continues while cache is prepared"
                : "Playback is paused while cache is prepared"
        case .idle, .monitoring, .ready, .failed:
            "Preparing enhanced playback"
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
