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

    /// Sharpness intensity (0 = off, >0 applies CIUnsharpMask)
    public var sharpness: Float = 0.0

    /// HDR tone mapping strength (0.0 = off, >0 expands SDR highlights into display EDR headroom)
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

        // Configure MTKView for EDR support via RGBA16Float pixel format
        self.colorPixelFormat = .rgba16Float
        self.framebufferOnly = false
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.enableSetNeedsDisplay = true
        self.isPaused = true // We manually trigger drawing when a new frame is received

        // Enable Extended Dynamic Range on the Metal layer so the display does not clamp values > 1.0
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
        }

        self.commandQueue = device.makeCommandQueue()
        if let queue = commandQueue {
            // Initialize CoreImage context with extended linear sRGB working space.
            // This allows CIFilters to produce values > 1.0 for HDR tone expansion.
            let extendedLinearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            self.ciContext = CIContext(mtlCommandQueue: queue, options: [
                .cacheIntermediates: false,
                .useSoftwareRenderer: false,
                .workingColorSpace: extendedLinearSpace as Any
            ])
        }
    }
    
    /// Updates the renderer with a new frame and schedules it to draw.
    /// - Parameter pixelBuffer: The new CVPixelBuffer frame to display.
    public func render(pixelBuffer: CVPixelBuffer) {
        self.currentPixelBuffer = pixelBuffer
        // Trigger a draw pass on the next screen refresh cycle
        self.draw()
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
        if sharpness > 0 {
            sharpenedImage = (ciImage.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputIntensityKey: sharpness,
                kCIInputRadiusKey: 0.5
            ]))
        } else {
            sharpenedImage = ciImage
        }

        // Apply optional HDR tone expansion (pushes highlights into display EDR headroom)
        let hdrImage: CIImage
        if hdrStrength > 0 {
            // Exposure boost pushes bright values beyond 1.0 into EDR territory;
            // saturation and contrast make the image more vibrant.
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
        // Extended sRGB color space preserves values > 1.0 for HDR/EDR display.
        let targetRect = CGRect(x: 0, y: 0, width: drawableSize.width, height: drawableSize.height)
        let outputColorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB) ?? CGColorSpaceCreateDeviceRGB()
        context.render(
            transformedImage,
            to: destinationTexture,
            commandBuffer: commandBuffer,
            bounds: targetRect,
            colorSpace: outputColorSpace
        )
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
