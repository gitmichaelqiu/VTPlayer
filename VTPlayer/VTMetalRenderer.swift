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

/// A high-performance Metal-backed view for rendering CVPixelBuffer frames.
@MainActor
public final class VTMetalRenderer: MTKView {
    
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    
    // The current pixel buffer to render
    private var currentPixelBuffer: CVPixelBuffer?
    private var currentFrameIsInterpolated = false

    /// Sharpness intensity (0 = off, >0 applies CIUnsharpMask)
    public var sharpness: Float = 0.0

    /// Brightness/contrast boost strength (0.0 = off, >0 applies exposure/saturation/contrast boost)
    public var hdrStrength: Float = 0.0

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
    }

    #if os(macOS)
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSizeForBackingScale()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSizeForBackingScale()
    }

    public override func layout() {
        super.layout()
        updateDrawableSizeForBackingScale()
    }

    /// SwiftUI supplies an NSView's bounds in points. Keep the Metal drawable
    /// in backing pixels so enabling the processing pipeline does not render
    /// at half resolution on a Retina display.
    private func updateDrawableSizeForBackingScale() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        layer?.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0, drawableSize != size else { return }
        drawableSize = size
    }
    #endif
    
    /// Updates the renderer with a new frame for presentation.
    /// - Parameters:
    ///   - pixelBuffer: The new CVPixelBuffer frame to display.
    ///   - isInterpolated: True if this is an interpolated frame.
    public func render(pixelBuffer: CVPixelBuffer, isInterpolated: Bool = false) {
        self.currentPixelBuffer = pixelBuffer
        self.currentFrameIsInterpolated = isInterpolated
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
        self.isPaused = !active
    }
    #endif

    /// Removes the currently displayed frame and redraws the view as black.
    public func clear() {
        self.currentPixelBuffer = nil
        self.currentFrameIsInterpolated = false
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
        let sharpnessIntensity = currentFrameIsInterpolated ? max(sharpness, 1.25) : sharpness
        if sharpnessIntensity > 0 {
            sharpenedImage = (ciImage.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputIntensityKey: sharpnessIntensity,
                kCIInputRadiusKey: 0.5
            ]))
        } else {
            sharpenedImage = ciImage
        }

        // Apply optional brightness/contrast boost (exposure + saturation + contrast)
        let hdrImage: CIImage
        if hdrStrength > 0 {
            hdrImage = sharpenedImage
                .applyingFilter("CIExposureAdjust", parameters: [
                    kCIInputEVKey: hdrStrength * 0.75
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.0 + hdrStrength * 0.15,
                    kCIInputContrastKey: 1.0 + hdrStrength * 0.1
                ])
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
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    #if os(iOS)
    public override func layoutSubviews() {
        super.layoutSubviews()
        // Force the MTKView to trigger draw() when bounds change due to rotation,
        // ensuring the aspect ratio transforms recalculate correctly while paused.
        self.setNeedsDisplay(self.bounds)
    }
    #endif
}
