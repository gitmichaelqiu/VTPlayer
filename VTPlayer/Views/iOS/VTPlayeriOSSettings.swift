import SwiftUI
import AVKit
import AVFoundation


private struct AnimatedIOSSettingValue: View {
    let text: String
    @State private var displayedText: String

    init(text: String) {
        self.text = text
        _displayedText = State(initialValue: text)
    }

    var body: some View {
        Text(displayedText)
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: true, vertical: false)
            .contentTransition(.numericText())
            .onChange(of: text) { _, newText in
                withAnimation(.snappy(duration: 0.18)) {
                    displayedText = newText
                }
            }
    }
}

private struct IOSSliderSettingRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    let valueText: (Double) -> String
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button {
                    resetTask?.cancel()
                    let start = value
                    let end = defaultValue
                    resetTask = Task { @MainActor in
                        let steps = 40
                        let startTime = DispatchTime.now().uptimeNanoseconds
                        let duration: UInt64 = 150_000_000
                        for step in 1...steps {
                            guard !Task.isCancelled else { return }
                            let targetTime = startTime + duration * UInt64(step) / UInt64(steps)
                            let currentTime = DispatchTime.now().uptimeNanoseconds
                            if targetTime > currentTime {
                                try? await Task.sleep(nanoseconds: targetTime - currentTime)
                            }
                            guard !Task.isCancelled else { return }
                            let linearProgress = Double(step) / Double(steps)
                            let progress = 1 - (1 - linearProgress) * (1 - linearProgress) * (1 - linearProgress)
                            value = start + (end - start) * progress
                        }
                        resetTask = nil
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(abs(value - defaultValue) < 0.001)
                .accessibilityLabel("Reset to default")
            }

            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                AnimatedIOSSettingValue(text: valueText(value))
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}
#if os(iOS)
private struct IOSMoreApp: Identifiable {
    let id: String
    let name: String
    let description: LocalizedStringKey
    let url: URL
    let iconName: String
}

private struct IOSMoreAppsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    private let primaryTextColor = Color(uiColor: .label)
    private let secondaryTextColor = Color(uiColor: .secondaryLabel)
    private let tertiaryTextColor = Color(uiColor: .tertiaryLabel)

    private let apps = [
        IOSMoreApp(id: "desktoprenamer", name: "DesktopRenamer", description: "Rename and organize your desktop spaces.", url: URL(string: "https://desktoprenamer.mqiu.dev")!, iconName: "DesktopRenamerIcon_Default"),
        IOSMoreApp(id: "optclicker", name: "OptClicker", description: "Right-click with the Option key.", url: URL(string: "https://optclicker.mqiu.dev")!, iconName: "OptClickerIcon_Default"),
        IOSMoreApp(id: "spaceswitcher", name: "SpaceSwitcher", description: "Control apps and docks across spaces.", url: URL(string: "https://spaceswitcher.mqiu.dev")!, iconName: "SpaceSwitcherIcon_Default")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("More apps for Apple platforms")
                        .font(.subheadline)
                        .foregroundStyle(secondaryTextColor)

                    ForEach(apps) { app in
                        Button {
                            openURL(app.url)
                        } label: {
                            HStack(spacing: 14) {
                                appIcon(for: app)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name)
                                        .font(.headline)
                                        .foregroundStyle(primaryTextColor)
                                    Text(app.description)
                                        .font(.subheadline)
                                        .foregroundStyle(secondaryTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(tertiaryTextColor)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(primaryTextColor)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .scrollIndicators(.hidden)
            .navigationTitle("More apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func appIcon(for app: IOSMoreApp) -> some View {
        let iconName = colorScheme == .dark
            ? app.iconName.replacingOccurrences(of: "_Default", with: "_Dark")
            : app.iconName
        if let image = UIImage(named: iconName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
}

private struct IOSAcknowledgementSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = Bundle.main.url(forResource: "Acknowledgement", withExtension: "pdf") {
                    IOSPDFView(url: url)
                } else {
                    ContentUnavailableView("Acknowledgement Unavailable", systemImage: "doc.badge.ellipsis")
                }
            }
            .navigationTitle("Acknowledgements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct IOSPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGroupedBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
#endif

import VideoToolbox
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif
#if os(iOS)
import PDFKit
#endif
#if canImport(PhotosUI)
import PhotosUI
import UniformTypeIdentifiers
#endif

// MARK: - Extracted SwiftUI Components
