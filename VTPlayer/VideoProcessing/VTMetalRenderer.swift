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
    
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    
    // The current pixel buffer to render
    private var currentPixelBuffer: CVPixelBuffer?
    private enum NativeHDRTransfer: Equatable {
        case pq
        case hlg
    }
    private var nativeHDRTransfer: NativeHDRTransfer?
    #if os(macOS)
    private var renderingActive = false
    private var pausedLayoutRedrawPending = false
    #endif

    /// Sharpness intensity (0 = off, >0 applies CIUnsharpMask)
    public var sharpness: Float = 0.0

    /// SDR-to-HDR mapping strength. Enabling it opts the drawable into EDR when
    /// the current display has available headroom.
    public var hdrStrength: Float = 0.0 {
        didSet {
            configureExtendedDynamicRangePresentation()
            requestRedrawForImageAdjustment()
        }
    }

    /// Optional perceptual compensation for SDR footage displayed in EDR.
    /// It is intentionally neutral by default and affects midtones only.
    public var hdrColorfulness: Float = 0.0 {
        didSet {
            requestRedrawForImageAdjustment()
        }
    }

    /// Whether the current drawable is configured to present extended-range
    /// content. This is false on displays without EDR headroom.
    public private(set) var isExtendedDynamicRangeActive = false

    private let extendedLinearDisplayP3ColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    private var nativeHDRColorSpace: CGColorSpace? {
        switch nativeHDRTransfer {
        case .pq:
            return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .hlg:
            return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case nil:
            return nil
        }
    }

    private lazy var midtoneChromaKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 midtoneChromaCompensation(__sample image, float amount) {
            float luma = dot(image.rgb, vec3(0.2126, 0.7152, 0.0722));
            float shadowWeight = smoothstep(0.08, 0.25, luma);
            float highlightWeight = 1.0 - smoothstep(0.60, 0.95, luma);
            float compensation = amount * shadowWeight * highlightWeight;
            vec3 compensated = mix(vec3(luma), image.rgb, 1.0 + compensation);
            return vec4(compensated, image.a);
        }
        """)

    #if os(macOS)
    /// Called immediately before each MTKView draw so the owner can provide
    /// the next video frame from its presentation queue.
    public var onDisplayTick: (() -> Void)?
    #endif

    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        setupMetal()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        setupMetal()
    }

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

        // Use potential headroom to opt in. On iOS, `currentEDRHeadroom` can
        // remain at 1.0 until an EDR layer is already visible.
        let nativeHDRColorSpace = nativeHDRColorSpace
        let shouldUseEDR = (nativeHDRColorSpace != nil || hdrStrength > 0) && potentialEDRHeadroom > 1.0
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
        } else {
            // Preserve the renderer's original SDR drawable configuration.
            // Forcing sRGB here changes Core Image's YUV conversion and can
            // wash out unenhanced video frames.
            colorPixelFormat = .bgra8Unorm
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.colorspace = nil
            metalLayer.wantsExtendedDynamicRangeContent = false
        }
        isExtendedDynamicRangeActive = shouldUseEDR
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
        #if os(macOS)
        if isPaused {
            draw()
        }
        #else
        draw()
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
        if updateDrawableSizeForBackingScale(), isPaused {
            requestPausedLayoutRedraw()
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
    #endif
    
    /// Updates the renderer with a new frame for presentation.
    /// - Parameters:
    ///   - pixelBuffer: The new CVPixelBuffer frame to display.
    ///   - isInterpolated: Retained for caller compatibility; rendering uses
    ///     the same user-selected sharpness for source and generated frames.
    public func render(pixelBuffer: CVPixelBuffer, isInterpolated _: Bool = false) {
        updateNativeHDRPresentation(for: pixelBuffer)
        self.currentPixelBuffer = pixelBuffer
        #if os(macOS)
        if self.isPaused {
            self.draw()
        }
        #else
        self.draw()
        #endif
    }

    #if os(macOS)
    /// Enables the MTKView display scheduler during playback. Keeping it
    /// paused while stopped avoids rendering the same frame unnecessarily.
    public func setRenderingActive(_ active: Bool) {
        self.renderingActive = active
        self.isPaused = !active
    }
    #endif

    /// Removes the currently displayed frame and redraws the view as black.
    public func clear() {
        self.currentPixelBuffer = nil
        #if os(macOS)
        self.draw()
        #else
        self.draw()
        #endif
    }
    
    public override func draw(_ rect: CGRect) {
        guard let drawable = currentDrawable,
              let queue = commandQueue else {
            return
        }

        #if os(macOS)
        // Only advance the presentation queue when this draw has a drawable;
        // resize/occlusion callbacks must not consume a frame that cannot be
        // presented to the screen.
        onDisplayTick?()
        #endif

        if currentPixelBuffer == nil {
            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].clearColor = clearColor
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        guard let pixelBuffer = currentPixelBuffer,
              let context = ciContext else {
            return
        }
        
        let drawableSize = self.drawableSize
        let destinationTexture = drawable.texture
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Apply optional sharpness filter
        let sharpenedImage: CIImage
        if sharpness > 0 {
            sharpenedImage = (ciImage.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputIntensityKey: sharpness,
                kCIInputRadiusKey: 0.5
            ]))
        } else {
            sharpenedImage = ciImage
        }

        // Map SDR into the display's available EDR headroom. SDR white remains
        // the reference white at strength zero; increasing strength raises the
        // image into extended range, capped by the screen's live headroom.
        let hdrImage: CIImage
        if isExtendedDynamicRangeActive, nativeHDRTransfer == nil {
            let normalizedStrength = min(max(hdrStrength / 2.0, 0), 1)
            let targetHeadroom = 1 + (currentEDRHeadroom - 1) * normalizedStrength
            let exposureEV = log2(targetHeadroom)
            // Exposure scales RGB uniformly, preserving the source hue and
            // chroma relationships. Do not add saturation or contrast here:
            // EDR describes luminance headroom, and SDR footage contains no
            // HDR color information for us to reconstruct safely.
            let expandedImage = sharpenedImage
                .applyingFilter("CIExposureAdjust", parameters: [
                    kCIInputEVKey: exposureEV
                ])
            if hdrColorfulness > 0, let kernel = midtoneChromaKernel {
                hdrImage = kernel.apply(
                    extent: expandedImage.extent,
                    arguments: [expandedImage, min(max(hdrColorfulness, 0), 1)]
                ) ?? expandedImage
            } else {
                hdrImage = expandedImage
            }
        } else {
            hdrImage = sharpenedImage
        }

        // Calculate aspect ratio locking transformation
        let imageSize = hdrImage.extent.size
        let scaleX = drawableSize.width / imageSize.width
        let scaleY = drawableSize.height / imageSize.height
        
        // Lock aspect ratio (fitting the image inside the view bounds)
        let scale = min(scaleX, scaleY)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        
        // Center the scaled image in the drawable
        let offsetX = (drawableSize.width - scaledWidth) / 2
        let offsetY = (drawableSize.height - scaledHeight) / 2
        
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
        
        let transformedImage = hdrImage.transformed(by: transform)
        
        // Render the image to the drawable texture
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        
        // Clear the drawable texture first (to avoid trailing graphics on aspect-ratio borders)
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = destinationTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            encoder.endEncoding()
        }
        
        // Draw the video frame using the optimized CoreImage Metal pipeline.
        let targetRect = CGRect(x: 0, y: 0, width: drawableSize.width, height: drawableSize.height)
        context.render(
            transformedImage,
            to: destinationTexture,
            commandBuffer: commandBuffer,
            bounds: targetRect,
            colorSpace: isExtendedDynamicRangeActive
                ? (nativeHDRColorSpace ?? extendedLinearDisplayP3ColorSpace)
                : CGColorSpaceCreateDeviceRGB()
        )
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    #if os(iOS)
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // The renderer is constructed before SwiftUI attaches it to a window,
        // so the active window scene's EDR headroom is only available here.
        configureExtendedDynamicRangePresentation()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Force the MTKView to trigger draw() when bounds change due to rotation,
        // ensuring the aspect ratio transforms recalculate correctly while paused.
        self.setNeedsDisplay(self.bounds)
    }
    #endif
}
