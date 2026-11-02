import Foundation
import MetalKit
import CoreVideo
import CoreImage
import QuartzCore
import Synchronization

#if os(macOS)
struct MacFullCacheRendererConfiguration: @unchecked Sendable {
    let drawableSize: CGSize
    let sharpness: Float
    let hdrStrength: Float
    let hdrColorfulness: Float
    let isExtendedDynamicRangeActive: Bool
    let currentEDRHeadroom: Float
    let potentialEDRHeadroom: Float
    let nativeHDRColorSpace: CGColorSpace?
    let outputColorSpace: CGColorSpace
}

nonisolated final class MacFullCacheMetalEncoder: @unchecked Sendable {
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let performanceAggregate: RendererPerformanceAggregate
    private let gpuPerformanceRecorder: RendererGPUPerformanceRecorder
    private let presentationPerformanceRecorder: RendererPresentationPerformanceRecorder
    private let configuration: Mutex<MacFullCacheRendererConfiguration>
    private let midtoneChromaKernel = CIColorKernel(source: """
        kernel vec4 midtoneChromaCompensation(__sample image, float amount) {
            float luma = dot(image.rgb, vec3(0.2126, 0.7152, 0.0722));
            float shadowWeight = smoothstep(0.08, 0.25, luma);
            float highlightWeight = 1.0 - smoothstep(0.60, 0.95, luma);
            float compensation = amount * shadowWeight * highlightWeight;
            vec3 compensated = mix(vec3(luma), image.rgb, 1.0 + compensation);
            return vec4(compensated, image.a);
        }
        """)

    init?(
        device: MTLDevice,
        configuration: MacFullCacheRendererConfiguration,
        performanceAggregate: RendererPerformanceAggregate,
        gpuPerformanceRecorder: RendererGPUPerformanceRecorder,
        presentationPerformanceRecorder: RendererPresentationPerformanceRecorder
    ) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue
        self.context = CIContext(mtlCommandQueue: commandQueue, options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: false
        ])
        self.configuration = Mutex(configuration)
        self.performanceAggregate = performanceAggregate
        self.gpuPerformanceRecorder = gpuPerformanceRecorder
        self.presentationPerformanceRecorder = presentationPerformanceRecorder
    }

    func update(configuration: MacFullCacheRendererConfiguration) {
        self.configuration.withLock { $0 = configuration }
    }

    func encode(
        pixelBuffer: CVPixelBuffer,
        to drawable: CAMetalDrawable,
        drawableAcquisitionStart: DispatchTime,
        targetPresentationTime: CFTimeInterval
    ) -> Bool {
        let configuration = configuration.withLock { $0 }
        let drawableSize = configuration.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        performanceAggregate.recordDrawAttempt()
        performanceAggregate.recordDrawableAcquisition(start: drawableAcquisitionStart)
        let encodeStart = DispatchTime.now()
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if configuration.sharpness > 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputIntensityKey: configuration.sharpness,
                kCIInputRadiusKey: 0.5
            ])
        }

        if configuration.isExtendedDynamicRangeActive {
            let normalizedStrength = min(max(configuration.hdrStrength / 2.0, 0), 1)
            let measuredHeadroom = max(
                configuration.currentEDRHeadroom,
                configuration.potentialEDRHeadroom
            )
            let exposureEV: CGFloat
            if configuration.nativeHDRColorSpace != nil {
                exposureEV = CGFloat(normalizedStrength)
            } else {
                let targetHeadroom = 1 + (measuredHeadroom - 1) * normalizedStrength
                exposureEV = CGFloat(log2(targetHeadroom))
            }
            image = image.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: exposureEV
            ])
            if configuration.hdrColorfulness > 0, let midtoneChromaKernel {
                image = midtoneChromaKernel.apply(
                    extent: image.extent,
                    arguments: [image, min(max(configuration.hdrColorfulness, 0), 1)]
                ) ?? image
            }
        }

        let imageSize = image.extent.size
        let scale = min(
            drawableSize.width / imageSize.width,
            drawableSize.height / imageSize.height
        )
        let offsetX = (drawableSize.width - imageSize.width * scale) / 2
        let offsetY = (drawableSize.height - imageSize.height * scale) / 2
        image = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
        )

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1
        )
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) {
            renderEncoder.endEncoding()
        }

        context.render(
            image,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: drawableSize),
            colorSpace: configuration.outputColorSpace
        )
        let presentationRecorder = presentationPerformanceRecorder
        drawable.addPresentedHandler { drawable in
            presentationRecorder.record(presentedTime: drawable.presentedTime)
        }
        let gpuRecorder = gpuPerformanceRecorder
        commandBuffer.addCompletedHandler { commandBuffer in
            let start = commandBuffer.gpuStartTime
            let end = commandBuffer.gpuEndTime
            guard start.isFinite, end.isFinite, end >= start else { return }
            let duration = (end - start) * 1_000_000_000
            guard duration <= Double(UInt64.max) else { return }
            gpuRecorder.recordCompletion(durationNanoseconds: UInt64(duration))
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        performanceAggregate.recordCPUEncode(start: encodeStart)
        return true
    }
}
#endif

