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
        .accessibilityLabel(playPauseButtonLabel)
        .help(playPauseButtonHelp)
    }

    private var playPauseButtonLabel: String {
        if viewModel.isPlaying && !viewModel.isPaused {
            return "Pause video"
        }
        return "Play video"
    }

    private var playPauseButtonHelp: String {
        if viewModel.isPlaying && !viewModel.isPaused {
            return "Pause playback"
        }
        if viewModel.isPreparingEnhancedCache {
            return "Enhanced playback is preparing. You can keep watching while it finishes."
        }
        return viewModel.isPipelineActive
            ? "Start enhanced playback"
            : "Play video with native presentation"
    }

    @ViewBuilder
    var playbackFallbackNotice: some View {
        if let message = viewModel.playbackNotice {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Try Enhanced Again") {
                    viewModel.retryEnhancedPlayback()
                }
                .controlSize(.small)
                .help("Retry enhanced playback")
                Button {
                    viewModel.dismissPlaybackNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Dismiss message")
                .accessibilityLabel("Dismiss message")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 760)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
            .transition(.move(edge: .top).combined(with: .opacity))
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
                Slider(value: Binding(
                    get: { viewModel.volume },
                    set: { newValue in
                        viewModel.volume = newValue
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
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            // Use the adaptive primary color so active controls remain
            // distinguishable on the light appearance without changing the
            // existing dark-appearance contrast.
            .background(
                Color.primary.opacity(isActive ? 0.12 : 0.04)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(title)
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
