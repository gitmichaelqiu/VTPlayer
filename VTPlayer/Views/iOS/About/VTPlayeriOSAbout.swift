import SwiftUI
import AVKit
import AVFoundation

extension VTPlayerView {
    #if os(iOS)
    var iosAboutView: some View {
        List {
            // App Identity Header section (Apple left-oriented HIG style)
            Section {
                DisclosureGroup(isExpanded: $isAboutCardExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider()

                        Text("Made by Michael Qiu.")
                            .font(.subheadline.weight(.medium))

                        Text("A real-time video enhancer using hardware acceleration.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            aboutLinkRow(title: "Report an issue", systemImage: "exclamationmark.bubble", url: "https://github.com/gitmichaelqiu/VTPlayer/issues")
                            aboutLinkRow(title: "VTPlayer's GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/gitmichaelqiu/VTPlayer")
                            aboutLinkRow(title: "Author's website", systemImage: "globe", url: "https://mqiu.dev")
                            aboutLinkRow(title: "Author's GitHub", systemImage: "person.crop.circle", url: "https://github.com/gitmichaelqiu")
                            aboutActionRow(title: "Acknowledgement", systemImage: "doc.text") {
                                showAcknowledgementSheet = true
                            }

                            Button {
                                showMoreAppsSheet = true
                            } label: {
                                Text("Explore more apps")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, -20)
                    .padding(.top, -15)
                } label: {
                    HStack(alignment: .center, spacing: 16) {
                        aboutAppIcon

                        VStack(alignment: .leading, spacing: 4) {
                            Text("VTPlayer")
                                .font(.headline)
                                .bold()
                            Text("Sharper. Smoother. Better.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(appVersionLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                    .frame(minHeight: 60, alignment: .center)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }

            // Default Playback Settings Section
            Section("Defaults") {
                Toggle("Continue video playback", isOn: $defaultContinueVideoPlayback)

                IOSSliderSettingRow(
                    title: "Frame cache",
                    value: Binding(
                        get: { Double(min(max(enhancedFrameCacheMemoryMB, 128), 1_024)) },
                        set: { enhancedFrameCacheMemoryMB = Int($0.rounded()) }
                    ),
                    range: 128...1_024,
                    step: 128,
                    defaultValue: 256,
                    valueText: { $0 >= 1_024 ? "1 GB" : "\(Int($0)) MB" }
                )
            }

            Section {
                IOSSliderSettingRow(
                    title: "Motion Blur",
                    value: Binding(
                        get: { Double(defaultMBLevel) },
                        set: { defaultMBLevel = Int($0.rounded()) }
                    ),
                    range: 0...100,
                    step: 5,
                    defaultValue: 0,
                    valueText: { $0 == 0 ? String(localized: "Off") : "\(Int($0))" }
                )

                IOSSliderSettingRow(
                    title: "Denoise",
                    value: $defaultDNLevel,
                    range: 0.0...1.0,
                    step: 0.05,
                    defaultValue: 0,
                    valueText: { String(format: "%.2f", $0) }
                )

                IOSSliderSettingRow(
                    title: "Sharpness",
                    value: $defaultSharpness,
                    range: 0.0...2.0,
                    step: 0.05,
                    defaultValue: 0,
                    valueText: { String(format: "%.2f", $0) }
                )

                IOSSliderSettingRow(
                    title: "HDR Boost",
                    value: Binding(
                        get: { defaultHDRBoost },
                        set: { newValue in
                            let wasEnabled = defaultHDRBoost > 0
                            let isEnabled = newValue > 0
                            if wasEnabled != isEnabled {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    defaultHDRBoost = newValue
                                }
                            } else {
                                defaultHDRBoost = newValue
                            }
                        }
                    ),
                    range: 0.0...2.0,
                    step: 0.05,
                    defaultValue: 0,
                    valueText: { String(format: "%.2f", $0) }
                )

            if defaultHDRBoost > 0 {
                IOSSliderSettingRow(
                    title: "HDR Colorfulness",
                    value: $defaultHDRColorfulness,
                    range: 0.0...1.0,
                    step: 0.05,
                    defaultValue: 0,
                    valueText: { String(format: "%.2f", $0) }
                )
                .transition(.opacity)
            }
            }
            .animation(.easeInOut(duration: 0.2), value: defaultHDRBoost)

            // Gallery Configuration Section
            Section("Display") {
                Toggle("Always use dark mode when playing", isOn: $alwaysDarkOnPlayback)
                Toggle("Show file extensions", isOn: $showFileExtensions)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.custom(16))
        .sheet(isPresented: $showMoreAppsSheet) {
            IOSMoreAppsSheet()
        }
        .sheet(isPresented: $showAcknowledgementSheet) {
            IOSAcknowledgementSheet()
        }
        .onAppear {
            viewModel.checkGlobalModelStatus()
        }
    }

    @ViewBuilder
    private var aboutAppIcon: some View {
        let icon = colorScheme == .dark
            ? UIImage(named: "VTPlayerIcon_Dark").map(Image.init(uiImage:))
            : viewModel.appIcon
        if let icon {
            icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        } else {
            Image(systemName: "cpu.fill")
                .font(.system(size: 24))
                .foregroundStyle(.blue)
                .frame(width: 60, height: 60)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? String(localized: "Unknown")
        return String(format: String(localized: "Version %@"), version)
    }

    @ViewBuilder
    private func aboutLinkRow(title: LocalizedStringKey, systemImage: String, url: String) -> some View {
        Button {
            openExternalURL(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)

                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func aboutActionRow(title: LocalizedStringKey, systemImage: String, verticalPadding: CGFloat = 8, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)

                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.vertical, verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openExternalURL(_ string: String) {
        guard let url = URL(string: string), UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
    #endif

}
