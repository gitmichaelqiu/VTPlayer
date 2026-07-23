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

                    HStack {
                        Text("Motion Blur")
                        Spacer()
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.motionBlurStrength) },
                                set: { viewModel.motionBlurStrength = Int($0) }
                            ),
                            in: 0...30,
                            step: 1,
                            onEditingChanged: { editing in
                                if !editing {
                                    viewModel.updateEnhancements()
                                }
                            }
                        )
                        .frame(width: 150)
                        .transaction { $0.animation = .snappy(duration: 0.18) }
                        Text(viewModel.motionBlurStrength == 0 ? "Off" : "\(viewModel.motionBlurStrength)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.18), value: viewModel.motionBlurStrength)
                    }

                    HStack {
                        Text("Denoise")
                        Spacer()
                        Slider(
                            value: $viewModel.denoiseStrength,
                            in: 0...1,
                            step: 0.05,
                            onEditingChanged: { editing in
                                if !editing {
                                    viewModel.updateEnhancements()
                                }
                            }
                        )
                        .frame(width: 150)
                        .transaction { $0.animation = .snappy(duration: 0.18) }
                        Text(viewModel.denoiseStrength > 0 ? String(format: "%.2f", viewModel.denoiseStrength) : "Off")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.18), value: viewModel.denoiseStrength)
                    }
                }

                Section("Filters & Adjustments") {
                    HStack {
                        Text("Sharpness")
                        Spacer()
                        Slider(value: $viewModel.sharpness, in: 0...2, step: 0.25)
                            .frame(width: 150)
                            .transaction { $0.animation = .snappy(duration: 0.18) }
                        Text(String(format: "%.2f", viewModel.sharpness))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.18), value: viewModel.sharpness)
                    }

                    HStack {
                        Text("HDR Boost")
                        Spacer()
                        Slider(value: $viewModel.hdrStrength, in: 0...2, step: 0.25)
                            .frame(width: 150)
                            .transaction { $0.animation = .snappy(duration: 0.18) }
                        Text(String(format: "%.2f", viewModel.hdrStrength))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.18), value: viewModel.hdrStrength)
                    }

                    HStack {
                        Text("HDR Colorfulness")
                        Spacer()
                        Slider(value: $viewModel.hdrColorfulness, in: 0...1, step: 0.05)
                            .frame(width: 150)
                            .transaction { $0.animation = .snappy(duration: 0.18) }
                            .disabled(viewModel.hdrStrength <= 0)
                        Text(String(format: "%.2f", viewModel.hdrColorfulness))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.18), value: viewModel.hdrColorfulness)
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
