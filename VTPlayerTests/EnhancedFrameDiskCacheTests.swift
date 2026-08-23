import CoreMedia
import CoreVideo
import XCTest
@testable import VTPlayer

final class EnhancedFrameDiskCacheTests: XCTestCase {
    func testStatusRequiresEveryGroupInAnExpandedCoveragePlan() {
        let status = EnhancedFrameCacheStatus(
            key: EnhancedFrameCacheKey(
                sourceFingerprint: "fixture",
                configuration: .disabled
            ),
            coverageBitmap: [false, true, false, true],
            availableGroupIndices: [1, 3],
            byteCount: 0,
            preparationIdentifier: nil
        )

        XCTAssertTrue(status.satisfies(coverage: [false, true, false, true]))
        XCTAssertFalse(status.satisfies(coverage: [true, true, false, true]))
        XCTAssertFalse(status.satisfies(coverage: [false, true]))
    }

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

    func testGroupLookupStartsAtTheNextCachedSourceTimestamp() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("lookup")
        _ = try await cache.prepare(
            key: key,
            coverageBitmap: [true, true],
            diskBudgetBytes: 1_000_000,
            requiredAdditionalBytes: 0
        )
        try await cache.writeGroup(
            [try makeFrame(value: 1, time: .zero, interpolated: false)],
            for: 0,
            sourcePresentationTime: .zero
        )
        try await cache.writeGroup(
            [try makeFrame(value: 2, time: CMTime(seconds: 1, preferredTimescale: 600), interpolated: false)],
            for: 1,
            sourcePresentationTime: CMTime(seconds: 1, preferredTimescale: 600)
        )
        _ = try await cache.finalizePreparation()

        let nextGroup = try await cache.groupIndex(
            atOrAfter: CMTime(seconds: 0.5, preferredTimescale: 600),
            for: key
        )
        XCTAssertEqual(nextGroup, 1)
    }

    func testStalePreparationCannotWriteOrDiscardNewPreparation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let firstPreparation = UUID()
        let secondPreparation = UUID()

        _ = try await cache.prepare(
            key: cacheKey("stale-preparation"),
            coverageBitmap: [true],
            diskBudgetBytes: 1_000_000,
            requiredAdditionalBytes: 0,
            preparationIdentifier: firstPreparation
        )
        _ = try await cache.prepare(
            key: cacheKey("stale-preparation"),
            coverageBitmap: [true],
            diskBudgetBytes: 1_000_000,
            requiredAdditionalBytes: 0,
            preparationIdentifier: secondPreparation
        )

        do {
            try await cache.writeGroup(
                [try makeFrame(value: 1, time: .zero, interpolated: false)],
                for: 0,
                preparationIdentifier: firstPreparation
            )
            XCTFail("Expected stale preparation rejection")
        } catch is CancellationError {
            XCTAssertTrue(true)
        }
        try await cache.discardPreparation(preparationIdentifier: firstPreparation)
        try await cache.writeGroup(
            [try makeFrame(value: 2, time: .zero, interpolated: false)],
            for: 0,
            preparationIdentifier: secondPreparation
        )
        _ = try await cache.finalizePreparation(preparationIdentifier: secondPreparation)
    }

    func testSparseManifestIndexesUncachedSourceGroupsForSeek() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("sparse-index")
        let preparation = UUID()
        _ = try await cache.prepare(
            key: key,
            coverageBitmap: [false, true, false],
            diskBudgetBytes: 1_000_000,
            requiredAdditionalBytes: 0,
            preparationIdentifier: preparation
        )
        for index in 0..<3 {
            try await cache.recordSourceGroup(
                index,
                presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
                preparationIdentifier: preparation
            )
        }
        try await cache.writeGroup(
            [try makeFrame(value: 2, time: CMTime(seconds: 1, preferredTimescale: 600), interpolated: false)],
            for: 1,
            sourcePresentationTime: CMTime(seconds: 1, preferredTimescale: 600),
            preparationIdentifier: preparation
        )
        let status = try await cache.finalizePreparation(preparationIdentifier: preparation)

        XCTAssertEqual(status.availableGroupIndices, [1])
        let seekGroup = try await cache.groupIndex(
            closestTo: CMTime(seconds: 2, preferredTimescale: 600),
            for: key
        )
        XCTAssertEqual(seekGroup, 2)
    }

    func testClearRemovesCompletedUnpinnedCachesAndReportsUsage() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("clear-unpinned")

        try await completeCache(cache, key: key)
        let initialUsage = try await cache.diskUsageBytes()
        XCTAssertGreaterThan(initialUsage, 0)

        let remainingUsage = try await cache.clearUnpinnedCaches()
        let status = try await cache.cachedStatus(for: key)
        XCTAssertEqual(remainingUsage, 0)
        XCTAssertNil(status)
    }

    func testClearRetainsCachePinnedByActivePlayback() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("clear-pinned")

        try await completeCache(cache, key: key)
        await cache.beginPlayback(for: key)

        let pinnedUsage = try await cache.clearUnpinnedCaches()
        let pinnedStatus = try await cache.cachedStatus(for: key)
        XCTAssertGreaterThan(pinnedUsage, 0)
        XCTAssertNotNil(pinnedStatus)

        await cache.endPlayback(for: key)
        let remainingUsage = try await cache.clearUnpinnedCaches()
        let status = try await cache.cachedStatus(for: key)
        XCTAssertEqual(remainingUsage, 0)
        XCTAssertNil(status)
    }

    func testOverlappingPlaybackPinsRetainCacheUntilEveryProducerEnds() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("overlapping-pins")

        try await completeCache(cache, key: key)
        await cache.beginPlayback(for: key)
        await cache.beginPlayback(for: key)
        await cache.endPlayback(for: key)

        let retainedUsage = try await cache.clearUnpinnedCaches()
        let retainedStatus = try await cache.cachedStatus(for: key)
        XCTAssertGreaterThan(retainedUsage, 0)
        XCTAssertNotNil(retainedStatus)

        await cache.endPlayback(for: key)
        let remainingUsage = try await cache.clearUnpinnedCaches()
        XCTAssertEqual(remainingUsage, 0)
    }

    private func cacheKey(_ source: String) -> EnhancedFrameCacheKey {
        EnhancedFrameCacheKey(sourceFingerprint: source, configuration: .disabled)
    }

    private func completeCache(
        _ cache: EnhancedFrameDiskCache,
        key: EnhancedFrameCacheKey
    ) async throws {
        _ = try await cache.prepare(
            key: key,
            coverageBitmap: [true],
            diskBudgetBytes: 1_000_000,
            requiredAdditionalBytes: 0
        )
        try await cache.writeGroup(
            [try makeFrame(value: 1, time: .zero, interpolated: false)],
            for: 0
        )
        _ = try await cache.finalizePreparation()
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
