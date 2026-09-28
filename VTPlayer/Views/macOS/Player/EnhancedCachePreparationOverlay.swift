import SwiftUI

#if os(macOS)
extension VTPlayerView {
    @ViewBuilder
    var enhancedCachePreparationIndicator: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(preparationTitle)
                        .font(.caption.weight(.semibold))
                }
                Text(preparationStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case let .preparing(progress, bytesWritten) = viewModel.enhancedCachePreparationState {
                    ProgressView(value: progress)
                        .frame(maxWidth: 220)
                    Text("\(Int((progress * 100).rounded()))% · \(ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button("Cancel", role: .cancel) {
                if viewModel.enhancedCachePreparationState == .prerolling {
                    viewModel.cancelEnhancedPlaybackPreroll()
                } else {
                    viewModel.cancelEnhancedCachePreparation()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Cancel this setup step. The original video is unchanged.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 430, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enhanced playback setup in progress")
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var preparationTitle: String {
        switch viewModel.enhancedCachePreparationState {
        case .benchmarking:
            return "Checking processing speed"
        case .prerolling:
            return viewModel.isPlaying && !viewModel.isPaused
                ? "Starting enhanced playback"
                : "Preparing enhanced playback"
        case .monitoring:
            return "Checking playback smoothness"
        case .preparing:
            return "Preparing enhanced playback"
        case .idle, .ready, .failed:
            return "Getting playback ready"
        }
    }

    private var preparationStatus: String {
        switch viewModel.enhancedCachePreparationState {
        case .benchmarking:
            return viewModel.isPlaying && !viewModel.isPaused
                ? "Checking processing speed · video continues"
                : "Checking processing speed · press Play to watch the original"
        case .preparing:
            return viewModel.isPlaying && !viewModel.isPaused
                ? "Preparing enhanced frames · video continues"
                : "Preparing enhanced frames · press Play to watch the original"
        case .prerolling:
            if viewModel.isPlaying && !viewModel.isPaused {
                return viewModel.preparedEnhancedFrameCacheMode == nil
                    ? "Starting the enhanced video pipeline"
                    : "Loading prepared enhanced frames"
            }
            return viewModel.preparedEnhancedFrameCacheMode == nil
                ? "Preparing the first enhanced frames · video stays paused"
                : "Loading cached frames · video stays paused"
        case .monitoring:
            return "Enhanced video is playing · checking smoothness"
        case .idle, .ready, .failed:
            return ""
        }
    }

    @ViewBuilder
    var livePresentationMonitoringIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Playback is running")
                    .font(.caption.weight(.semibold))
                Text("Verifying enhanced frames reach the display")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}
#endif
