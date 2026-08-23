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

                Text("Preparing Enhancements")
                    .font(.headline)

                switch viewModel.enhancedCachePreparationState {
                case .benchmarking:
                    Text("Measuring the selected pipeline before playback.")
                        .foregroundStyle(.secondary)
                case let .preparing(progress, bytesWritten):
                    ProgressView(value: progress)
                        .frame(width: 260)
                    Text("\(Int((progress * 100).rounded()))% · \(ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file))")
                        .foregroundStyle(.secondary)
                case .idle, .ready, .failed:
                    EmptyView()
                }

                Button("Cancel", role: .cancel) {
                    viewModel.cancelEnhancedCachePreparation()
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
}
#endif
