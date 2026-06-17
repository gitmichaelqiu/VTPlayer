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
    
    private let processor = VTFrameProcessor()
    private var isSessionActive = false
    
    // Configuration options
    public let enableSuperResolution: Bool
    public let enableFrameInterpolation: Bool
    
    // Configured dimensions
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var targetWidth = 0
    private var targetHeight = 0
    
    // Memory pools
    private var destinationPool: CVPixelBufferPool?
    
    // State tracking
    private var previousSourceFrame: VTFrameProcessorFrame?
    private var previousOutputFrame: VTFrameProcessorFrame?
    private var isFirstFrame = true
    
    public init(enableSuperResolution: Bool, enableFrameInterpolation: Bool) {
        self.enableSuperResolution = enableSuperResolution
        self.enableFrameInterpolation = enableFrameInterpolation
    }
    
    /// Starts the processing session for the given input dimensions.
    /// - Parameters:
    ///   - width: Width of the source frames.
    ///   - height: Height of the source frames.
    public func startSession(width: Int, height: Int) throws {
        guard !isSessionActive else { return }
        
        self.sourceWidth = width
        self.self.sourceHeight = height
        
        let config: any VTFrameProcessorConfiguration
        
        if enableSuperResolution && enableFrameInterpolation {
            // Combined spatial (2x) and temporal (1 frame interpolation) scaling
            self.targetWidth = width * 2
            self.targetHeight = height * 2
            guard let combinedConfig = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                spatialScaleFactor: 2
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize low latency frame interpolation configuration with spatial scaling"])
            }
            config = combinedConfig
        } else if enableFrameInterpolation {
            // Pure temporal frame interpolation (1x size, 2x frame rate)
            self.targetWidth = width
            self.targetHeight = height
            guard let interpolationConfig = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                numberOfInterpolatedFrames: 1
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize low latency frame interpolation configuration"])
            }
            config = interpolationConfig
        } else if enableSuperResolution {
            // Pure spatial super resolution upscaling (2x size, 1x frame rate)
            self.targetWidth = width * 2
            self.targetHeight = height * 2
            guard let srConfig = VTSuperResolutionScalerConfiguration(
                frameWidth: width,
                frameHeight: height,
                scaleFactor: 2,
                inputType: .video,
                usePrecomputedFlow: false,
                qualityPrioritization: .normal,
                revision: .revision1
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize super resolution configuration"])
            }
            config = srConfig
        } else {
            // Bypassed (no processing)
            self.targetWidth = width
            self.targetHeight = height
            return
        }
        
        // Try starting the session on the processor
        try processor.startSession(configuration: config)
        
        // Create destination pixel buffer pool matching the processor's output requirements
        let destAttributes = config.destinationPixelBufferAttributes
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 15
        ]
        
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            destAttributes as CFDictionary,
            &pool
        )
        guard poolStatus == kCVReturnSuccess, let createdPool = pool else {
            processor.endSession()
            throw NSError(domain: "VTFrameProcessorCoordinator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination CVPixelBufferPool"])
        }
        
        self.destinationPool = createdPool
        self.isSessionActive = true
        self.isFirstFrame = true
        self.previousSourceFrame = nil
        self.previousOutputFrame = nil
    }
    
    /// Processes a single incoming frame and returns a sequence of processed frames.
    /// - Parameter frame: The source frame.
    /// - Returns: An array of processed frames (can be empty, 1, or 2 frames depending on configuration).
    public func processFrame(_ frame: VTFrame) async throws -> [VTFrame] {
        // If bypassed, return the frame directly
        guard isSessionActive, let pool = destinationPool else {
            return [frame]
        }
        
        let sourcePTS = frame.presentationTimeStamp
        guard let sourceFPFrame = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: sourcePTS) else {
            throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create source VTFrameProcessorFrame"])
        }
        
        if enableFrameInterpolation {
            // Temporal Interpolation is active (either combined or pure temporal)
            let midPTS: CMTime
            let prevFPFrame: VTFrameProcessorFrame
            
            if isFirstFrame {
                // For the very first frame, we don't have a previous frame to interpolate with.
                // We create a dummy previous reference frame using the first frame buffer with a small time offset.
                let offsetTime = CMTimeSubtract(sourcePTS, CMTime(value: 1, timescale: 30))
                midPTS = CMTimeSubtract(sourcePTS, CMTime(value: 1, timescale: 60))
                guard let dummyPrev = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: offsetTime) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create dummy previous VTFrameProcessorFrame"])
                }
                prevFPFrame = dummyPrev
            } else {
                guard let lastSource = previousSourceFrame else {
                    return []
                }
                prevFPFrame = lastSource
                // Midpoint timestamp
                midPTS = CMTimeAdd(prevFPFrame.presentationTimeStamp, CMTimeMultiplyByFloat64(CMTimeSubtract(sourcePTS, prevFPFrame.presentationTimeStamp), multiplier: 0.5))
            }
            
            if enableSuperResolution {
                // Combined: 2x upscaling + 2x frame rate
                // Allocate 2 buffers from pool: one for interpolated, one for upscaled source
                var buf1: CVPixelBuffer?
                var buf2: CVPixelBuffer?
                
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf1) == kCVReturnSuccess, let outBuf1 = buf1 else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferPool allocation failed for interpolated frame"])
                }
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf2) == kCVReturnSuccess, let outBuf2 = buf2 else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferPool allocation failed for upscaled source frame"])
                }
                
                guard let destFrame1 = VTFrameProcessorFrame(buffer: outBuf1, presentationTimeStamp: midPTS),
                      let destFrame2 = VTFrameProcessorFrame(buffer: outBuf2, presentationTimeStamp: sourcePTS) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination VTFrameProcessorFrames"])
                }
                
                guard let params = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: sourceFPFrame,
                    previousFrame: prevFPFrame,
                    interpolationPhase: [0.5] as [Float],
                    destinationFrames: [destFrame1, destFrame2]
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize low-latency interpolation parameters"])
                }
                
                _ = try await processor.process(parameters: params)
                
                // Keep track of the state
                self.previousSourceFrame = sourceFPFrame
                self.isFirstFrame = false
                
                return [
                    VTFrame(buffer: outBuf1, presentationTimeStamp: midPTS),
                    VTFrame(buffer: outBuf2, presentationTimeStamp: sourcePTS)
                ]
            } else {
                // Pure Temporal Interpolation: 1x size, 2x frame rate
                var buf1: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf1) == kCVReturnSuccess, let outBuf1 = buf1 else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferPool allocation failed for interpolated frame"])
                }
                
                guard let destFrame1 = VTFrameProcessorFrame(buffer: outBuf1, presentationTimeStamp: midPTS) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination VTFrameProcessorFrame"])
                }
                
                guard let params = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: sourceFPFrame,
                    previousFrame: prevFPFrame,
                    interpolationPhase: [0.5] as [Float],
                    destinationFrames: [destFrame1]
                ) else {
                    throw NSError(domain: "VTFrameProcessorCoordinator", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize low-latency interpolation parameters"])
                }
                
                _ = try await processor.process(parameters: params)
                
                self.previousSourceFrame = sourceFPFrame
                self.isFirstFrame = false
                
                return [
                    VTFrame(buffer: outBuf1, presentationTimeStamp: midPTS),
                    frame // Source frame itself remains unchanged
                ]
            }
        } else {
            // Pure Super Resolution (2x scaling, 1x frame rate)
            var buf: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf) == kCVReturnSuccess, let outBuf = buf else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferPool allocation failed for upscaled frame"])
            }
            
            guard let destFrame = VTFrameProcessorFrame(buffer: outBuf, presentationTimeStamp: sourcePTS) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination VTFrameProcessorFrame"])
            }
            
            guard let params = VTSuperResolutionScalerParameters(
                sourceFrame: sourceFPFrame,
                previousFrame: previousSourceFrame,
                previousOutputFrame: previousOutputFrame,
                opticalFlow: nil,
                submissionMode: isFirstFrame ? .random : .sequential,
                destinationFrame: destFrame
            ) else {
                throw NSError(domain: "VTFrameProcessorCoordinator", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize super-resolution parameters"])
            }
            
            _ = try await processor.process(parameters: params)
            
            self.previousSourceFrame = sourceFPFrame
            self.previousOutputFrame = destFrame
            self.isFirstFrame = false
            
            return [
                VTFrame(buffer: outBuf, presentationTimeStamp: sourcePTS)
            ]
        }
    }
    
    /// Ends the processing session and cleans up resources.
    public func endSession() {
        guard isSessionActive else { return }
        processor.endSession()
        destinationPool = nil
        previousSourceFrame = nil
        previousOutputFrame = nil
        isSessionActive = false
        isFirstFrame = true
    }
}
