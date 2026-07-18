import SwiftUI

struct PlaybackSettingsView: View {
    @Bindable var viewModel: VTPlayerViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Neural Engine Enhancements") {
                    Picker("Super Resolution", selection: Binding(
                        get: {
                            if viewModel.qualitySuperResolutionScaleFactor > 0 {
                                return 10 + viewModel.qualitySuperResolutionScaleFactor
                            }
                            return viewModel.superResolutionLevel
                        },
                        set: { selection in
                            let isSupported: Bool
                            switch selection {
                            case 2, 4:
                                isSupported = viewModel.availableSuperResolutionScales.contains(selection)
                            case 12:
                                isSupported = viewModel.availableQualitySuperResolutionScales.contains(2)
                            case 14:
                                isSupported = viewModel.availableQualitySuperResolutionScales.contains(4)
                            default:
                                isSupported = true
                            }
                            guard isSupported else { return }
                            switch selection {
                            case 2:
                                viewModel.superResolutionLevel = 2
                                viewModel.qualitySuperResolutionScaleFactor = 0
                            case 4:
                                viewModel.superResolutionLevel = 4
                                viewModel.qualitySuperResolutionScaleFactor = 0
                            case 12:
                                viewModel.superResolutionLevel = 0
                                viewModel.qualitySuperResolutionScaleFactor = 2
                            case 14:
                                viewModel.superResolutionLevel = 0
                                viewModel.qualitySuperResolutionScaleFactor = 4
                            default:
                                viewModel.superResolutionLevel = 0
                                viewModel.qualitySuperResolutionScaleFactor = 0
                            }
                            viewModel.updateEnhancements()
                        }
                    )) {
                        Text("Off").tag(0)
                        if viewModel.availableSuperResolutionScales.contains(2) {
                            Text("Low Latency 2x").tag(2)
                        }
                        if viewModel.availableSuperResolutionScales.contains(4) {
                            Text("Low Latency 4x").tag(4)
                        }
                        if viewModel.availableQualitySuperResolutionScales.contains(2) {
                            Text("Quality 2x").tag(12)
                        }
                        if viewModel.availableQualitySuperResolutionScales.contains(4) {
                            Text("Quality 4x").tag(14)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                    Picker("Frame Interpolation", selection: $viewModel.frameInterpolationLevel) {
                        Text("Off").tag(0)
                        Text("2x").tag(2)
                        Text("4x").tag(4)
                    }
                    .onChange(of: viewModel.frameInterpolationLevel) { _, _ in
                        viewModel.updateEnhancements()
                    }
                    .tint(.secondary)

                    Picker("Motion Blur", selection: $viewModel.motionBlurStrength) {
                        Text("Off").tag(0)
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("20").tag(20)
                        Text("30").tag(30)
                    }
                    .onChange(of: viewModel.motionBlurStrength) { _, _ in
                        viewModel.updateEnhancements()
                    }

                    Picker("Denoise Strength", selection: $viewModel.denoiseStrength) {
                        Text("Off").tag(0.0)
                        Text("0.25").tag(0.25)
                        Text("0.50").tag(0.5)
                        Text("0.75").tag(0.75)
                        Text("1.00").tag(1.0)
                    }
                    .onChange(of: viewModel.denoiseStrength) { _, _ in
                        viewModel.updateEnhancements()
                    }
                }

                Section("Filters & Adjustments") {
                    HStack {
                        Text("Sharpness")
                        Spacer()
                        Slider(value: $viewModel.sharpness, in: 0...2, step: 0.25)
                            .frame(width: 150)
                        Text(String(format: "%.2f", viewModel.sharpness))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }

                    HStack {
                        Text("SDR-to-HDR Boost")
                        Spacer()
                        Slider(value: $viewModel.hdrStrength, in: 0...2, step: 0.25)
                            .frame(width: 150)
                        Text(String(format: "%.2f", viewModel.hdrStrength))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }

                    HStack {
                        Text("HDR Colorfulness")
                        Spacer()
                        Slider(value: $viewModel.hdrColorfulness, in: 0...1, step: 0.05)
                            .frame(width: 150)
                            .disabled(viewModel.hdrStrength <= 0)
                        Text(String(format: "%.2f", viewModel.hdrColorfulness))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
            .navigationTitle("Playback Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
