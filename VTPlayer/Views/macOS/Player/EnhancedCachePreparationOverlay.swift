import SwiftUI

#if os(macOS)
extension VTPlayerView {
    @ViewBuilder
    var enhancedCachePreparationOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                Text(preparationTitle)
                    .font(.headline)

                switch viewModel.enhancedCachePreparationState {
                case .benchmarking:
                    Text("Checking whether these settings can play smoothly. If not, VTPlayer will prepare a cache.")
                        .foregroundStyle(.secondary)
                case .prerolling:
                    Text(viewModel.preparedEnhancedFrameCacheMode == nil
                        ? "Preparing the first enhanced frames. Playback starts automatically when enough are ready."
                        : "Loading prepared enhanced frames. Playback starts automatically when the queue is ready.")
                        .foregroundStyle(.secondary)
                case .monitoring:
                    Text("Playback is running; smoothness is being checked in the background.")
                        .foregroundStyle(.secondary)
                case let .preparing(progress, bytesWritten):
                    ProgressView(value: progress)
                        .frame(width: 260)
                    Text("\(Int((progress * 100).rounded()))% · \(ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file))")
                        .foregroundStyle(.secondary)
                case .idle, .ready, .failed:
                    EmptyView()
                }

                if viewModel.nativeFallbackActive &&
                    (!viewModel.isPlaying || viewModel.isPaused) {
                    Button("Continue Native Playback") {
                        viewModel.play()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(cancelButtonTitle, role: .cancel) {
                    if viewModel.enhancedCachePreparationState == .prerolling {
                        viewModel.cancelEnhancedPlaybackPreroll()
                    } else {
                        viewModel.cancelEnhancedCachePreparation()
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(28)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enhancement preparation in progress")
    }

    private var preparationTitle: String {
        switch viewModel.enhancedCachePreparationState {
        case .benchmarking:
            return "Measuring selected enhancements"
        case .prerolling:
            return "Loading frames for playback"
        case .monitoring:
            return "Checking playback smoothness"
        case .preparing:
            return "Building enhanced frame cache"
        case .idle, .ready, .failed:
            return "Preparing enhancements"
        }
    }

    private var cancelButtonTitle: String {
        viewModel.enhancedCachePreparationState == .prerolling
            ? "Cancel Playback Start"
            : "Cancel Preparation"
    }

    @ViewBuilder
    var enhancedCachePreparationIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(preparationTitle)
                    .font(.caption.weight(.semibold))
                Text(preparationStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if case let .preparing(progress, _) = viewModel.enhancedCachePreparationState {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") {
                viewModel.cancelEnhancedCachePreparation()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enhancement preparation; native playback continues")
    }

    private var preparationStatus: String {
        switch viewModel.enhancedCachePreparationState {
        case .benchmarking:
            return "Checking processing speed · native playback continues"
        case .preparing:
            return "Writing bounded enhanced cache · native playback continues"
        case .prerolling:
            return "Loading prepared frames"
        case .monitoring:
            return "Checking presentation smoothness"
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
                Text("Checking smoothness in the background")
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
