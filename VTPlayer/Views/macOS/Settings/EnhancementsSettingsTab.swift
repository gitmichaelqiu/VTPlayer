#if os(macOS)
import SwiftUI
import Combine
import AppKit

struct EnhancementsSettingsTab: View {
    @AppStorage("VTDefaultMBLevel") private var defaultMBLevel = 0
    @AppStorage("VTDefaultDNLevel") private var defaultDNLevel = 0.0
    @AppStorage("VTDefaultSharpness") private var defaultSharpness = 0.0
    @AppStorage("VTDefaultHDRBoost") private var defaultHDRBoost = 0.0
    @AppStorage("VTDefaultHDRColorfulness") private var defaultHDRColorfulness = 0.0
    @AppStorage("VTEnhancedFrameCacheMemoryMB") private var enhancedFrameCacheMemoryMB = 1_024
    @AppStorage("VTEnhancedFrameCacheDiskGB") private var enhancedFrameCacheDiskGB = 20
    @State private var diskCacheUsageBytes: Int64 = 0
    @State private var isClearingDiskCache = false
    @State private var showClearDiskCacheConfirmation = false
    @State private var diskCacheError: String?
    private let diskCache = EnhancedFrameDiskCache.shared

    var body: some View {
        SettingsContainer(.enhancements) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection("Neural Engine Enhancements") {
                    SliderSettingsRow(
                        "Enhanced frame cache",
                        helperText: "Maximum memory for enhanced-frame prebuffering.",
                        value: Binding(
                            get: { Double(min(max(enhancedFrameCacheMemoryMB, 256), 4_096)) },
                            set: { enhancedFrameCacheMemoryMB = Int($0.rounded()) }
                        ),
                        range: 256.0...4_096.0,
                        defaultValue: 1_024.0,
                        step: 256.0,
                        valueString: {
                            $0 >= 1_024
                                ? String(format: "%.1f GB", $0 / 1_024.0)
                                : String(format: "%.0f MB", $0)
                        }
                    )

                    Divider()

                    SliderSettingsRow(
                        "Enhanced frame disk cache",
                        helperText: "Maximum persistent storage for lossless enhanced frames.",
                        value: Binding(
                            get: { Double(min(max(enhancedFrameCacheDiskGB, 2), 200)) },
                            set: { enhancedFrameCacheDiskGB = Int($0.rounded()) }
                        ),
                        range: 2.0...200.0,
                        defaultValue: 20.0,
                        step: 1.0,
                        valueString: { String(format: "%.0f GB", $0) }
                    )

                    HStack {
                        Label("Current disk usage", systemImage: "internaldrive")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: diskCacheUsageBytes, countStyle: .file))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Clear Disk Cache", role: .destructive) {
                            showClearDiskCacheConfirmation = true
                        }
                        .disabled(isClearingDiskCache || diskCacheUsageBytes == 0)

                        if isClearingDiskCache {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if let diskCacheError {
                        Text(diskCacheError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                SettingsSection("Postprocessing") {
                    SliderSettingsRow(
                        "Motion Blur",
                        helperText: "Apply motion blur.",
                        value: Binding(
                            get: { Double(defaultMBLevel) },
                            set: { defaultMBLevel = Int($0) }
                        ),
                        range: 0.0...100.0,
                        defaultValue: 0.0,
                        step: 5.0,
                        valueString: { $0 > 0 ? String(format: "%.0f", $0) : String(localized: "Off") }
                    )

                    Divider()

                    SliderSettingsRow(
                        "Denoise",
                        helperText: "Reduce video noise.",
                        value: $defaultDNLevel,
                        range: 0.0...1.0,
                        defaultValue: 0.0,
                        step: 0.05,
                        valueString: { $0 > 0 ? String(format: "%.2f", $0) : String(localized: "Off") }
                    )
                }

                SettingsSection("Color & Image Adjustments") {
                    VStack(spacing: 0) {
                        SliderSettingsRow(
                            "Sharpness",
                            value: $defaultSharpness,
                            range: 0.0...2.0,
                            defaultValue: 0.0,
                            step: 0.05
                        )

                        Divider()

                        SliderSettingsRow(
                            "HDR Boost",
                            helperText: "Expand luminance for HDR displays.",
                            value: $defaultHDRBoost,
                            range: 0.0...2.0,
                            defaultValue: 0.0,
                            step: 0.05
                        )

                        if defaultHDRBoost > 0 {
                            Divider()
                                .transition(.opacity)

                            SliderSettingsRow(
                                "HDR Colorfulness",
                                helperText: "Adjust HDR color intensity.",
                                value: $defaultHDRColorfulness,
                                range: 0.0...1.0,
                                defaultValue: 0.0,
                                step: 0.05
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: defaultHDRBoost)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            await refreshDiskCacheUsage()
        }
        .confirmationDialog("Clear Enhanced Frame Disk Cache?", isPresented: $showClearDiskCacheConfirmation) {
            Button("Clear Disk Cache", role: .destructive) {
                clearDiskCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached enhanced frames will be removed. Frames currently being played or prepared are retained until they are no longer in use.")
        }
    }

    @MainActor
    private func refreshDiskCacheUsage() async {
        diskCacheUsageBytes = (try? await diskCache.diskUsageBytes()) ?? 0
    }

    private func clearDiskCache() {
        isClearingDiskCache = true
        diskCacheError = nil
        Task { @MainActor in
            do {
                diskCacheUsageBytes = try await diskCache.clearUnpinnedCaches()
            } catch {
                diskCacheError = error.localizedDescription
            }
            isClearingDiskCache = false
        }
    }
}

#endif
