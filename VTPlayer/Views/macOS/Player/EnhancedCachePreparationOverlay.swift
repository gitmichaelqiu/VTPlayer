import SwiftUI

#if os(macOS)
extension VTPlayerView {
    var enhancedCachePreparationIndicator: some View {
        EnhancedCachePreparationIndicator(viewModel: viewModel)
    }
}

private struct EnhancedCachePreparationIndicator: View {
    let viewModel: VTPlayerViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(preparationTitle)
                        .font(.caption.weight(.semibold))
                }
                Text(preparationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case let .preparing(progress, bytesWritten, estimatedTotalBytes, estimatedRemainingSeconds) = viewModel.enhancedCachePreparationState {
                    ProgressView(value: progress)
                        .frame(maxWidth: .infinity)
                    let writtenSize = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
                    let estimatedSize = ByteCountFormatter.string(fromByteCount: estimatedTotalBytes, countStyle: .file)
                    Text("\(Int((progress * 100).rounded()))% · \(writtenSize) of ~\(estimatedSize)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(preparationProgressAccessibilityLabel(
                            progress: progress,
                            writtenSize: writtenSize,
                            estimatedSize: estimatedSize,
                            estimatedRemainingSeconds: estimatedRemainingSeconds
                        ))
                    if let estimatedRemainingSeconds {
                        Text("About \(remainingTimeLabel(estimatedRemainingSeconds)) remaining")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                if viewModel.enhancedCachePreparationState == .prerolling {
                    viewModel.cancelEnhancedPlaybackPreroll()
                } else {
                    viewModel.cancelEnhancedCachePreparation()
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Cancel this setup step. The original video is unchanged.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                ? "Video continues while checking"
                : "Press Play to watch the original"
        case .preparing:
            return viewModel.isPlaying && !viewModel.isPaused
                ? "Video continues while preparing"
                : "Press Play to watch the original"
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

    private func remainingTimeLabel(_ seconds: Double) -> String {
        let totalSeconds = max(1, Int(seconds.rounded(.up)))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            let remainingSeconds = totalSeconds % 60
            return remainingSeconds == 0 ? "\(totalMinutes)m" : "\(totalMinutes)m \(remainingSeconds)s"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    private func preparationProgressAccessibilityLabel(
        progress: Double,
        writtenSize: String,
        estimatedSize: String,
        estimatedRemainingSeconds: Double?
    ) -> String {
        let percent = Int((progress * 100).rounded())
        let size = "\(percent) percent complete, \(writtenSize) written of an estimated \(estimatedSize)"
        guard let estimatedRemainingSeconds else { return size }
        return "\(size), about \(remainingTimeLabel(estimatedRemainingSeconds)) remaining"
    }

}
#endif
