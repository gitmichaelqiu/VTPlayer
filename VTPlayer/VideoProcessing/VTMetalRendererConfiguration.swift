//
//  VTMetalRenderer.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import Foundation
import MetalKit
import CoreVideo
import CoreImage
import QuartzCore

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// A high-performance Metal-backed view for rendering CVPixelBuffer frames.
@MainActor
public final class VTMetalRenderer: MTKView {

@MainActor
extension VTMetalRenderer {
    private func setupMetal() {
        guard let device = self.device else { return }

        self.framebufferOnly = false
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        #if os(macOS)
        // Drive drawing from MTKView's display scheduler while playback is
        // active. AppKit setNeedsDisplay is coalesced and can collapse FI
        // frames when two updates arrive between run-loop redraws.
        self.enableSetNeedsDisplay = false
        self.isPaused = true
        self.preferredFramesPerSecond = 60
        #else
        self.enableSetNeedsDisplay = true
        self.isPaused = true // We manually trigger drawing when a new frame is received
        #endif
        #if os(iOS)
        self.contentMode = .redraw
        #endif

        self.commandQueue = device.makeCommandQueue()
        if let queue = commandQueue {
            self.ciContext = CIContext(mtlCommandQueue: queue, options: [
                .cacheIntermediates: false,
                .useSoftwareRenderer: false
            ])
        }
        configureExtendedDynamicRangePresentation()
    }

    /// Configures the CAMetalLayer for genuine extended dynamic range output.
    /// An EDR layer must use a floating-point pixel format and an extended
    /// linear color space; merely raising CI exposure in an SDR drawable is
    /// clipped before it reaches an XDR display.
    private func configureExtendedDynamicRangePresentation() {
        guard let metalLayer = layer as? CAMetalLayer else { return }

        let previousPixelFormat = colorPixelFormat
        let previousEDRState = isExtendedDynamicRangeActive

        // Use potential headroom to opt in. On iOS, `currentEDRHeadroom` can
        // remain at 1.0 until an EDR layer is already visible.
        let nativeHDRColorSpace = nativeHDRColorSpace
        let hasHDRIntent = nativeHDRColorSpace != nil || hdrStrength > 0
        #if os(iOS)
        // iOS may not report EDR headroom until its layer already requests it.
        // Once attached, opt in based on intent so restored settings do not
        // wait for a rotation to create the first EDR drawable.
        let shouldUseEDR = hasHDRIntent && window != nil
        #else
        let shouldUseEDR = hasHDRIntent && potentialEDRHeadroom > 1.0
        #endif
        if shouldUseEDR {
            if let nativeHDRColorSpace {
                // PQ and HLG frames must be presented in the transfer
                // function carried by the decoded video. The linear Display
                // P3 drawable is reserved for the SDR-to-HDR effect.
                colorPixelFormat = .bgr10a2Unorm
                metalLayer.pixelFormat = .bgr10a2Unorm
                metalLayer.colorspace = nativeHDRColorSpace
            } else {
                colorPixelFormat = .rgba16Float
                metalLayer.pixelFormat = .rgba16Float
                metalLayer.colorspace = extendedLinearDisplayP3ColorSpace
            }
            metalLayer.wantsExtendedDynamicRangeContent = true
            #if os(iOS)
            if #available(iOS 26.0, *) {
                // `wantsExtendedDynamicRangeContent` no longer changes the
                // default standard preference on iOS 26. Mark this focused
                // media layer as high range before its first drawable exists.
                metalLayer.preferredDynamicRange = .high
                metalLayer.contentsHeadroom = max(
                    2.0,
                    min(4.0, pow(2.0, CGFloat(max(hdrStrength, 0))))
                )
            }
            #endif
        } else {
            // Preserve the renderer's untagged SDR drawable configuration.
            // The Core Image presentation color space is selected at render
            // time, while the drawable remains in its native BGRA format.
            colorPixelFormat = .bgra8Unorm
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.colorspace = nil
            metalLayer.wantsExtendedDynamicRangeContent = false
            #if os(iOS)
            if #available(iOS 26.0, *) {
                metalLayer.preferredDynamicRange = .standard
                metalLayer.contentsHeadroom = 0
            }
            #endif
        }
        isExtendedDynamicRangeActive = shouldUseEDR
        if previousPixelFormat != colorPixelFormat || previousEDRState != shouldUseEDR {
            releaseDrawables()
        }
        #if os(iOS)
        if shouldUseEDR {
            edrRefreshAttempts = 0
        } else if hdrStrength > 0, window != nil, edrRefreshAttempts < 8 {
            edrRefreshAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.window != nil, self.hdrStrength > 0 else { return }
                self.configureExtendedDynamicRangePresentation()
                self.setNeedsDisplay(self.bounds)
            }
        }
        #endif
    }

    private func updateNativeHDRPresentation(for pixelBuffer: CVPixelBuffer) {
        let transfer: NativeHDRTransfer?
        if let attachment = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            nil
        ), CFEqual(attachment, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) {
            transfer = .pq
        } else if let attachment = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            nil
        ), CFEqual(attachment, kCVImageBufferTransferFunction_ITU_R_2100_HLG) {
            transfer = .hlg
        } else {
            transfer = nil
        }

        guard transfer != nativeHDRTransfer else { return }
        nativeHDRTransfer = transfer
        configureExtendedDynamicRangePresentation()
    }

    /// The usable headroom can change with the selected display, brightness,
    /// power state, and system HDR settings, so it is queried at presentation.
    private var currentEDRHeadroom: Float {
        #if os(macOS)
        guard let screen = window?.screen else { return 1.0 }
        return Float(screen.maximumExtendedDynamicRangeColorComponentValue)
        #elseif os(iOS)
        guard let screen = window?.windowScene?.screen else { return 1.0 }
        return Float(screen.currentEDRHeadroom)
        #else
        return 1.0
        #endif
    }

    private var potentialEDRHeadroom: Float {
        #if os(macOS)
        guard let screen = window?.screen else { return 1.0 }
        return Float(screen.maximumExtendedDynamicRangeColorComponentValue)
        #elseif os(iOS)
        guard let screen = window?.windowScene?.screen else { return 1.0 }
        return Float(screen.potentialEDRHeadroom)
        #else
        return 1.0
        #endif
    }

    private func requestRedrawForImageAdjustment() {
        needsDrawableUpdate = true
        #if os(macOS)
        if isPaused {
            draw()
        }
        #else
        setNeedsDisplay(bounds)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setNeedsDisplay(self.bounds)
            self.draw()
        }
        #endif
    }

    #if os(macOS)
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSizeForBackingScale()
        configureExtendedDynamicRangePresentation()
        if window != nil, renderingActive {
            isPaused = false
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSizeForBackingScale()
        configureExtendedDynamicRangePresentation()
    }

    public override func layout() {
        super.layout()
        let sizeChanged = bounds.size != lastLayoutSize
        if sizeChanged {
            lastLayoutSize = bounds.size
            updateDrawableSizeForBackingScale()
            needsDrawableUpdate = true
            if isPaused {
                requestPausedLayoutRedraw()
            }
        }
    }

    /// SwiftUI supplies an NSView's bounds in points. Keep the Metal drawable
    /// in backing pixels so enabling the processing pipeline does not render
    /// at half resolution on a Retina display.
    @discardableResult
    private func updateDrawableSizeForBackingScale() -> Bool {
        guard let window else { return false }
        let scale = window.backingScaleFactor
        layer?.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0, drawableSize != size else { return false }
        drawableSize = size
        return true
    }

    /// MTKView's display scheduler is intentionally paused with playback.
    /// A sidebar resize can otherwise leave its previous drawable stretched by
    /// AppKit until another video frame arrives. Schedule one coalesced draw
    /// after layout, when the resized drawable is available.
    private func requestPausedLayoutRedraw() {
        guard !pausedLayoutRedrawPending else { return }
        pausedLayoutRedrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pausedLayoutRedrawPending = false
            guard self.isPaused else { return }
            self.draw()
        }
    }
}
