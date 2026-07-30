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
                    if !editing {
                        viewModel.seek(to: scrubTime)
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
            
            // Bottom control actions
            // Keep every enhancement control available at narrow widths.
            // The bar scrolls horizontally instead of silently removing the
            // controls that are useful while tuning playback.
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                // Play/Pause button
                playPauseButton
                
                Divider()
                    .frame(height: 16)
                
                // Super Resolution Popover
                Button {
                    showSuperResolutionPopover.toggle()
                } label: {
                    let isQL = viewModel.qualitySuperResolutionScaleFactor > 0
                    let scale = max(viewModel.superResolutionLevel, Float(viewModel.qualitySuperResolutionScaleFactor))
                    let scaleLabel = scale.rounded() == scale ? String(Int(scale)) : String(format: "%.1f", scale)
                    let isActive = scale > 0
                    enhancementControlLabel(
                        isQL
                            ? "\(String(localized: "Super Resolution")): \(scaleLabel)x QL"
                            : "\(String(localized: "Super Resolution")): \(isActive ? "\(scaleLabel)x" : String(localized: "Off"))",
                        isActive: isActive
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Super Resolution — increases spatial resolution using neural upscaling")
                .popover(isPresented: $showSuperResolutionPopover, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Super Resolution")
                            .font(.headline)
                        Picker("", selection: Binding(
                            get: {
                                viewModel.qualitySuperResolutionScaleFactor > 0
                                    ? Float(10 + viewModel.qualitySuperResolutionScaleFactor)
                                    : viewModel.superResolutionLevel
                            },
                            set: { selection in
                                switch selection {
                                case 1.5, 2, 4: viewModel.superResolutionLevel = selection; viewModel.qualitySuperResolutionScaleFactor = 0
                                case 12: viewModel.superResolutionLevel = 0; viewModel.qualitySuperResolutionScaleFactor = 2
                                case 14: viewModel.superResolutionLevel = 0; viewModel.qualitySuperResolutionScaleFactor = 4
                                default: viewModel.superResolutionLevel = 0; viewModel.qualitySuperResolutionScaleFactor = 0
                                }
                                viewModel.updateEnhancements()
                            }
                        )) {
                            Text("Off").tag(Float(0))
                            ForEach(viewModel.availableSuperResolutionScales.sorted(), id: \.self) { scale in
                                Text(String(format: "Low Latency %.1fx", scale)).tag(scale)
                            }
                            if viewModel.availableQualitySuperResolutionScales.contains(2) { Text("Quality 2x").tag(Float(12)) }
                            if viewModel.availableQualitySuperResolutionScales.contains(4) { Text("Quality 4x").tag(Float(14)) }
                        }
                        .pickerStyle(.inline)
                    }
                    .padding(12)

                // Frame Interpolation Popover
                }
                Button {
                    showFrameInterpolationPopover.toggle()
                } label: {
                    let isActive = viewModel.frameInterpolationLevel > 0
                    enhancementControlLabel(
                        "\(String(localized: "Frame Interpolation")): \(isActive ? "\(viewModel.frameInterpolationLevel)x" : String(localized: "Off"))",
                        isActive: isActive
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Frame Interpolation — increases video frame rate for fluid movement")
                .popover(isPresented: $showFrameInterpolationPopover, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Frame Interpolation")
                            .font(.headline)
                        Picker("", selection: Binding(
                            get: { viewModel.frameInterpolationLevel },
                            set: { viewModel.frameInterpolationLevel = $0; viewModel.updateEnhancements() }
                        )) {
                            Text("Off").tag(0)
                            Text("2x").tag(2)
                            Text("4x").tag(4)
                        }
                        .pickerStyle(.inline)
                    }
                    .padding(12)
                }
                
                // Motion Blur Popover
                Button {
                    showMotionBlurPopover.toggle()
                } label: {
                    let isActive = viewModel.motionBlurStrength > 0
                    enhancementControlLabel(
                        "\(String(localized: "Motion Blur")): \(isActive ? "\(viewModel.motionBlurStrength)" : String(localized: "Off"))",
                        isActive: isActive
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Motion Blur — simulates natural motion blur on upscaled/interpolated frames")
                .popover(isPresented: $showMotionBlurPopover, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Motion Blur: \(viewModel.motionBlurStrength > 0 ? "\(viewModel.motionBlurStrength)" : String(localized: "Off"))")
                            .font(.headline)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.18), value: viewModel.motionBlurStrength)
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.motionBlurStrength) },
                                set: { newValue in
                                    withAnimation(.snappy(duration: 0.18)) { viewModel.motionBlurStrength = Int(newValue) }
                                }
                            ),
                            in: 0...100,
                            step: 1,
                            onEditingChanged: { editing in
                                if !editing {
                                    viewModel.updateEnhancements()
                                }
                            }
                        )
                    }
                    .padding(16)
                    .frame(width: 220)
                }
                
                // Denoise Popover
                Button {
                    showDenoisePopover.toggle()
                } label: {
                    let isActive = viewModel.denoiseStrength > 0
                    enhancementControlLabel(
                        "\(String(localized: "Denoise")): \(isActive ? String(format: "%.2f", viewModel.denoiseStrength) : String(localized: "Off"))",
                        isActive: isActive
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Denoise — filters compression noise and high-frequency grain")
                .popover(isPresented: $showDenoisePopover, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Denoise: \(viewModel.denoiseStrength > 0 ? String(format: "%.2f", viewModel.denoiseStrength) : String(localized: "Off"))")
                            .font(.headline)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.18), value: viewModel.denoiseStrength)
                        Slider(
                            value: Binding(
                                get: { viewModel.denoiseStrength },
                                set: { newValue in
                                    withAnimation(.snappy(duration: 0.18)) { viewModel.denoiseStrength = newValue }
                                }
                            ),
                            in: 0...1,
                            step: 0.05,
                            onEditingChanged: { editing in
                                if !editing {
                                    viewModel.updateEnhancements()
                                }
                            }
                        )
                    }
                    .padding(16)
                    .frame(width: 220)
                }

                // Image Adjustments Popover Button
                Button(action: { viewModel.showAdjustmentsPopover.toggle() }) {
                    enhancementControlLabel(
                        "Adjustments",
                        isActive: viewModel.sharpness > 0 || viewModel.hdrStrength > 0
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .popover(isPresented: Binding(
                    get: { viewModel.showAdjustmentsPopover },
                    set: { viewModel.showAdjustmentsPopover = $0 }
                ), arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Image Adjustments")
                            .font(.headline)
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sharpness: \(viewModel.sharpness > 0 ? String(format: "%.2f", viewModel.sharpness) : String(localized: "Off"))")
                                .font(.caption)
                                .contentTransition(.numericText())
                                .animation(.snappy(duration: 0.18), value: viewModel.sharpness)
                            Slider(value: Binding(
                                get: { viewModel.sharpness },
                                set: { newValue in withAnimation(.snappy(duration: 0.18)) { viewModel.sharpness = newValue } }
                            ), in: 0...2, step: 0.25)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("HDR Boost: \(viewModel.hdrStrength > 0 ? String(format: "%.2f", viewModel.hdrStrength) : String(localized: "Off"))")
                                .font(.caption)
                                .contentTransition(.numericText())
                                .animation(.snappy(duration: 0.18), value: viewModel.hdrStrength)
                            Slider(value: Binding(
                                get: { viewModel.hdrStrength },
                                set: { newValue in withAnimation(.snappy(duration: 0.18)) { viewModel.hdrStrength = newValue } }
                            ), in: 0...2, step: 0.25)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("HDR Colorfulness: \(String(format: "%.2f", viewModel.hdrColorfulness))")
                                .font(.caption)
                                .contentTransition(.numericText())
                                .animation(.snappy(duration: 0.18), value: viewModel.hdrColorfulness)
                            Slider(value: Binding(
                                get: { viewModel.hdrColorfulness },
                                set: { newValue in withAnimation(.snappy(duration: 0.18)) { viewModel.hdrColorfulness = newValue } }
                            ), in: 0...1, step: 0.05)
                                .disabled(viewModel.hdrStrength <= 0)
                        }
                    }
                    .padding(16)
                    .frame(width: 220)
                }
                
                Spacer()
                
                volumeControl

                playbackSpeedControl
                
                Divider()
                    .frame(height: 16)
                
                        fullscreenButton
                    }
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                }
            }
            .frame(height: 30)
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
        .onChange(of: showSuperResolutionPopover) { _, _ in syncConfigurationPopoverVisibility() }
        .onChange(of: showFrameInterpolationPopover) { _, _ in syncConfigurationPopoverVisibility() }
        .onChange(of: showMotionBlurPopover) { _, _ in syncConfigurationPopoverVisibility() }
        .onChange(of: showDenoisePopover) { _, _ in syncConfigurationPopoverVisibility() }
        .onChange(of: showPlaybackSpeedPopover) { _, _ in syncConfigurationPopoverVisibility() }
        .onChange(of: showVolumePopover) { _, _ in syncConfigurationPopoverVisibility() }
        .onChange(of: viewModel.showAdjustmentsPopover) { _, _ in syncConfigurationPopoverVisibility() }
    }

    private func syncConfigurationPopoverVisibility() {
        let isPresented = showSuperResolutionPopover || showFrameInterpolationPopover ||
            showMotionBlurPopover || showDenoisePopover || showPlaybackSpeedPopover ||
            showVolumePopover || viewModel.showAdjustmentsPopover
        viewModel.isConfigurationPopoverPresented = isPresented
        if isPresented {
            viewModel.showControls = true
            viewModel.inactivityTask?.cancel()
        } else {
            viewModel.userActivityDetected()
        }
    }
    
    @ViewBuilder
    var playPauseButton: some View {
        Button(action: { viewModel.togglePlayPause() }) {
            Image(systemName: (viewModel.isPlaying && !viewModel.isPaused) ? "pause.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.glass)
        .keyboardShortcut(.space, modifiers: [])
    }
    
    @ViewBuilder
    var playbackSpeedControl: some View {
        Button(action: { showPlaybackSpeedPopover.toggle() }) {
            compactPlaybackControlLabel(
                systemImage: "speedometer",
                value: viewModel.playbackSpeed == 1
                    ? nil
                    : String(format: "%.2fx", viewModel.playbackSpeed),
                isActive: viewModel.playbackSpeed != 1
            )
        }
        .buttonStyle(.plain)
        .help("Adjust playback speed (0.5x - 2x)")
        .popover(isPresented: $showPlaybackSpeedPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Speed: \(String(format: "%.2fx", viewModel.playbackSpeed))")
                    .font(.headline)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: viewModel.playbackSpeed)
                Slider(value: Binding(
                    get: { viewModel.playbackSpeed },
                    set: { newValue in withAnimation(.snappy(duration: 0.18)) { viewModel.playbackSpeed = newValue } }
                ), in: 0.5...2.0, step: 0.25)

                Divider()

                Picker("Continue video playback", selection: Binding(
                    get: { viewModel.continueVideoPlaybackPreference },
                    set: { viewModel.setContinueVideoPlaybackPreference($0) }
                )) {
                    Text("Default").tag(ContinueVideoPlaybackPreference.default)
                    Text("On").tag(ContinueVideoPlaybackPreference.on)
                    Text("Off").tag(ContinueVideoPlaybackPreference.off)
                }
            }
            .padding(16)
            .frame(width: 220)
        }
    }

    @ViewBuilder
    var volumeControl: some View {
        Button(action: { showVolumePopover.toggle() }) {
            compactPlaybackControlLabel(
                systemImage: volumeSymbolName,
                value: viewModel.volume == 1
                    ? nil
                    : "\(Int((viewModel.volume * 100).rounded()))%",
                isActive: viewModel.volume != 1
            )
        }
        .buttonStyle(.plain)
        .help("Adjust volume (0% - 100%)")
        .popover(isPresented: $showVolumePopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Volume: \(Int((viewModel.volume * 100).rounded()))%")
                    .font(.headline)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: viewModel.volume)
                Slider(value: Binding(
                    get: { viewModel.volume },
                    set: { newValue in
                        withAnimation(.snappy(duration: 0.18)) { viewModel.volume = newValue }
                    }
                ), in: 0...1, step: 0.05)
            }
            .padding(16)
            .frame(width: 220)
        }
    }

    @ViewBuilder
    private func compactPlaybackControlLabel(
        systemImage: String,
        value: String?,
        isActive: Bool
    ) -> some View {
        HStack(spacing: value == nil ? 0 : 5) {
            Image(systemName: systemImage)
            if let value {
                Text(value)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isActive ? .primary : .secondary)
        .padding(.vertical, 5)
        .padding(.horizontal, value == nil ? 7 : 9)
        .background(isActive ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var volumeSymbolName: String {
        switch viewModel.volume {
        case 0: return "speaker.slash.fill"
        case 0..<0.5: return "speaker.wave.1.fill"
        case 0..<0.8: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    @ViewBuilder
    func enhancementControlLabel(_ title: String, isActive: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(isActive ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    @ViewBuilder
    var fullscreenButton: some View {
        #if os(macOS)
        Button(action: {
            if let window = NSApp.mainWindow ?? NSApp.keyWindow {
                window.toggleFullScreen(nil)
            }
        }) {
            Image(systemName: viewModel.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.glass)
        .keyboardShortcut("f", modifiers: [])
        .help(viewModel.isFullScreen ? "Exit Fullscreen (F)" : "Enter Fullscreen (F)")
        #else
        EmptyView()
        #endif
    }

}
