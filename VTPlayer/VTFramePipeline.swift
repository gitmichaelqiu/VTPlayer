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
public struct VTFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public let presentationTimeStamp: CMTime
    
    public init(buffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        self.buffer = buffer
        self.presentationTimeStamp = presentationTimeStamp
    }
}

/// A pipeline responsible for reading and decompressing video tracks asynchronously.
public final class VTFramePipeline: Sendable {
    
    public init() {}
    
    /// Starts reading frames from the specified video file URL as an asynchronous stream.
    /// - Parameter url: The local URL of the video file.
    /// - Returns: An AsyncStream yielding VTFrame objects.
    public func readFrames(from url: URL) -> AsyncStream<VTFrame> {
        AsyncStream { continuation in
            let asset = AVAsset(url: url)
            
            Task {
                do {
                    // Swift 6 asynchronous loading of tracks
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard let videoTrack = tracks.first else {
                        continuation.finish()
                        return
                    }
                    
                    let reader = try AVAssetReader(asset: asset)
                    
                    // Request NV12 pixel format (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                    let outputSettings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ]
                    
                    let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
                    trackOutput.alwaysCopiesSampleData = false
                    
                    guard reader.canAdd(trackOutput) else {
                        continuation.finish()
                        return
                    }
                    reader.add(trackOutput)
                    
                    guard reader.startReading() else {
                        continuation.finish()
                        return
                    }
                    
                    continuation.onTermination = { _ in
                        if reader.status == .reading {
                            reader.cancelReading()
                        }
                    }
                    
                    // Processing loop on background queue
                    while reader.status == .reading {
                        autoreleasepool {
                            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                                return
                            }
                            
                            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                                return
                            }
                            
                            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                            let frame = VTFrame(buffer: pixelBuffer, presentationTimeStamp: pts)
                            
                            // Yield to stream with backpressure support
                            let result = continuation.yield(frame)
                            if case .terminated = result {
                                reader.cancelReading()
                            }
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    print("Error loading or reading asset: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }
}
