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
        self.enableSetNeedsDisplay = true
        self.isPaused = true // We manually trigger drawing when a new frame is received
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
    
    /// Updates the renderer with a new frame and schedules it to draw.
    /// - Parameters:
    ///   - pixelBuffer: The new CVPixelBuffer frame to display.
    ///   - isInterpolated: True if this is an interpolated frame.
    public func render(pixelBuffer: CVPixelBuffer, isInterpolated: Bool = false) {
        self.currentPixelBuffer = pixelBuffer
        self.currentFrameIsInterpolated = isInterpolated
        // Schedule a draw pass on the next display refresh cycle rather
        // than drawing synchronously.  draw() blocks on currentDrawable
        // and CIContext.render(); for large SR-upscaled frames this can
        // take 5-10ms, stalling the consumer's timing loop and causing
        // visible stutter even though FPS averages look correct.
        self.setNeedsDisplay(self.bounds)
    }
    
    public override func draw(_ rect: CGRect) {
        guard let pixelBuffer = currentPixelBuffer,
              let drawable = currentDrawable,
              let queue = commandQueue,
              let context = ciContext else {
            return
        }
        
        let drawableSize = self.drawableSize
        let destinationTexture = drawable.texture
        
        // Create CoreImage image wrapping the pixel buffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Apply optional sharpness filter
        let sharpenedImage: CIImage
        let activeSharpness = currentFrameIsInterpolated ? max(sharpness, 1.25) : sharpness
        if activeSharpness > 0 {
            sharpenedImage = (ciImage.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputIntensityKey: activeSharpness,
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
