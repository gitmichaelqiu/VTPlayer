//
//  VTFramePipeline.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import Foundation
import AVFoundation
import CoreVideo
import CoreMedia

/// A frame representation wrapping the pixel buffer and its presentation timestamp.
nonisolated public struct VTFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public let presentationTimeStamp: CMTime
    public let isInterpolated: Bool
    
    public init(buffer: CVPixelBuffer, presentationTimeStamp: CMTime, isInterpolated: Bool = false) {
        self.buffer = buffer
        self.presentationTimeStamp = presentationTimeStamp
        self.isInterpolated = isInterpolated
    }
}

/// An asynchronous sequence of video frames providing backpressure and seeking support.
public struct VTFrameSequence: AsyncSequence, Sendable {
    public typealias Element = VTFrame
    
    private let url: URL
    private let startTime: CMTime
    private let outputSize: CGSize?
    private let extendedPixelsRight: Int
    private let extendedPixelsBottom: Int
    
    public init(
        url: URL,
        startTime: CMTime = .zero,
        outputSize: CGSize? = nil,
        extendedPixelsRight: Int = 0,
        extendedPixelsBottom: Int = 0
    ) {
        self.url = url
        self.startTime = startTime
        self.outputSize = outputSize
        self.extendedPixelsRight = extendedPixelsRight
        self.extendedPixelsBottom = extendedPixelsBottom
    }
    
    public func makeAsyncIterator() -> Iterator {
        return Iterator(
            url: url,
            startTime: startTime,
            outputSize: outputSize,
            extendedPixelsRight: extendedPixelsRight,
            extendedPixelsBottom: extendedPixelsBottom
        )
    }
    
    /// Thread-safe class-based iterator conforming to AsyncIteratorProtocol.
    public final class Iterator: AsyncIteratorProtocol, Sendable {
        private let url: URL
        private let startTime: CMTime
        private let outputSize: CGSize?
        private let extendedPixelsRight: Int
        private let extendedPixelsBottom: Int
        private let state = StateLock()
        
        init(
            url: URL,
            startTime: CMTime,
            outputSize: CGSize?,
            extendedPixelsRight: Int,
            extendedPixelsBottom: Int
        ) {
            self.url = url
            self.startTime = startTime
            self.outputSize = outputSize
            self.extendedPixelsRight = extendedPixelsRight
            self.extendedPixelsBottom = extendedPixelsBottom
        }
        
        public func next() async throws -> VTFrame? {
            return try await state.next(
                url: url,
                startTime: startTime,
                outputSize: outputSize,
                extendedPixelsRight: extendedPixelsRight,
                extendedPixelsBottom: extendedPixelsBottom
            )
        }
        
        /// Actor to encapsulate state and run reader initialization on background threads.
        private actor StateLock {
            private var reader: AVAssetReader?
            private var trackOutput: AVAssetReaderTrackOutput?
            private var sourceColorAttachments: [(CFString, CFPropertyList)] = []
            private var isInitialized = false
            
            func next(
                url: URL,
                startTime: CMTime,
                outputSize: CGSize?,
                extendedPixelsRight: Int,
                extendedPixelsBottom: Int
            ) async throws -> VTFrame? {
                if !isInitialized {
                    let asset = AVURLAsset(url: url)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard let videoTrack = tracks.first else {
                        isInitialized = true
                        return nil
                    }

                    // AVAssetReader does not consistently copy the color
                    // extensions from the track format description onto each
                    // decoded pixel buffer. Preserve them here so the first
                    // frame of a newly-started FI pipeline is presented with
                    // the same transfer function and matrix as native AVPlayer.
                    if let formatDescription = try await videoTrack.load(.formatDescriptions).first {
                        let colorKeys: [(CFString, CFString)] = [
                            (kCVImageBufferColorPrimariesKey, kCMFormatDescriptionExtension_ColorPrimaries),
                            (kCVImageBufferTransferFunctionKey, kCMFormatDescriptionExtension_TransferFunction),
                            (kCVImageBufferYCbCrMatrixKey, kCMFormatDescriptionExtension_YCbCrMatrix)
                        ]
                        sourceColorAttachments = colorKeys.compactMap { pixelBufferKey, extensionKey in
                            guard let value = CMFormatDescriptionGetExtension(
                                formatDescription,
                                extensionKey: extensionKey
                            ) else {
                                return nil
                            }
                            return (pixelBufferKey, value)
                        }
                    }
                    
                    let reader = try AVAssetReader(asset: asset)
                    
                    // If seeked, configure starting time range
                    if startTime > .zero {
                        let duration = try await asset.load(.duration)
                        let remaining = CMTimeSubtract(duration, startTime)
                        if remaining > .zero {
                            reader.timeRange = CMTimeRange(start: startTime, duration: remaining)
                        } else {
                            reader.timeRange = CMTimeRange(start: startTime, duration: CMTime(value: 1, timescale: 100))
                        }
                    }
                    
                    var outputSettings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                    ]
                    if let outputSize {
                        outputSettings[kCVPixelBufferWidthKey as String] = Int(outputSize.width)
                        outputSettings[kCVPixelBufferHeightKey as String] = Int(outputSize.height)
                    }
                    if extendedPixelsRight > 0 {
                        outputSettings[kCVPixelBufferExtendedPixelsRightKey as String] = extendedPixelsRight
                    }
                    if extendedPixelsBottom > 0 {
                        outputSettings[kCVPixelBufferExtendedPixelsBottomKey as String] = extendedPixelsBottom
                    }
                    let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
                    trackOutput.alwaysCopiesSampleData = false
                    
                    guard reader.canAdd(trackOutput) else {
                        isInitialized = true
                        return nil
                    }
                    reader.add(trackOutput)
                    
                    guard reader.startReading() else {
                        isInitialized = true
                        return nil
                    }
                    
                    self.reader = reader
                    self.trackOutput = trackOutput
                    self.isInitialized = true
                }
                
                guard let reader = reader, let trackOutput = trackOutput else {
                    return nil
                }
                
                if reader.status == .reading {
                    return autoreleasepool { () -> VTFrame? in
                        guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                            return nil
                        }
                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                            return nil
                        }
                        for (key, value) in sourceColorAttachments {
                            CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
                        }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        return VTFrame(buffer: pixelBuffer, presentationTimeStamp: pts)
                    }
                } else {
                    return nil
                }
            }
        }
    }
}

/// A pipeline responsible for reading and decompressing video tracks asynchronously.
public final class VTFramePipeline: Sendable {
    
    public init() {}
    
    /// Starts reading frames from the specified video file URL as an asynchronous sequence.
    /// - Parameters:
    ///   - url: The local URL of the video file.
    ///   - startTime: The time location to start reading from.
    /// - Returns: A VTFrameSequence yielding VTFrame objects.
    public func readFrames(from url: URL, startTime: CMTime = .zero) -> VTFrameSequence {
        return VTFrameSequence(url: url, startTime: startTime)
    }
}
