import SwiftUI

struct PlaybackSettingsView: View {
    @Bindable var viewModel: VTPlayerViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Continue video playback", selection: Binding(
                        get: { viewModel.continueVideoPlaybackPreference },
                        set: { viewModel.setContinueVideoPlaybackPreference($0) }
                    )) {
                        Text("Default").tag(ContinueVideoPlaybackPreference.default)
                        Text("On").tag(ContinueVideoPlaybackPreference.on)
                        Text("Off").tag(ContinueVideoPlaybackPreference.off)
                    }
                    .tint(.secondary)
                }

                Section("Neural Engine Enhancements") {
                    Picker("Super Resolution", selection: Binding(
                        get: {
                            if viewModel.qualitySuperResolutionScaleFactor > 0 {
                                return Float(10 + viewModel.qualitySuperResolutionScaleFactor)
                            }
                            return viewModel.superResolutionLevel
                        },
                        set: { selection in
                            let isSupported: Bool
                            switch selection {
                            case 1.5, 2, 4:
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
                            case 1.5, 2, 4:
                                viewModel.superResolutionLevel = selection
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
                        Text("Off").tag(Float(0))
                        ForEach(viewModel.availableSuperResolutionScales.sorted(), id: \.self) { scale in
                            let label = scale.rounded() == scale ? String(Int(scale)) : String(format: "%.1f", scale)
                            Text(String(format: String(localized: "Low Latency %@"), "\(label)x")).tag(scale)
                        }
                        if viewModel.availableQualitySuperResolutionScales.contains(2) {
                            Text(String(format: String(localized: "Quality %@"), "2x")).tag(Float(12))
                        }
                        if viewModel.availableQualitySuperResolutionScales.contains(4) {
                            Text(String(format: String(localized: "Quality %@"), "4x")).tag(Float(14))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                    Picker("Frame Interpolation", selection: $viewModel.frameInterpolationLevel) {
                        Text("Off").tag(0)
                        if viewModel.frameInterpolationIsAvailable {
                            Text("2x").tag(2)
                            Text("4x").tag(4)
                        }
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
                            in: 0...100,
                            step: 5,
                            onEditingChanged: { editing in
                                if !editing {
                                    viewModel.updateEnhancements()
                                }
                            }
                        )
                        .frame(width: 150)
                        Text(viewModel.motionBlurStrength == 0 ? String(localized: "Off") : "\(viewModel.motionBlurStrength)")
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
                        Text(viewModel.denoiseStrength > 0 ? String(format: "%.2f", viewModel.denoiseStrength) : String(localized: "Off"))
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
                        Slider(value: $viewModel.sharpness, in: 0...2, step: 0.05)
                            .frame(width: 150)
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
                        Slider(value: $viewModel.hdrStrength, in: 0...2, step: 0.05)
                            .frame(width: 150)
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
