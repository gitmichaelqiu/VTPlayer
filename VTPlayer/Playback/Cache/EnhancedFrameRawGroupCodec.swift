import Foundation
import CoreMedia
@preconcurrency import CoreVideo

nonisolated enum EnhancedFrameRawGroupCodec {
    private struct GroupHeader: Codable {
        var frames: [FrameHeader]
    }

    private struct FrameHeader: Codable {
        var pixelFormat: UInt32
        var width: Int
        var height: Int
        var planes: [Plane]
        var presentationTimeValue: Int64
        var presentationTimeScale: Int32
        var presentationTimeFlags: UInt32
        var presentationTimeEpoch: Int64
        var isInterpolated: Bool
        var attachmentData: Data?
    }

    private struct Plane: Codable {
        var bytesPerRow: Int
        var height: Int
        var byteCount: Int
    }

    static func encode(_ frames: [VTFrame]) throws -> Data {
        var headers: [FrameHeader] = []
        var payloads: [Data] = []
        for frame in frames {
            let buffer = frame.buffer
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let planeCount = CVPixelBufferGetPlaneCount(buffer)
            let planeIndices = planeCount == 0 ? [nil] : (0..<planeCount).map(Optional.some)
            var planes: [Plane] = []
            for plane in planeIndices {
                let baseAddress = plane.map { CVPixelBufferGetBaseAddressOfPlane(buffer, $0) } ?? CVPixelBufferGetBaseAddress(buffer)
                let bytesPerRow = plane.map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) } ?? CVPixelBufferGetBytesPerRow(buffer)
                let height = plane.map { CVPixelBufferGetHeightOfPlane(buffer, $0) } ?? CVPixelBufferGetHeight(buffer)
                guard let baseAddress, bytesPerRow > 0, height > 0 else {
                    throw EnhancedFrameDiskCacheError.invalidFrameData
                }
                let byteCount = bytesPerRow * height
                planes.append(Plane(bytesPerRow: bytesPerRow, height: height, byteCount: byteCount))
                payloads.append(Data(bytes: baseAddress, count: byteCount))
            }
            let time = frame.presentationTimeStamp
            headers.append(FrameHeader(
                pixelFormat: CVPixelBufferGetPixelFormatType(buffer),
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                planes: planes,
                presentationTimeValue: time.value,
                presentationTimeScale: time.timescale,
                presentationTimeFlags: time.flags.rawValue,
                presentationTimeEpoch: time.epoch,
                isInterpolated: frame.isInterpolated,
                attachmentData: encodedAttachments(for: buffer)
            ))
        }
        let headerData = try JSONEncoder().encode(GroupHeader(frames: headers))
        var data = Data()
        var headerLength = UInt64(headerData.count).bigEndian
        data.append(Data(bytes: &headerLength, count: MemoryLayout<UInt64>.size))
        data.append(headerData)
        for payload in payloads { data.append(payload) }
        return data
    }

    static func decode(_ data: Data, maximumFrameCount: Int?) throws -> [VTFrame] {
        guard data.count >= MemoryLayout<UInt64>.size else { throw EnhancedFrameDiskCacheError.invalidFrameData }
        let headerLength = data.prefix(MemoryLayout<UInt64>.size).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let headerStart = MemoryLayout<UInt64>.size
        let headerEnd = headerStart + Int(headerLength)
        guard headerEnd <= data.count else { throw EnhancedFrameDiskCacheError.invalidFrameData }
        let header = try JSONDecoder().decode(GroupHeader.self, from: data[headerStart..<headerEnd])
        let selectedIndices = selectedFrameIndices(
            totalCount: header.frames.count,
            maximumFrameCount: maximumFrameCount
        )
        var payloadOffset = headerEnd
        var frames: [VTFrame] = []
        frames.reserveCapacity(selectedIndices.count)
        for (frameIndex, frameHeader) in header.frames.enumerated() {
            let framePayloadOffset = payloadOffset
            let framePayloadByteCount = frameHeader.planes.reduce(0) { $0 + $1.byteCount }
            payloadOffset += framePayloadByteCount
            guard payloadOffset <= data.count else {
                throw EnhancedFrameDiskCacheError.invalidFrameData
            }
            guard selectedIndices.contains(frameIndex) else { continue }
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: frameHeader.width,
                kCVPixelBufferHeightKey: frameHeader.height,
                kCVPixelBufferPixelFormatTypeKey: frameHeader.pixelFormat,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, frameHeader.width, frameHeader.height, frameHeader.pixelFormat, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
                  let buffer else { throw EnhancedFrameDiskCacheError.invalidFrameData }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let planeCount = CVPixelBufferGetPlaneCount(buffer)
            guard (planeCount == 0 && frameHeader.planes.count == 1) || planeCount == frameHeader.planes.count else {
                throw EnhancedFrameDiskCacheError.invalidFrameData
            }
            var planePayloadOffset = framePayloadOffset
            for (index, plane) in frameHeader.planes.enumerated() {
                let destinationBytesPerRow = planeCount == 0 ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
                let destinationHeight = planeCount == 0 ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, index)
                guard destinationBytesPerRow >= plane.bytesPerRow, destinationHeight >= plane.height,
                      planePayloadOffset + plane.byteCount <= data.count else {
                    throw EnhancedFrameDiskCacheError.invalidFrameData
                }
                let destination = planeCount == 0 ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, index)
                guard let destination else { throw EnhancedFrameDiskCacheError.invalidFrameData }
                data.withUnsafeBytes { source in
                    for row in 0..<plane.height {
                        memcpy(
                            destination.advanced(by: row * destinationBytesPerRow),
                            source.baseAddress!.advanced(by: planePayloadOffset + row * plane.bytesPerRow),
                            plane.bytesPerRow
                        )
                    }
                }
                planePayloadOffset += plane.byteCount
            }
            applyAttachments(frameHeader.attachmentData, to: buffer)
            let time = CMTime(
                value: frameHeader.presentationTimeValue,
                timescale: frameHeader.presentationTimeScale,
                flags: CMTimeFlags(rawValue: frameHeader.presentationTimeFlags),
                epoch: frameHeader.presentationTimeEpoch
            )
            frames.append(VTFrame(buffer: buffer, presentationTimeStamp: time, isInterpolated: frameHeader.isInterpolated))
        }
        return frames
    }

    private static func selectedFrameIndices(totalCount: Int, maximumFrameCount: Int?) -> Set<Int> {
        guard let maximumFrameCount,
              maximumFrameCount > 0,
              maximumFrameCount < totalCount else {
            return Set(0..<totalCount)
        }
        return Set((0..<maximumFrameCount).map { index in
            (2 * index + 1) * totalCount / (2 * maximumFrameCount)
        })
    }

    private static func encodedAttachments(for buffer: CVPixelBuffer) -> Data? {
        guard let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any],
              PropertyListSerialization.propertyList(attachments, isValidFor: .binary) else {
            return nil
        }
        return try? PropertyListSerialization.data(
            fromPropertyList: attachments,
            format: .binary,
            options: 0
        )
    }

    private static func applyAttachments(_ data: Data?, to buffer: CVPixelBuffer) {
        guard let data,
              let attachments = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return
        }
        for (key, value) in attachments {
            CVBufferSetAttachment(buffer, key as CFString, value as CFTypeRef, .shouldPropagate)
        }
    }
}
