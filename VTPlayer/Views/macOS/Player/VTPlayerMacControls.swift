import SwiftUI
import AVKit
import AVFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif
#if os(macOS)
import AppKit
#endif
#if canImport(PhotosUI)
import PhotosUI
import UniformTypeIdentifiers
#endif


extension VTPlayerView {
    #if os(macOS)
    func adjustVolume(by amount: Double) {
        guard viewModel.videoURL != nil else { return }
        withAnimation(.snappy(duration: 0.18)) {
            viewModel.volume = min(1, max(0, viewModel.volume + amount))
        }
        showVolumePopoverBriefly()
    }

    func showVolumePopoverBriefly() {
        if !viewModel.showControls {
            volumePopoverRevealedControls = true
        }
        showVolumePopover = true
        volumePopoverDismissTask?.cancel()
        volumePopoverDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            let shouldHideControls = volumePopoverRevealedControls
            volumePopoverRevealedControls = false
            showVolumePopover = false
            if shouldHideControls {
                // Let the popover finish its dismissal transition before
                // hiding the bar; otherwise its presentation update can
                // immediately reveal the controls again.
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, !showVolumePopover else { return }
                viewModel.inactivityTask?.cancel()
                viewModel.showControls = false
            }
        }
    }
    #endif

    @ViewBuilder
    var controlBar: some View {
        VStack(spacing: 10) {
            // Video Scrubbing Timeline Progress Bar
            HStack(spacing: 8) {
                Text(formatTime(isScrubbing ? scrubTime : viewModel.currentTime))
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)

                Slider(value: $scrubTime, in: 0...viewModel.duration, onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        viewModel.beginScrub()
                    } else {
                        viewModel.finishScrub(to: scrubTime)
                    }
                })
                .labelsHidden()
                .onChange(of: viewModel.currentTime) { _, newValue in
                    if !isScrubbing {
                        scrubTime = newValue
                    }
                }
                .onChange(of: scrubTime) { _, newValue in
                    if isScrubbing {
                        viewModel.scrub(to: newValue)
                    }
}
                Text(formatTime(viewModel.duration))
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)

            // Keep transport controls visible and group enhancement choices
            // behind one compact control.
            HStack(spacing: 10) {
                playPauseButton
                playbackStatusLabel
                Spacer(minLength: 10)
                volumeControl
                playbackSpeedControl
                Divider()
                    .frame(height: 16)
                fullscreenButton
            }
            .frame(height: 30)

            HStack(spacing: 8) {
                enhancementsControl
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            .disabled(viewModel.isPreparingEnhancedCache)
        }
        .macOnHover { viewModel.isHoveringControlBar = $0 }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .opacity(viewModel.showControls ? 1.0 : 0.0)
        .offset(y: viewModel.showControls ? 0 : 50)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showControls)
        .onChange(of: showEnhancementsPopover) { _, _ in syncConfigurationPopoverVisibility() }
        .onChange(of: showPlaybackSpeedPopover) { _, _ in syncConfigurationPopoverVisibility() }
        .onChange(of: showVolumePopover) { _, _ in syncConfigurationPopoverVisibility() }
    }

    private var enhancementsControl: some View {
        Button {
            showEnhancementsPopover.toggle()
        } label: {
            enhancementControlLabel(
                "Enhancements",
                isActive: viewModel.isPipelineActive,
                systemImage: "slider.horizontal.3"
            )
        }
        .buttonStyle(.plain)
        .help("Choose enhancement settings. Apply them, then press Play separately.")
        .popover(isPresented: $showEnhancementsPopover, arrowEdge: .top) {
            enhancementsPopoverContent
        }
    }

    private var enhancementsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enhancements")
                            .font(.headline)
                        Text(viewModel.hasUnappliedPipelineChanges
                            ? "Apply these settings, then press Play separately."
                            : "Settings are applied. Press Play when you are ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker("Upscale", selection: Binding(
                        get: {
                            viewModel.qualitySuperResolutionScaleFactor > 0
                                ? Float(10 + viewModel.qualitySuperResolutionScaleFactor)
                                : viewModel.superResolutionLevel
                        },
                        set: { selection in
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
                    .accessibilityLabel("Upscale")

                    Picker("Smooth motion", selection: Binding(
                        get: { viewModel.frameInterpolationLevel },
                        set: { viewModel.frameInterpolationLevel = $0; viewModel.updateEnhancements() }
                    )) {
                        Text("Off").tag(0)
                        if viewModel.frameInterpolationIsAvailable {
                            Text("2x").tag(2)
                            Text("4x").tag(4)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Smooth motion")

                    DisclosureGroup("Fine tuning", isExpanded: $showAdvancedEnhancements) {
                        VStack(alignment: .leading, spacing: 10) {
                            enhancementSlider(
                                "Motion blur",
                                value: Binding(
                                    get: { Double(viewModel.motionBlurStrength) },
                                    set: { viewModel.motionBlurStrength = Int($0.rounded()) }
                                ),
                                range: 0...100,
                                step: 5,
                                valueLabel: { $0 > 0 ? String(format: "%.0f", $0) : String(localized: "Off") }
                            )
                            enhancementSlider(
                                "Noise reduction",
                                value: Binding(
                                    get: { viewModel.denoiseStrength },
                                    set: { viewModel.denoiseStrength = $0 }
                                ),
                                range: 0...1,
                                step: 0.05,
                                valueLabel: { $0 > 0 ? String(format: "%.2f", $0) : String(localized: "Off") }
                            )
                            Divider()
                            enhancementSlider(
                                "Sharpness",
                                value: Binding(
                                    get: { viewModel.sharpness },
                                    set: { viewModel.sharpness = $0 }
                                ),
                                range: 0...2,
                                step: 0.05,
                                valueLabel: { $0 > 0 ? String(format: "%.2f", $0) : String(localized: "Off") }
                            )
                            enhancementSlider(
                                "HDR boost",
                                value: Binding(
                                    get: { viewModel.hdrStrength },
                                    set: { viewModel.hdrStrength = $0 }
                                ),
                                range: 0...2,
                                step: 0.05,
                                valueLabel: { $0 > 0 ? String(format: "%.2f", $0) : String(localized: "Off") }
                            )
                            enhancementSlider(
                                "HDR colorfulness",
                                value: Binding(
                                    get: { viewModel.hdrColorfulness },
                                    set: { viewModel.hdrColorfulness = $0 }
                                ),
                                range: 0...1,
                                step: 0.05,
                                valueLabel: { String(format: "%.2f", $0) },
                                isDisabled: viewModel.hdrStrength <= 0
                            )
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: viewModel.hasUnappliedPipelineChanges ? 365 : 405)

            if viewModel.hasUnappliedPipelineChanges {
                Divider()
                HStack {
                    Button("Revert") {
                        viewModel.dismissPendingEnhancementChanges()
                        showEnhancementsPopover = false
                    }
                    .buttonStyle(.bordered)
                    .help("Restore the enhancement settings currently in use")

                    Spacer()

                    Button("Apply") {
                        viewModel.applyPipelineEnhancements()
                        showEnhancementsPopover = false
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Apply these settings. Press Play separately when you are ready to start.")
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .frame(maxHeight: 460)
    }

    private func enhancementSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: (Double) -> String,
        isDisabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer(minLength: 8)
                Text(valueLabel(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step, onEditingChanged: { editing in
                if !editing {
                    viewModel.updateEnhancements()
                }
            })
        }
        .disabled(isDisabled)
    }

    private func syncConfigurationPopoverVisibility() {
        let isPresented = showEnhancementsPopover || showPlaybackSpeedPopover || showVolumePopover
        viewModel.isConfigurationPopoverPresented = isPresented
        if isPresented {
            viewModel.showControls = true
            viewModel.inactivityTask?.cancel()
        } else {
            viewModel.userActivityDetected()
        }
    }

}
