#if os(macOS)
import SwiftUI
import Combine
import AppKit


struct GeneralSettingsTab: View {
    @AppStorage("VTShowFileExtensions") private var showFileExtensions = true
    @AppStorage("VTAlwaysDarkOnPlayback") private var alwaysDarkOnPlayback = false
    @AppStorage("VTDefaultContinueVideoPlayback") private var defaultContinueVideoPlayback = true
    @State private var automaticallyChecksForUpdates = false
    @State private var automaticallyDownloadsUpdates = false

    var body: some View {
        SettingsContainer(.general) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection("User Interface") {
                    SettingsRow(
                        "Show file extensions",
                        helperText: "Show or hide file extensions."
                    ) {
                        Toggle("", isOn: $showFileExtensions)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsRow(
                        "Continue video playback",
                        helperText: "Resume new videos from their saved position."
                    ) {
                        Toggle("", isOn: $defaultContinueVideoPlayback)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsRow(
                        "Always use dark mode when playing",
                        helperText: "Use dark styling during playback."
                    ) {
                        Toggle("", isOn: $alwaysDarkOnPlayback)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                SettingsSection("Updates") {
                    SettingsRow(
                        "Automatically check for updates"
                    ) {
                        Toggle("", isOn: $automaticallyChecksForUpdates)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(!VTPlayerUpdater.shared.isConfigured)
                            .onChange(of: automaticallyChecksForUpdates) { _, value in
                                VTPlayerUpdater.shared.automaticallyChecksForUpdates = value
                            }
                    }

                    if automaticallyChecksForUpdates {
                        VStack(spacing: 0) {
                            Divider()

                            SettingsRow(
                                "Automatically download updates"
                            ) {
                                Toggle("", isOn: $automaticallyDownloadsUpdates)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .disabled(!VTPlayerUpdater.shared.isConfigured)
                                    .onChange(of: automaticallyDownloadsUpdates) { _, value in
                                        VTPlayerUpdater.shared.automaticallyDownloadsUpdates = value
                                    }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Divider()

                    SettingsRow(
                        "Check for updates",
                    ) {
                        Button("Check Now") {
                            VTPlayerUpdater.shared.checkForUpdates()
                        }
                        .disabled(!VTPlayerUpdater.shared.isConfigured)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: automaticallyChecksForUpdates)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onAppear {
                automaticallyChecksForUpdates = VTPlayerUpdater.shared.automaticallyChecksForUpdates
                automaticallyDownloadsUpdates = VTPlayerUpdater.shared.automaticallyDownloadsUpdates
            }
        }
    }
}

#endif
