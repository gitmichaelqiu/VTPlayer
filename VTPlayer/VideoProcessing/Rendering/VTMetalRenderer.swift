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
import Synchronization

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct RendererPerformanceSnapshot: Equatable {
    let drawAttempts: Int
    let drawableAcquisitions: Int
    let encodedFrames: Int
    let totalDrawableAcquisitionNanoseconds: UInt64
    let totalCPUEncodeNanoseconds: UInt64
    let completedGPUFrames: Int
    let totalGPUNanoseconds: UInt64

    var averageDrawableAcquisitionMilliseconds: Double {
        guard drawableAcquisitions > 0 else { return 0 }
        return Double(totalDrawableAcquisitionNanoseconds) / Double(drawableAcquisitions) / 1_000_000.0
    }

    var averageCPUEncodeMilliseconds: Double {
        guard encodedFrames > 0 else { return 0 }
        return Double(totalCPUEncodeNanoseconds) / Double(encodedFrames) / 1_000_000.0
    }

    var averageGPUMilliseconds: Double {
        guard completedGPUFrames > 0 else { return 0 }
        return Double(totalGPUNanoseconds) / Double(completedGPUFrames) / 1_000_000.0
    }
}

struct RendererPerformanceAggregate {
    private var drawAttempts = 0
    private var drawableAcquisitions = 0
    private var encodedFrames = 0
    private var totalDrawableAcquisitionNanoseconds: UInt64 = 0
    private var totalCPUEncodeNanoseconds: UInt64 = 0

    mutating func recordDrawAttempt() {
        drawAttempts += 1
    }

    mutating func recordDrawableAcquisition(start: DispatchTime, end: DispatchTime = .now()) {
        drawableAcquisitions += 1
        guard end.uptimeNanoseconds >= start.uptimeNanoseconds else { return }
        totalDrawableAcquisitionNanoseconds += end.uptimeNanoseconds - start.uptimeNanoseconds
    }

    mutating func recordCPUEncode(start: DispatchTime, end: DispatchTime = .now()) {
        encodedFrames += 1
        guard end.uptimeNanoseconds >= start.uptimeNanoseconds else { return }
        totalCPUEncodeNanoseconds += end.uptimeNanoseconds - start.uptimeNanoseconds
    }

    mutating func consumeSnapshot(completedGPU: RendererGPUPerformanceSnapshot) -> RendererPerformanceSnapshot {
        let snapshot = RendererPerformanceSnapshot(
            drawAttempts: drawAttempts,
            drawableAcquisitions: drawableAcquisitions,
            encodedFrames: encodedFrames,
            totalDrawableAcquisitionNanoseconds: totalDrawableAcquisitionNanoseconds,
            totalCPUEncodeNanoseconds: totalCPUEncodeNanoseconds,
            completedGPUFrames: completedGPU.completedFrames,
            totalGPUNanoseconds: completedGPU.totalNanoseconds
        )
        drawAttempts = 0
        drawableAcquisitions = 0
        encodedFrames = 0
        totalDrawableAcquisitionNanoseconds = 0
        totalCPUEncodeNanoseconds = 0
        return snapshot
    }
}

struct RendererGPUPerformanceSnapshot: Equatable, Sendable {
    let completedFrames: Int
    let totalNanoseconds: UInt64
}

struct RendererSchedulingSnapshot: Equatable {
    let preferredFramesPerSecond: Int
    let presentsWithTransaction: Bool
    let displaySyncEnabled: Bool
    let screenMaximumFramesPerSecond: Int
    let screenMinimumRefreshInterval: TimeInterval
    let screenMaximumRefreshInterval: TimeInterval
    let displayModeRefreshRate: Double
}

private struct RendererGPUPerformanceStorage: Sendable {
    var completedFrames = 0
    var totalNanoseconds: UInt64 = 0
}

private final class RendererGPUPerformanceRecorder: @unchecked Sendable {
    private let storage = Mutex(RendererGPUPerformanceStorage())

    func recordCompletion(durationNanoseconds: UInt64) {
        storage.withLock { storage in
            storage.completedFrames += 1
            storage.totalNanoseconds += durationNanoseconds
        }
    }

    func consumeSnapshot() -> RendererGPUPerformanceSnapshot {
        storage.withLock { storage in
            let snapshot = RendererGPUPerformanceSnapshot(
                completedFrames: storage.completedFrames,
                totalNanoseconds: storage.totalNanoseconds
            )
            storage = RendererGPUPerformanceStorage()
            return snapshot
        }
    }
}

/// A high-performance Metal-backed view for rendering CVPixelBuffer frames.
@MainActor
public final class VTMetalRenderer: MTKView {

    internal var commandQueue: MTLCommandQueue?
    internal var ciContext: CIContext?
    internal var performanceAggregate = RendererPerformanceAggregate()
    private let gpuPerformanceRecorder = RendererGPUPerformanceRecorder()

    // The current pixel buffer to render
    internal var currentPixelBuffer: CVPixelBuffer?
    internal var needsDrawableUpdate = true
    internal enum NativeHDRTransfer: Equatable {
        case pq
        case hlg
    }
    internal var nativeHDRTransfer: NativeHDRTransfer?
    #if os(macOS)
    internal var renderingActive = false
    internal var usesExternalDisplayScheduling = false
    internal var pausedLayoutRedrawPending = false
    internal var lastLayoutSize: CGSize = .zero
    #endif
    #if os(iOS)
    internal var edrRefreshAttempts = 0
    internal var pausedLayoutRedrawPending = false
    #endif

    public var sharpness: Float = 0.0 {
        didSet {
            requestRedrawForImageAdjustment()
        }
    }

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
    public internal(set) var isExtendedDynamicRangeActive = false

    internal let extendedLinearDisplayP3ColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    internal var nativeHDRColorSpace: CGColorSpace? {
        switch nativeHDRTransfer {
        case .pq:
            return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .hlg:
            return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case nil:
            return nil
        }
    }

    internal lazy var midtoneChromaKernel: CIColorKernel? = CIColorKernel(source: """
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

    /// Updates the renderer with a new frame for presentation.
    /// - Parameters:
    ///   - pixelBuffer: The new CVPixelBuffer frame to display.
    ///   - isInterpolated: Retained for caller compatibility; rendering uses
    ///     the same user-selected sharpness for source and generated frames.
    public func render(pixelBuffer: CVPixelBuffer, isInterpolated _: Bool = false) {
        updateNativeHDRPresentation(for: pixelBuffer)
        self.currentPixelBuffer = pixelBuffer
        needsDrawableUpdate = true
        #if os(macOS)
        if self.isPaused && !usesExternalDisplayScheduling {
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
        self.isPaused = !active || usesExternalDisplayScheduling
    }

    /// Uses an owner-provided display callback while retaining MTKView's
    /// drawable and Metal presentation implementation.
    public func setExternalDisplayScheduling(_ enabled: Bool) {
        usesExternalDisplayScheduling = enabled
        isPaused = !renderingActive || enabled
    }
    #endif

    /// Removes the currently displayed frame and redraws the view as black.
    public func clear() {
        self.currentPixelBuffer = nil
        needsDrawableUpdate = true
        #if os(macOS)
        self.draw()
        #else
        self.draw()
        #endif
    }

    internal func consumePerformanceSnapshot() -> RendererPerformanceSnapshot {
        performanceAggregate.consumeSnapshot(completedGPU: gpuPerformanceRecorder.consumeSnapshot())
    }

    #if os(macOS)
    internal func schedulingSnapshot() -> RendererSchedulingSnapshot {
        let metalLayer = layer as? CAMetalLayer
        let displayID = window?.screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ].flatMap { ($0 as? NSNumber).map(CGDirectDisplayID.init(truncating:)) }
        let displayModeRefreshRate = displayID
            .flatMap(CGDisplayCopyDisplayMode)
            .map(\.refreshRate) ?? 0
        return RendererSchedulingSnapshot(
            preferredFramesPerSecond: preferredFramesPerSecond,
            presentsWithTransaction: presentsWithTransaction,
            displaySyncEnabled: metalLayer?.displaySyncEnabled ?? true,
            screenMaximumFramesPerSecond: window?.screen?.maximumFramesPerSecond ?? 0,
            screenMinimumRefreshInterval: window?.screen?.minimumRefreshInterval ?? 0,
            screenMaximumRefreshInterval: window?.screen?.maximumRefreshInterval ?? 0,
            displayModeRefreshRate: displayModeRefreshRate
        )
    }
    #endif

    public override func draw(_ rect: CGRect) {
        #if os(macOS)
        let drawSignpost = MacPresentationSignposts.begin("MTKDraw")
        defer { MacPresentationSignposts.end("MTKDraw", identifier: drawSignpost) }
        #endif
        performanceAggregate.recordDrawAttempt()
        let drawableAcquisitionStart = DispatchTime.now()
        guard let drawable = currentDrawable else {
            return
        }
        performanceAggregate.recordDrawableAcquisition(start: drawableAcquisitionStart)

        #if os(macOS)
        // Only advance the presentation queue when this draw has a drawable;
        // resize/occlusion callbacks must not consume a frame that cannot be
        // presented to the screen.
        onDisplayTick?()
        #endif

        drawCurrentFrame(to: drawable)
    }

    #if os(macOS)
    /// Encodes directly into the drawable provided by CAMetalDisplayLink.
    /// This avoids a second drawable acquisition between the display callback
    /// and presentation.
    public func draw(to drawable: CAMetalDrawable) {
        performanceAggregate.recordDrawAttempt()
        let drawableAcquisitionStart = DispatchTime.now()
        performanceAggregate.recordDrawableAcquisition(start: drawableAcquisitionStart)
        drawCurrentFrame(to: drawable)
    }
    #endif

    private func drawCurrentFrame(to drawable: CAMetalDrawable) {
        guard needsDrawableUpdate else { return }

        guard let queue = commandQueue else { return }

        if currentPixelBuffer == nil {
            #if os(macOS)
            let encodeSignpost = MacPresentationSignposts.begin("CoreImageEncode")
            defer { MacPresentationSignposts.end("CoreImageEncode", identifier: encodeSignpost) }
            #endif
            let encodeStart = DispatchTime.now()
            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].clearColor = clearColor
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            trackGPUCompletion(of: commandBuffer)
            commandBuffer.commit()
            performanceAggregate.recordCPUEncode(start: encodeStart)
            needsDrawableUpdate = false
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
        if isExtendedDynamicRangeActive {
            let normalizedStrength = min(max(hdrStrength / 2.0, 0), 1)
            let measuredHeadroom = max(currentEDRHeadroom, potentialEDRHeadroom)
            #if os(iOS)
            // The first EDR drawable can still report SDR headroom. The layer
            // is explicitly tagged for at least 2x, so keep the restored boost
            // visible until UIKit reports the display's live value.
            let availableHeadroom = max(measuredHeadroom, 2.0)
            #else
            let availableHeadroom = measuredHeadroom
            #endif
            let exposureEV: CGFloat
            if nativeHDRTransfer != nil {
                // Native PQ/HLG already carries HDR luminance. Apply a
                // bounded additional lift rather than remapping it as SDR.
                exposureEV = CGFloat(normalizedStrength)
            } else {
                let targetHeadroom = 1 + (availableHeadroom - 1) * normalizedStrength
                exposureEV = CGFloat(log2(targetHeadroom))
            }
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
        #if os(macOS)
        let encodeSignpost = MacPresentationSignposts.begin("CoreImageEncode")
        defer { MacPresentationSignposts.end("CoreImageEncode", identifier: encodeSignpost) }
        #endif
        let encodeStart = DispatchTime.now()
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
        trackGPUCompletion(of: commandBuffer)
        commandBuffer.commit()
        performanceAggregate.recordCPUEncode(start: encodeStart)
        needsDrawableUpdate = false
    }

    private func trackGPUCompletion(of commandBuffer: MTLCommandBuffer) {
        #if os(macOS)
        let completionSignpost = MacPresentationSignposts.begin("CommandBuffer")
        #endif
        let recorder = gpuPerformanceRecorder
        commandBuffer.addCompletedHandler { commandBuffer in
            #if os(macOS)
            MacPresentationSignposts.end("CommandBuffer", identifier: completionSignpost)
            #endif
            let start = commandBuffer.gpuStartTime
            let end = commandBuffer.gpuEndTime
            guard start.isFinite, end.isFinite, end >= start else { return }
            let duration = (end - start) * 1_000_000_000
            guard duration <= Double(UInt64.max) else { return }
            recorder.recordCompletion(durationNanoseconds: UInt64(duration))
        }
    }

    #if os(iOS)
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // The renderer is constructed before SwiftUI attaches it to a window,
        // so the active window scene's EDR headroom is only available here.
        configureExtendedDynamicRangePresentation()
        if hdrStrength > 0 || nativeHDRTransfer != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.configureExtendedDynamicRangePresentation()
                self.setNeedsDisplay(self.bounds)
                self.draw()
            }
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        configureExtendedDynamicRangePresentation()
        needsDrawableUpdate = true
        self.setNeedsDisplay(self.bounds)
        guard isPaused, !pausedLayoutRedrawPending else { return }
        pausedLayoutRedrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pausedLayoutRedrawPending = false
            guard self.isPaused else { return }
            self.draw()
        }
    }
    #endif
}
