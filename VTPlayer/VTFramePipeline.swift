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
    
    public init(buffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        self.buffer = buffer
        self.presentationTimeStamp = presentationTimeStamp
    }
}

/// An asynchronous sequence of video frames providing backpressure support.
public struct VTFrameSequence: AsyncSequence, Sendable {
    public typealias Element = VTFrame
    
    private let url: URL
    
    public init(url: URL) {
        self.url = url
    }
    
    public func makeAsyncIterator() -> Iterator {
        return Iterator(url: url)
    }
    
    /// Thread-safe class-based iterator conforming to AsyncIteratorProtocol.
    public final class Iterator: AsyncIteratorProtocol, Sendable {
        private let url: URL
        private let state = StateLock()
        
        init(url: URL) {
            self.url = url
        }
        
        public func next() async throws -> VTFrame? {
            return try await state.next(url: url)
        }
        
        /// Actor to encapsulate state and run reader initialization on background threads.
        private actor StateLock {
            private var reader: AVAssetReader?
            private var trackOutput: AVAssetReaderTrackOutput?
            private var isInitialized = false
            
            func next(url: URL) async throws -> VTFrame? {
                if !isInitialized {
                    let asset = AVURLAsset(url: url)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard let videoTrack = tracks.first else {
                        isInitialized = true
                        return nil
                    }
                    
                    let reader = try AVAssetReader(asset: asset)
                    let outputSettings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ]
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
    /// - Parameter url: The local URL of the video file.
    /// - Returns: A VTFrameSequence yielding VTFrame objects.
    public func readFrames(from url: URL) -> VTFrameSequence {
        return VTFrameSequence(url: url)
    }
}
