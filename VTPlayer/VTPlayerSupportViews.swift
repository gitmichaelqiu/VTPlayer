import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if canImport(PhotosUI)
import PhotosUI
import UniformTypeIdentifiers
#endif

struct QLModelStatusView: View {
    let modelManager: VTModelManager

    var body: some View {
        let modelStatus = modelManager.status
        LabeledContent("QL Model", value: modelStatusLabel(modelStatus))
            .foregroundStyle(modelStatusColor(modelStatus))
        if case .downloading(let progress) = modelStatus {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 200)
        }
    }

    private func modelStatusLabel(_ status: VTModelManager.Status) -> String {
        switch status {
        case .notChecked: return "Not Checked"
        case .ready: return "Ready"
        case .downloadRequired: return "Download Required"
        case .downloading(let progress): return String(format: "Downloading (%.0f%%)", progress * 100)
        case .failed(let error): return "Failed: \(error)"
        }
    }

    private func modelStatusColor(_ status: VTModelManager.Status) -> Color {
        switch status {
        case .ready: return .green
        case .downloading: return .orange
        case .downloadRequired, .notChecked: return .secondary
        case .failed: return .red
        }
    }
}

/// Helper view for blur/visual effect backgrounds.
#if os(macOS)
struct VisualEffectView: NSViewRepresentable {
    let material: PlatformVisualEffectMaterial
    let blendingMode: PlatformVisualEffectBlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
#else
struct VisualEffectView: UIViewRepresentable {
    let material: PlatformVisualEffectMaterial
    let blendingMode: PlatformVisualEffectBlendingMode

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}
#endif

extension View {
    @ViewBuilder
    func macOnHover(perform action: @escaping (Bool) -> Void) -> some View {
        #if os(macOS)
        self.onHover(perform: action)
        #else
        self
        #endif
    }

    @ViewBuilder
    func macWindowToolbarFullScreenVisibility() -> some View {
        #if os(macOS)
        self.windowToolbarFullScreenVisibility(.onHover)
        #else
        self
        #endif
    }

    @ViewBuilder
    func macNavigationBarTitleDisplayMode() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#if canImport(PhotosUI)
struct PhotosMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { receivedData in
            let fileURL = receivedData.file
            let isAccessing = fileURL.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(fileURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: copy.path) {
                try? FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: fileURL, to: copy)
            return .init(url: copy)
        }
    }
}
#endif
