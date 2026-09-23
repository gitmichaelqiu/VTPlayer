import AVFoundation
import CoreMedia
@preconcurrency import CoreVideo
import CryptoKit
import Foundation
import VideoToolbox

nonisolated struct EnhancedFrameCacheEncodedFrame: Sendable {
    let groupIndex: Int
    let frame: VTFrame
}

nonisolated struct EnhancedFrameCacheEncodedFrameMetadata: Codable, Equatable, Sendable {
    let groupIndex: Int
    let pixelFormat: UInt32
    let width: Int
    let height: Int
    let presentationTimeValue: Int64
    let presentationTimeScale: Int32
    let presentationTimeFlags: UInt32
    let presentationTimeEpoch: Int64
    let isInterpolated: Bool
    let attachmentIdentifier: String?

    var presentationTime: CMTime {
        CMTime(
            value: presentationTimeValue,
            timescale: presentationTimeScale,
            flags: CMTimeFlags(rawValue: presentationTimeFlags),
            epoch: presentationTimeEpoch
        )
    }
}

nonisolated struct EnhancedFrameCacheEncodedChunk: Codable, Equatable, Sendable {
    let chunkIndex: Int
    let filename: String
    let codec: String
    let profile: String
    let averageBitRate: Int
    let expectedFrameRate: Int
    let maximumKeyFrameInterval: Int
    let closedGOP: Bool
    let startsWithSyncSample: Bool
    let allowsFrameReordering: Bool
    var sourceGroupCount: Int
    let firstGroupIndex: Int
    let lastGroupIndex: Int
    let byteCount: Int64
    let sha256: String
    let attachmentTable: [String: Data]
    let frames: [EnhancedFrameCacheEncodedFrameMetadata]

    var groupIndices: Set<Int> {
        Set(frames.map(\.groupIndex))
    }
}

nonisolated struct EnhancedFrameCacheDecodedChunk: Sendable {
    let metadata: EnhancedFrameCacheEncodedChunk
    let frames: [VTFrame]
    let sourceGroupCount: Int
}

nonisolated private final class EnhancedFrameChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [VTFrame] = []

    func append(_ frame: VTFrame) {
        lock.lock()
        defer { lock.unlock() }
        frames.append(frame)
    }

    func snapshot() -> [VTFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}

/// Writes one independently decodable HEVC movie. Every cache chunk has its
/// own encoder session and starts at a sync sample, so no reference crosses a
/// chunk boundary. Frame timestamps and renderer metadata remain in the
/// manifest at their original rational CMTime values.
actor EnhancedFrameHEVCChunkWriter {
    private let outputURL: URL
    private let chunkIndex: Int
    private let averageBitRate: Int
    private let expectedFrameRate: Int
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var firstGroupIndex: Int?
    private var lastGroupIndex: Int?
    private var frameMetadata: [EnhancedFrameCacheEncodedFrameMetadata] = []
    private var attachmentTable: [String: Data] = [:]
    private var profileName = "HEVC Main"
    private var isFinished = false

    init(outputURL: URL, chunkIndex: Int, averageBitRate: Int, expectedFrameRate: Int) {
        self.outputURL = outputURL
        self.chunkIndex = chunkIndex
        self.averageBitRate = averageBitRate
        self.expectedFrameRate = max(1, expectedFrameRate)
    }

    func append(_ cachedFrame: EnhancedFrameCacheEncodedFrame) async throws {
        try Task.checkCancellation()
        let frame = cachedFrame.frame
        let pixelBuffer = frame.buffer
        let presentationTime = frame.presentationTimeStamp
        guard presentationTime.isValid, presentationTime.isNumeric,
              CVPixelBufferGetWidth(pixelBuffer) > 0,
              CVPixelBufferGetHeight(pixelBuffer) > 0 else {
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }

        if let lastPresentationTime,
           CMTimeCompare(lastPresentationTime, presentationTime) >= 0 {
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }
        if writer == nil {
            try startWriter(for: pixelBuffer, at: presentationTime)
        }
        guard let startTime, let input, let adaptor else {
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }

        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer?.status == .writing else {
                NSLog("CACHE: HEVC writer left writing state before append: %@", writer?.error?.localizedDescription ?? "unknown encoder error")
                throw writer?.error ?? EnhancedFrameDiskCacheError.invalidFrameData
            }
            try await Task.sleep(for: .milliseconds(2))
        }

        let relativeTime = CMTimeSubtract(presentationTime, startTime)
        guard relativeTime.isValid, relativeTime >= .zero else {
            NSLog("CACHE: invalid HEVC chunk-relative timestamp original=%@ start=%@", String(describing: presentationTime), String(describing: startTime))
            throw writer?.error ?? EnhancedFrameDiskCacheError.invalidFrameData
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: relativeTime) else {
            NSLog("CACHE: HEVC writer rejected a frame: %@", writer?.error?.localizedDescription ?? "unknown encoder error")
            throw writer?.error ?? EnhancedFrameDiskCacheError.invalidFrameData
        }

        let attachmentData = try Self.encodedAttachments(for: pixelBuffer)
        let attachmentIdentifier = attachmentData.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        if let attachmentData, let attachmentIdentifier {
            attachmentTable[attachmentIdentifier] = attachmentData
        }
        frameMetadata.append(EnhancedFrameCacheEncodedFrameMetadata(
            groupIndex: cachedFrame.groupIndex,
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            presentationTimeValue: presentationTime.value,
            presentationTimeScale: presentationTime.timescale,
            presentationTimeFlags: presentationTime.flags.rawValue,
            presentationTimeEpoch: presentationTime.epoch,
            isInterpolated: frame.isInterpolated,
            attachmentIdentifier: attachmentIdentifier
        ))
        firstGroupIndex = min(firstGroupIndex ?? cachedFrame.groupIndex, cachedFrame.groupIndex)
        lastGroupIndex = max(lastGroupIndex ?? cachedFrame.groupIndex, cachedFrame.groupIndex)
        lastPresentationTime = presentationTime
    }

    func finish() async throws -> EnhancedFrameCacheEncodedChunk {
        guard !isFinished, let writer, !frameMetadata.isEmpty,
              let firstGroupIndex, let lastGroupIndex else {
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }
        isFinished = true
        input?.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? EnhancedFrameDiskCacheError.invalidFrameData
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else { throw EnhancedFrameDiskCacheError.invalidFrameData }
        guard try await Self.firstSampleIsSync(in: outputURL) else {
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }
        let fileData = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        return EnhancedFrameCacheEncodedChunk(
            chunkIndex: chunkIndex,
            filename: outputURL.lastPathComponent,
            codec: "HEVC",
            profile: profileName,
            averageBitRate: averageBitRate,
            expectedFrameRate: expectedFrameRate,
            maximumKeyFrameInterval: max(1, expectedFrameRate / 2),
            closedGOP: true,
            startsWithSyncSample: true,
            allowsFrameReordering: false,
            sourceGroupCount: 0,
            firstGroupIndex: firstGroupIndex,
            lastGroupIndex: lastGroupIndex,
            byteCount: byteCount,
            sha256: digest,
            attachmentTable: attachmentTable,
            frames: frameMetadata
        )
    }

    func cancel() {
        writer?.cancelWriting()
        writer = nil
        input = nil
        adaptor = nil
        isFinished = true
        try? FileManager.default.removeItem(at: outputURL)
    }

    nonisolated static func read(
        chunk: EnhancedFrameCacheEncodedChunk,
        from url: URL
    ) async throws -> [VTFrame] {
        let collector = EnhancedFrameChunkCollector()
        _ = try await read(chunk: chunk, from: url) { frame in
            collector.append(frame)
        }
        return collector.snapshot()
    }

    nonisolated static func read(
        chunk: EnhancedFrameCacheEncodedChunk,
        from url: URL,
        consumeFrame: @escaping @Sendable (VTFrame) async throws -> Void
    ) async throws -> Int {
        let fileData = try Data(contentsOf: url, options: [.mappedIfSafe])
        let actualDigest = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == chunk.sha256,
              chunk.codec == "HEVC",
              chunk.closedGOP,
              chunk.startsWithSyncSample,
              !chunk.allowsFrameReordering,
              !chunk.frames.isEmpty else {
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }
        guard chunk.frames.allSatisfy({ frame in
            guard let identifier = frame.attachmentIdentifier else { return true }
            return chunk.attachmentTable[identifier] != nil
        }) else {
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }
        let reader = try AVAssetReader(asset: asset)
        let pixelFormat = chunk.frames[0].pixelFormat
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EnhancedFrameDiskCacheError.invalidFrameData }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? EnhancedFrameDiskCacheError.invalidFrameData
        }

        var frameIndex = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard frameIndex < chunk.frames.count,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                reader.cancelReading()
                throw EnhancedFrameDiskCacheError.invalidFrameData
            }
            let metadata = chunk.frames[frameIndex]
            guard CVPixelBufferGetWidth(imageBuffer) == metadata.width,
                  CVPixelBufferGetHeight(imageBuffer) == metadata.height else {
                reader.cancelReading()
                throw EnhancedFrameDiskCacheError.invalidFrameData
            }
            let attachmentData = metadata.attachmentIdentifier.flatMap { chunk.attachmentTable[$0] }
            try applyAttachments(attachmentData, to: imageBuffer)
            let expectedColorMetadata = Self.colorMetadata(from: attachmentData)
            if !expectedColorMetadata.isEmpty {
                let actualColorMetadata = Self.colorMetadata(from: imageBuffer)
                let metadataMatches = expectedColorMetadata.allSatisfy { key, expectedValue in
                    guard let actualValue = actualColorMetadata[key] else { return false }
                    return (actualValue as AnyObject).isEqual(expectedValue)
                }
                guard metadataMatches else {
                    reader.cancelReading()
                    throw EnhancedFrameDiskCacheError.invalidFrameData
                }
            }
            try await consumeFrame(VTFrame(
                buffer: imageBuffer,
                presentationTimeStamp: metadata.presentationTime,
                isInterpolated: metadata.isInterpolated
            ))
            frameIndex += 1
        }
        guard reader.status == .completed, frameIndex == chunk.frames.count else {
            throw reader.error ?? EnhancedFrameDiskCacheError.invalidFrameData
        }
        return frameIndex
    }

    private func startWriter(for pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isTenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let profile: CFString = isTenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        profileName = isTenBit ? "HEVC Main 10 AutoLevel" : "HEVC Main AutoLevel"
        let colorProperties = Self.colorProperties(for: pixelBuffer)
        let hardLimitBytesPerSecond = max(1, Int((Double(averageBitRate) * 1.5 / 8).rounded(.up)))
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: averageBitRate,
            AVVideoProfileLevelKey: profile,
            AVVideoExpectedSourceFrameRateKey: expectedFrameRate,
            AVVideoMaxKeyFrameIntervalKey: max(1, expectedFrameRate / 2),
            AVVideoAllowFrameReorderingKey: false,
            kVTCompressionPropertyKey_DataRateLimits as String: [
                NSNumber(value: hardLimitBytesPerSecond),
                NSNumber(value: 1)
            ]
        ]
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        if !colorProperties.isEmpty {
            videoSettings[AVVideoColorPropertiesKey] = colorProperties
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(input) else {
            NSLog("CACHE: AVAssetWriter rejected the HEVC video input configuration")
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }
        writer.add(input)
        guard writer.startWriting() else {
            NSLog("CACHE: AVAssetWriter failed to start: %@", writer.error?.localizedDescription ?? "unknown encoder error")
            throw writer.error ?? EnhancedFrameDiskCacheError.invalidFrameData
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.startTime = presentationTime
    }

    private nonisolated static func colorProperties(for pixelBuffer: CVPixelBuffer) -> [String: Any] {
        let mappings: [(CFString, String)] = [
            (kCVImageBufferColorPrimariesKey, AVVideoColorPrimariesKey),
            (kCVImageBufferTransferFunctionKey, AVVideoTransferFunctionKey),
            (kCVImageBufferYCbCrMatrixKey, AVVideoYCbCrMatrixKey)
        ]
        let properties = mappings.reduce(into: [String: Any]()) { result, mapping in
            if let value = CVBufferCopyAttachment(pixelBuffer, mapping.0, nil) {
                result[mapping.1] = value
            }
        }
        // AVAssetWriter requires a complete color triplet. Per-frame
        // attachments are persisted separately and restored after decode, so
        // incomplete source metadata must not be promoted to track metadata.
        return properties.count == mappings.count ? properties : [:]
    }

    private nonisolated static func firstSampleIsSync(in url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return false }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer() else { return false }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        return !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private nonisolated static func encodedAttachments(for buffer: CVPixelBuffer) throws -> Data? {
        let colorMetadata = colorMetadata(from: buffer)
        guard !colorMetadata.isEmpty else {
            return nil
        }
        // CoreVideo can attach non-property-list objects such as CGColorSpace
        // alongside the renderer-relevant color values. Persist only the
        // stable HDR/color signaling fields; encoding unrelated attachments
        // would reject otherwise valid frames or serialize implementation
        // details that AVAssetReader cannot round-trip.
        let attachments = colorMetadata
        guard PropertyListSerialization.propertyList(attachments, isValidFor: .binary) else {
            NSLog("CACHE: unsupported HEVC color attachment values: %@", attachments.keys.sorted().joined(separator: ","))
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }
        return try PropertyListSerialization.data(
            fromPropertyList: attachments,
            format: .binary,
            options: 0
        )
    }

    private nonisolated static func applyAttachments(_ data: Data?, to buffer: CVPixelBuffer) throws {
        guard let data else { return }
        guard let attachments = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw EnhancedFrameDiskCacheError.invalidFrameData
        }
        for (key, value) in attachments {
            CVBufferSetAttachment(buffer, key as CFString, value as CFTypeRef, .shouldPropagate)
        }
    }

    private nonisolated static func colorMetadata(from buffer: CVPixelBuffer) -> [String: Any] {
        let keys = colorAttachmentKeys()
        return keys.reduce(into: [String: Any]()) { result, key in
            if let value = CVBufferCopyAttachment(buffer, key, nil) {
                result[key as String] = value
            }
        }
    }

    private nonisolated static func colorMetadata(from data: Data?) -> [String: Any] {
        guard let data,
              let attachments = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        let keys = Set(colorAttachmentKeys().map { $0 as String })
        return attachments.filter { keys.contains($0.key) }
    }

    private nonisolated static func colorAttachmentKeys() -> [CFString] {
        [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferGammaLevelKey,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            kCVImageBufferContentLightLevelInfoKey
        ]
    }
}
