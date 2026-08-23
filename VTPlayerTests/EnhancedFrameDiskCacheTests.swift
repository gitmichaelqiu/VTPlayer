import CoreMedia
import CoreVideo
import XCTest
@testable import VTPlayer

final class EnhancedFrameDiskCacheTests: XCTestCase {
    func testRawFrameRoundTripPreservesPixelsTimingAndAttachments() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("round-trip")
        let frame = try makeFrame(value: 0x7A, time: CMTime(value: 123, timescale: 600), interpolated: true)

        _ = try await cache.prepare(
            key: key,
            coverageBitmap: [true],
            diskBudgetBytes: 1_000_000,
            requiredAdditionalBytes: 0
        )
        try await cache.writeGroup([frame], for: 0)
        _ = try await cache.finalizePreparation()

        let decodedGroup = try await cache.readGroup(0, for: key)
        let decoded = try XCTUnwrap(try XCTUnwrap(decodedGroup).first)
        XCTAssertEqual(decoded.presentationTimeStamp, frame.presentationTimeStamp)
        XCTAssertTrue(decoded.isInterpolated)
        XCTAssertEqual(firstByte(of: decoded.buffer), 0x7A)
        XCTAssertEqual(
            CVBufferCopyAttachment(decoded.buffer, kCVImageBufferColorPrimariesKey, nil) as? String,
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        )
    }

    func testExtendingCoverageReusesCompletedGroups() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("extension")

        _ = try await cache.prepare(
            key: key,
            coverageBitmap: [true, false],
            diskBudgetBytes: 1_000_000,
            requiredAdditionalBytes: 0
        )
        try await cache.writeGroup([try makeFrame(value: 1, time: .zero, interpolated: false)], for: 0)
        _ = try await cache.finalizePreparation()

        let status = try await cache.prepare(
            key: key,
            coverageBitmap: [true, true],
            diskBudgetBytes: 1_000_000,
            requiredAdditionalBytes: 0
        )
        XCTAssertEqual(status.availableGroupIndices, [0])
        XCTAssertEqual(status.missingGroupIndices, [1])
        try await cache.writeGroup([try makeFrame(value: 2, time: CMTime(value: 1, timescale: 60), interpolated: false)], for: 1)
        let completed = try await cache.finalizePreparation()

        XCTAssertEqual(completed.availableGroupIndices, [0, 1])
    }

    func testCapacityRefusalLeavesNoPartialCache() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)

        do {
            _ = try await cache.prepare(
                key: cacheKey("capacity"),
                coverageBitmap: [true],
                diskBudgetBytes: 100,
                requiredAdditionalBytes: 101
            )
            XCTFail("Expected capacity refusal")
        } catch EnhancedFrameDiskCacheError.insufficientCapacity {
            XCTAssertTrue(true)
        }

        let cachedStatus = try await cache.cachedStatus(for: cacheKey("capacity"))
        XCTAssertNil(cachedStatus)
    }

    func testCapacityEvictsLeastRecentlyUsedCompletedCache() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let firstKey = cacheKey("first")

        _ = try await cache.prepare(
            key: firstKey,
            coverageBitmap: [true],
            diskBudgetBytes: 1_000_000,
            requiredAdditionalBytes: 0
        )
        try await cache.writeGroup([try makeFrame(value: 1, time: .zero, interpolated: false)], for: 0)
        _ = try await cache.finalizePreparation()

        _ = try await cache.prepare(
            key: cacheKey("second"),
            coverageBitmap: [true],
            diskBudgetBytes: 1,
            requiredAdditionalBytes: 1
        )

        let evictedStatus = try await cache.cachedStatus(for: firstKey)
        XCTAssertNil(evictedStatus)
    }

    private func cacheKey(_ source: String) -> EnhancedFrameCacheKey {
        EnhancedFrameCacheKey(sourceFingerprint: source, configuration: .disabled)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFrame(value: UInt8, time: CMTime, interpolated: Bool) throws -> VTFrame {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                4,
                4,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &buffer
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(value), CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        return VTFrame(buffer: pixelBuffer, presentationTimeStamp: time, isInterpolated: interpolated)
    }

    private func firstByte(of buffer: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self).pointee
    }
}
