//
//  VTFrameProcessorCoordinator.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// A coordinator actor that manages the VideoToolbox session, memory pooling, and processing execution.
public actor VTFrameProcessorCoordinator {
    
    /// Checks if VideoToolbox Low-Latency Super Resolution is supported on the current hardware.
    public static func isSuperResolutionSupported() -> Bool {
        return VTLowLatencySuperResolutionScalerConfiguration.isSupported
    }
    
    /// Queries the list of supported scale factors for the given frame dimensions.
    public static func supportedSuperResolutionScaleFactors(width: Int, height: Int) -> [Float] {
        return VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height)
    }
    
    // Configurations
    public let superResolutionLevel: Int // 0, 2, 4
    public let frameInterpolationLevel: Int // 0, 2, 4
    
    private var isSessionActive = false
    
    // Configured dimensions
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var targetWidth = 0
    private var targetHeight = 0
    
    // Processors
    private var temporalProcessor: VTFrameProcessor?
    private var spatialProcessor1: VTFrameProcessor?
    private var spatialProcessor2: VTFrameProcessor?
    
    // Memory pools
    private var temporalPool: CVPixelBufferPool?
    private var spatialPool1: CVPixelBufferPool?
    private var spatialPool2: CVPixelBufferPool?
    
    // State tracking
    private var previousSourceFrame: VTFrameProcessorFrame?
    private var previousOutputFrame: VTFrameProcessorFrame?
    private var isFirstFrame = true
    
    public init(superResolutionLevel: Int, frameInterpolationLevel: Int) {
        self.superResolutionLevel = superResolutionLevel
        self.frameInterpolationLevel = frameInterpolationLevel
    }
    
    private func makePool(width: Int, height: Int, from attributes: [AnyHashable: Any]?) -> CVPixelBufferPool? {
        var dict: [AnyHashable: Any] = attributes ?? [:]
        dict[kCVPixelBufferWidthKey] = width
        dict[kCVPixelBufferHeightKey] = height
        if dict[kCVPixelBufferPixelFormatTypeKey] == nil {
            dict[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        if dict[kCVPixelBufferIOSurfacePropertiesKey] == nil {
            dict[kCVPixelBufferIOSurfacePropertiesKey] = [:] as [String: Any]
        }
        var pool: CVPixelBufferPool?
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 15] as CFDictionary
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, dict as CFDictionary, &pool)
        return status == kCVReturnSuccess ? pool : nil
    }
    
    /// Starts the processing session for the given input dimensions.
    public func startSession(width: Int, height: Int) throws {
        guard !isSessionActive else { return }
        
        self.sourceWidth = width
        self.sourceHeight = height
        
        // Check for native combined 2x/2x configuration
        if superResolutionLevel == 2 && frameInterpolationLevel == 2 {
            self.targetWidth = width * 2
            self.targetHeight = height * 2
            guard let combinedConfig = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                spatialScaleFactor: 2
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize native combined configuration"])
            }
            let proc = VTFrameProcessor()
            try proc.startSession(configuration: combinedConfig)
            self.temporalProcessor = proc
            
            let destAttributes = combinedConfig.destinationPixelBufferAttributes
            self.temporalPool = makePool(width: width * 2, height: height * 2, from: destAttributes)
            if self.temporalPool == nil {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create combined pool"])
            }
            
        } else if superResolutionLevel == 4 && frameInterpolationLevel == 2 {
            // Combined 2x/2x first, then 2x spatial again to reach 4x size
            self.targetWidth = width * 4
            self.targetHeight = height * 4
            guard let combinedConfig = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                spatialScaleFactor: 2
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize native combined configuration"])
            }
            let proc1 = VTFrameProcessor()
            try proc1.startSession(configuration: combinedConfig)
            self.temporalProcessor = proc1
            
            let destAttributes1 = combinedConfig.destinationPixelBufferAttributes
            self.temporalPool = makePool(width: width * 2, height: height * 2, from: destAttributes1)
            if self.temporalPool == nil {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create combined pool"])
            }
            
            // Second spatial upscaler 2x -> 4x
            let srConfig = VTLowLatencySuperResolutionScalerConfiguration(
                frameWidth: width * 2,
                frameHeight: height * 2,
                scaleFactor: 2.0
            )
            let proc2 = VTFrameProcessor()
            try proc2.startSession(configuration: srConfig)
            self.spatialProcessor2 = proc2
            
            let destAttributes2 = srConfig.destinationPixelBufferAttributes
            self.spatialPool2 = makePool(width: width * 4, height: height * 4, from: destAttributes2)
            if self.spatialPool2 == nil {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create second spatial pool"])
            }
            
        } else {
            // Cascaded configuration
            var currentWidth = width
            var currentHeight = height
            
            // 1. Setup Temporal Processor
            if frameInterpolationLevel > 0 {
                let numFrames = frameInterpolationLevel == 4 ? 3 : 1
                guard let config = VTLowLatencyFrameInterpolationConfiguration(
                    frameWidth: currentWidth,
                    frameHeight: currentHeight,
                    numberOfInterpolatedFrames: numFrames
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize interpolation config"])
                }
                let proc = VTFrameProcessor()
                try proc.startSession(configuration: config)
                self.temporalProcessor = proc
                
                let destAttributes = config.destinationPixelBufferAttributes
                self.temporalPool = makePool(width: currentWidth, height: currentHeight, from: destAttributes)
                if self.temporalPool == nil {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create temporal pool"])
                }
            }
            
            // 2. Setup Spatial Processor 1 (2x upscaler)
            if superResolutionLevel >= 2 {
                let config = VTLowLatencySuperResolutionScalerConfiguration(
                    frameWidth: currentWidth,
                    frameHeight: currentHeight,
                    scaleFactor: 2.0
                )
                let proc = VTFrameProcessor()
                try proc.startSession(configuration: config)
                self.spatialProcessor1 = proc
                
                let destAttributes = config.destinationPixelBufferAttributes
                self.spatialPool1 = makePool(width: currentWidth * 2, height: currentHeight * 2, from: destAttributes)
                if self.spatialPool1 == nil {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create spatial pool 1"])
                }
                
                currentWidth = currentWidth * 2
                currentHeight = currentHeight * 2
            }
            
            // 3. Setup Spatial Processor 2 (4x upscaler)
            if superResolutionLevel == 4 {
                let config = VTLowLatencySuperResolutionScalerConfiguration(
                    frameWidth: currentWidth,
                    frameHeight: currentHeight,
                    scaleFactor: 2.0
                )
                let proc = VTFrameProcessor()
                try proc.startSession(configuration: config)
                self.spatialProcessor2 = proc
                
                let destAttributes = config.destinationPixelBufferAttributes
                self.spatialPool2 = makePool(width: currentWidth * 2, height: currentHeight * 2, from: destAttributes)
                if self.spatialPool2 == nil {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create spatial pool 2"])
                }
                
                currentWidth = currentWidth * 2
                currentHeight = currentHeight * 2
            }
            
            self.targetWidth = currentWidth
            self.targetHeight = currentHeight
        }
        
        self.isSessionActive = true
        self.isFirstFrame = true
        self.previousSourceFrame = nil
        self.previousOutputFrame = nil
    }
    
    /// Processes a single incoming frame and returns a sequence of processed frames.
    public func processFrame(_ frame: VTFrame) async throws -> [VTFrame] {
        guard isSessionActive else {
            return [frame]
        }
        
        var framesToScale: [VTFrame] = []
        
        // 1. Run Temporal / Combined Interpolation
        if let temporalProcessor = temporalProcessor, let pool = temporalPool {
            let sourcePTS = frame.presentationTimeStamp
            guard let sourceFPFrame = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: sourcePTS) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create source frame"])
            }
            
            let prevFPFrame: VTFrameProcessorFrame
            if isFirstFrame {
                let offsetTime = CMTimeSubtract(sourcePTS, CMTime(value: 1, timescale: 30))
                guard let dummyPrev = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: offsetTime) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create dummy previous frame"])
                }
                prevFPFrame = dummyPrev
            } else {
                guard let lastSource = previousSourceFrame else {
                    return []
                }
                prevFPFrame = lastSource
            }
            
            // Check if we are using the combined native spatial/temporal scaling
            if (superResolutionLevel == 2 || superResolutionLevel == 4) && frameInterpolationLevel == 2 {
                // Combined 2x spatial + 2x temporal
                var buf1: CVPixelBuffer?
                var buf2: CVPixelBuffer?
                
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf1) == kCVReturnSuccess, let outBuf1 = buf1,
                      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf2) == kCVReturnSuccess, let outBuf2 = buf2 else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "Pool allocation failed"])
                }
                
                let midPTS = CMTimeAdd(prevFPFrame.presentationTimeStamp, CMTimeMultiplyByFloat64(CMTimeSubtract(sourcePTS, prevFPFrame.presentationTimeStamp), multiplier: 0.5))
                
                guard let destFrame1 = VTFrameProcessorFrame(buffer: outBuf1, presentationTimeStamp: midPTS),
                      let destFrame2 = VTFrameProcessorFrame(buffer: outBuf2, presentationTimeStamp: sourcePTS) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination frames"])
                }
                
                guard let params = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: sourceFPFrame,
                    previousFrame: prevFPFrame,
                    interpolationPhase: [0.5] as [Float],
                    destinationFrames: [destFrame1, destFrame2]
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize combined parameters"])
                }
                
                _ = try await temporalProcessor.process(parameters: params)
                
                self.previousSourceFrame = sourceFPFrame
                self.isFirstFrame = false
                
                framesToScale = [
                    VTFrame(buffer: outBuf1, presentationTimeStamp: midPTS),
                    VTFrame(buffer: outBuf2, presentationTimeStamp: sourcePTS)
                ]
            } else if frameInterpolationLevel == 4 {
                // 4x framerate: 3 interpolated frames
                var buf1: CVPixelBuffer?
                var buf2: CVPixelBuffer?
                var buf3: CVPixelBuffer?
                
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf1) == kCVReturnSuccess, let outBuf1 = buf1,
                      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf2) == kCVReturnSuccess, let outBuf2 = buf2,
                      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf3) == kCVReturnSuccess, let outBuf3 = buf3 else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "Pool allocation failed"])
                }
                
                let diff = CMTimeSubtract(sourcePTS, prevFPFrame.presentationTimeStamp)
                let t1 = CMTimeAdd(prevFPFrame.presentationTimeStamp, CMTimeMultiplyByFloat64(diff, multiplier: 0.25))
                let t2 = CMTimeAdd(prevFPFrame.presentationTimeStamp, CMTimeMultiplyByFloat64(diff, multiplier: 0.50))
                let t3 = CMTimeAdd(prevFPFrame.presentationTimeStamp, CMTimeMultiplyByFloat64(diff, multiplier: 0.75))
                
                guard let destFrame1 = VTFrameProcessorFrame(buffer: outBuf1, presentationTimeStamp: t1),
                      let destFrame2 = VTFrameProcessorFrame(buffer: outBuf2, presentationTimeStamp: t2),
                      let destFrame3 = VTFrameProcessorFrame(buffer: outBuf3, presentationTimeStamp: t3) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination frames"])
                }
                
                guard let params = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: sourceFPFrame,
                    previousFrame: prevFPFrame,
                    interpolationPhase: [0.25, 0.5, 0.75] as [Float],
                    destinationFrames: [destFrame1, destFrame2, destFrame3]
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize interpolation parameters"])
                }
                
                _ = try await temporalProcessor.process(parameters: params)
                
                self.previousSourceFrame = sourceFPFrame
                self.isFirstFrame = false
                
                framesToScale = [
                    VTFrame(buffer: outBuf1, presentationTimeStamp: t1),
                    VTFrame(buffer: outBuf2, presentationTimeStamp: t2),
                    VTFrame(buffer: outBuf3, presentationTimeStamp: t3),
                    frame
                ]
            } else {
                // 2x framerate: 1 interpolated frame
                var buf1: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf1) == kCVReturnSuccess, let outBuf1 = buf1 else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "Pool allocation failed"])
                }
                
                let midPTS = CMTimeAdd(prevFPFrame.presentationTimeStamp, CMTimeMultiplyByFloat64(CMTimeSubtract(sourcePTS, prevFPFrame.presentationTimeStamp), multiplier: 0.5))
                guard let destFrame1 = VTFrameProcessorFrame(buffer: outBuf1, presentationTimeStamp: midPTS) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination frame"])
                }
                
                guard let params = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: sourceFPFrame,
                    previousFrame: prevFPFrame,
                    interpolationPhase: [0.5] as [Float],
                    destinationFrames: [destFrame1]
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize interpolation parameters"])
                }
                
                _ = try await temporalProcessor.process(parameters: params)
                
                self.previousSourceFrame = sourceFPFrame
                self.isFirstFrame = false
                
                framesToScale = [
                    VTFrame(buffer: outBuf1, presentationTimeStamp: midPTS),
                    frame
                ]
            }
        } else {
            framesToScale = [frame]
        }
        
        // 2. Run Spatial Scaling
        var processedFrames: [VTFrame] = []
        
        for f in framesToScale {
            var currentBuffer = f.buffer
            
            // Spatial Stage 1 (2x)
            let inCombinedMode = (superResolutionLevel == 2 || superResolutionLevel == 4) && frameInterpolationLevel == 2
            if !inCombinedMode, let spatialProcessor1 = spatialProcessor1, let pool1 = spatialPool1 {
                var buf1: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool1, &buf1) == kCVReturnSuccess, let outBuf1 = buf1 else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "Pool 1 allocation failed"])
                }
                
                guard let sourceFP = VTFrameProcessorFrame(buffer: currentBuffer, presentationTimeStamp: f.presentationTimeStamp),
                      let destFP = VTFrameProcessorFrame(buffer: outBuf1, presentationTimeStamp: f.presentationTimeStamp) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create frames for scaling"])
                }
                
                let params = VTLowLatencySuperResolutionScalerParameters(
                    sourceFrame: sourceFP,
                    destinationFrame: destFP
                )
                
                _ = try await spatialProcessor1.process(parameters: params)
                currentBuffer = outBuf1
            }
            
            // Spatial Stage 2 (4x)
            if let spatialProcessor2 = spatialProcessor2, let pool2 = spatialPool2 {
                var buf2: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool2, &buf2) == kCVReturnSuccess, let outBuf2 = buf2 else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "Pool 2 allocation failed"])
                }
                
                guard let sourceFP = VTFrameProcessorFrame(buffer: currentBuffer, presentationTimeStamp: f.presentationTimeStamp),
                      let destFP = VTFrameProcessorFrame(buffer: outBuf2, presentationTimeStamp: f.presentationTimeStamp) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create frames for scaling stage 2"])
                }
                
                let params = VTLowLatencySuperResolutionScalerParameters(
                    sourceFrame: sourceFP,
                    destinationFrame: destFP
                )
                
                _ = try await spatialProcessor2.process(parameters: params)
                currentBuffer = outBuf2
            }
            
            processedFrames.append(VTFrame(buffer: currentBuffer, presentationTimeStamp: f.presentationTimeStamp))
        }
        
        return processedFrames
    }
    
    /// Ends the processing session and cleans up resources.
    public func endSession() {
        guard isSessionActive else { return }
        temporalProcessor?.endSession()
        spatialProcessor1?.endSession()
        spatialProcessor2?.endSession()
        
        temporalProcessor = nil
        spatialProcessor1 = nil
        spatialProcessor2 = nil
        
        temporalPool = nil
        spatialPool1 = nil
        spatialPool2 = nil
        
        previousSourceFrame = nil
        previousOutputFrame = nil
        isSessionActive = false
        isFirstFrame = true
    }
}
