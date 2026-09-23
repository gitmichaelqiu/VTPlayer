import CoreMedia
import CoreVideo
import XCTest
@testable import VTPlayer

final class EnhancedFrameDiskCacheTests: XCTestCase {
    func testSourceFingerprintDistinguishesCanonicalPathsAndMiddleContentChanges() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstFolder = directory.appendingPathComponent("first", isDirectory: true)
        let secondFolder = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let firstURL = firstFolder.appendingPathComponent("same-name.mp4")
        let secondURL = secondFolder.appendingPathComponent("same-name.mp4")
        let content = Data(repeating: 0, count: 10 * 1_024 * 1_024)
        try content.write(to: firstURL)
        try content.write(to: secondURL)
        let fixedModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModificationDate],
            ofItemAtPath: firstURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModificationDate],
            ofItemAtPath: secondURL.path
        )

        let firstFingerprint = try EnhancedFrameDiskCache.sourceFingerprint(for: firstURL)
        XCTAssertNotEqual(firstFingerprint, try EnhancedFrameDiskCache.sourceFingerprint(for: secondURL))

        let handle = try FileHandle(forWritingTo: firstURL)
        try handle.seek(toOffset: 5 * 1_024 * 1_024)
        try handle.write(contentsOf: Data([0x7F]))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModificationDate],
            ofItemAtPath: firstURL.path
        )

        XCTAssertNotEqual(firstFingerprint, try EnhancedFrameDiskCache.sourceFingerprint(for: firstURL))
    }

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
        let frame = try makeFrame(
            value: 0x7A,
            time: CMTime(value: 123, timescale: 600, flags: .valid, epoch: 3),
            interpolated: true
        )

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

    func testFrameLimitedReadEvenlySelectsDisplayableFrames() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("limited-read")
        let frames = try (0..<4).map { index in
            try makeFrame(
                value: UInt8(index),
                time: CMTime(value: Int64(index), timescale: 240),
                interpolated: index < 3
            )
        }

        _ = try await cache.prepare(
            key: key,
            coverageBitmap: [true],
            diskBudgetBytes: 1_000_000,
            requiredAdditionalBytes: 0
        )
        try await cache.writeGroup(frames, for: 0)
        _ = try await cache.finalizePreparation()

        let group = try await cache.readGroup(0, for: key, maximumFrameCount: 2)
        let decoded = try XCTUnwrap(group)
        XCTAssertEqual(decoded.map(\.presentationTimeStamp), [frames[1].presentationTimeStamp, frames[3].presentationTimeStamp])
        XCTAssertEqual(decoded.map { firstByte(of: $0.buffer) }, [1, 3])
    }

    func testResolvedGroupCanBeReadOutsideCacheActor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("resolved-group")

        try await completeCache(cache, key: key)
        let groupURL = try await cache.groupFileURL(0, for: key)
        let url = try XCTUnwrap(groupURL)
        let frames = try EnhancedFrameDiskCache.readFrames(at: url)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(firstByte(of: frames[0].buffer), 1)
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

    func testDiskUsageRecoversCacheInterruptedDuringDirectoryReplacement() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("replacement-recovery")
        try await completeCache(cache, key: key)

        let completed = directory.appendingPathComponent(key.directoryName, isDirectory: true)
        let replaced = directory.appendingPathComponent("\(key.directoryName).replaced", isDirectory: true)
        try FileManager.default.moveItem(at: completed, to: replaced)

        let usage = try await cache.diskUsageBytes()
        let status = try await cache.cachedStatus(for: key)
        XCTAssertGreaterThan(usage, 0)
        XCTAssertNotNil(status)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replaced.path))
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

    func testEncodedChunkRoundTripsExactTimestampsInterpolationAndColorAttachments() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = EnhancedFrameCacheKey(
            sourceFingerprint: "encoded-chunk-round-trip",
            configuration: .disabled,
            cacheFormatVersion: EnhancedFrameCacheKey.currentHEVCChunkFormatVersion,
            displayTargetFrameRate: 120
        )
        let preparation = UUID()
        let firstTime = CMTime(value: 0, timescale: 60_000, flags: .valid, epoch: 2)
        let secondTime = CMTime(value: 1_001, timescale: 120_000, flags: .valid, epoch: 2)
        _ = try await cache.prepare(
            key: key,
            coverageBitmap: [true, true],
            diskBudgetBytes: 10 * 1_024 * 1_024,
            requiredAdditionalBytes: 1 * 1_024 * 1_024,
            preparationIdentifier: preparation
        )
        try await cache.recordEncodedSourceGroup(
            0,
            presentationTime: firstTime,
            chunkIndex: 0,
            preparationIdentifier: preparation
        )
        try await cache.appendEncodedFrame(
            makeFrame(value: 48, time: firstTime, interpolated: false, width: 64, height: 64),
            groupIndex: 0,
            chunkIndex: 0,
            averageBitRate: 2_000_000,
            expectedFrameRate: 120,
            preparationIdentifier: preparation
        )
        try await cache.recordEncodedSourceGroup(
            1,
            presentationTime: CMTime(value: 1_001, timescale: 60_000, flags: .valid, epoch: 2),
            chunkIndex: 0,
            preparationIdentifier: preparation
        )
        try await cache.appendEncodedFrame(
            makeFrame(value: 96, time: secondTime, interpolated: true, width: 64, height: 64),
            groupIndex: 1,
            chunkIndex: 0,
            averageBitRate: 2_000_000,
            expectedFrameRate: 120,
            preparationIdentifier: preparation
        )

        let completed = try await cache.finalizePreparation(preparationIdentifier: preparation)
        let optionalChunkIndex = try await cache.encodedChunkIndex(atOrAfter: firstTime, for: key)
        let chunkIndex = try XCTUnwrap(optionalChunkIndex)
        let optionalDecodedChunk = try await cache.readEncodedChunk(chunkIndex, for: key)
        let decodedChunk = try XCTUnwrap(optionalDecodedChunk)

        XCTAssertTrue(completed.satisfies(coverage: [true, true]))
        XCTAssertEqual(decodedChunk.sourceGroupCount, 2)
        XCTAssertEqual(decodedChunk.metadata.sourceGroupCount, 2)
        XCTAssertEqual(decodedChunk.frames.count, 2)
        XCTAssertEqual(CMTimeCompare(decodedChunk.frames[0].presentationTimeStamp, firstTime), 0)
        XCTAssertEqual(CMTimeCompare(decodedChunk.frames[1].presentationTimeStamp, secondTime), 0)
        XCTAssertTrue(decodedChunk.frames[1].isInterpolated)
        XCTAssertEqual(decodedChunk.metadata.codec, "HEVC")
        XCTAssertTrue(decodedChunk.metadata.profile.contains("AutoLevel"))
        XCTAssertTrue(decodedChunk.metadata.closedGOP)
        XCTAssertTrue(decodedChunk.metadata.startsWithSyncSample)
        XCTAssertFalse(decodedChunk.metadata.allowsFrameReordering)
        XCTAssertEqual(decodedChunk.metadata.maximumKeyFrameInterval, 60)
        XCTAssertEqual(decodedChunk.metadata.attachmentTable.count, 1)
        XCTAssertNotNil(CVBufferCopyAttachment(
            decodedChunk.frames[0].buffer,
            kCVImageBufferColorPrimariesKey,
            nil
        ))

        let streamProbe = EncodedChunkStreamProbe()
        let streamedGroupCount = try await cache.readEncodedChunkStreaming(
            chunkIndex,
            for: key
        ) { frame in
            await streamProbe.append(frame)
        }
        let streamedFrames = await streamProbe.frames
        XCTAssertEqual(streamedGroupCount, 2)
        XCTAssertEqual(streamedFrames.map(\.presentationTimeStamp), decodedChunk.frames.map(\.presentationTimeStamp))
        XCTAssertEqual(streamedFrames.map(\.isInterpolated), decodedChunk.frames.map(\.isInterpolated))
    }

    func testEncodedMain10ChunkRetainsHDRColorMetadataAndBitDepth() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = EnhancedFrameCacheKey(
            sourceFingerprint: "main10-round-trip",
            configuration: .disabled,
            cacheFormatVersion: EnhancedFrameCacheKey.currentHEVCChunkFormatVersion,
            displayTargetFrameRate: 30
        )
        let preparation = UUID()
        let firstTime = CMTime(value: 0, timescale: 30)
        let secondTime = CMTime(value: 1, timescale: 30)
        _ = try await cache.prepare(
            key: key,
            coverageBitmap: [true, true],
            diskBudgetBytes: 10 * 1_024 * 1_024,
            requiredAdditionalBytes: 1 * 1_024 * 1_024,
            preparationIdentifier: preparation
        )
        try await cache.recordEncodedSourceGroup(
            0,
            presentationTime: firstTime,
            chunkIndex: 0,
            preparationIdentifier: preparation
        )
        try await cache.appendEncodedFrame(
            makeMain10Frame(time: firstTime),
            groupIndex: 0,
            chunkIndex: 0,
            averageBitRate: 2_000_000,
            expectedFrameRate: 30,
            preparationIdentifier: preparation
        )
        try await cache.recordEncodedSourceGroup(
            1,
            presentationTime: secondTime,
            chunkIndex: 0,
            preparationIdentifier: preparation
        )
        try await cache.appendEncodedFrame(
            makeMain10Frame(time: secondTime),
            groupIndex: 1,
            chunkIndex: 0,
            averageBitRate: 2_000_000,
            expectedFrameRate: 30,
            preparationIdentifier: preparation
        )

        _ = try await cache.finalizePreparation(preparationIdentifier: preparation)
        let optionalChunk = try await cache.readEncodedChunk(0, for: key)
        let chunk = try XCTUnwrap(optionalChunk)
        XCTAssertEqual(chunk.frames.count, 2)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(chunk.frames[0].buffer),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(chunk.frames[0].buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(chunk.frames[0].buffer, kCVImageBufferColorPrimariesKey, nil) as? String,
            kCVImageBufferColorPrimaries_ITU_R_2020 as String
        )
    }

    func testEncodedChunkMeetsMinimumQualityAgainstEnhancedInput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = EnhancedFrameCacheKey(
            sourceFingerprint: "quality-round-trip",
            configuration: .disabled,
            cacheFormatVersion: EnhancedFrameCacheKey.currentHEVCChunkFormatVersion,
            displayTargetFrameRate: 30
        )
        let preparation = UUID()
        let originalFrames = try [
            makeQualityFrame(time: .zero, shift: 0),
            makeQualityFrame(time: CMTime(value: 1, timescale: 120), shift: 3)
        ]
        let qualityBitRate = EnhancedFrameCacheSizing.targetBitRate(
            width: 1_280,
            height: 720,
            frameRate: 120
        )
        _ = try await cache.prepare(
            key: key,
            coverageBitmap: [true, true],
            diskBudgetBytes: 20 * 1_024 * 1_024,
            requiredAdditionalBytes: 1 * 1_024 * 1_024,
            preparationIdentifier: preparation
        )
        for (groupIndex, frame) in originalFrames.enumerated() {
            try await cache.recordEncodedSourceGroup(
                groupIndex,
                presentationTime: frame.presentationTimeStamp,
                chunkIndex: 0,
                preparationIdentifier: preparation
            )
            try await cache.appendEncodedFrame(
                frame,
                groupIndex: groupIndex,
                chunkIndex: 0,
                averageBitRate: qualityBitRate,
                expectedFrameRate: 120,
                preparationIdentifier: preparation
            )
        }
        _ = try await cache.finalizePreparation(preparationIdentifier: preparation)
        let optionalDecodedChunk = try await cache.readEncodedChunk(0, for: key)
        let decodedChunk = try XCTUnwrap(optionalDecodedChunk)

        XCTAssertEqual(decodedChunk.frames.count, originalFrames.count)
        for (original, decoded) in zip(originalFrames, decodedChunk.frames) {
            XCTAssertGreaterThan(imagePSNR(original.buffer, decoded.buffer), 32)
        }
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

    func testInvalidatedEncodedCacheCannotBeReusedAndWaitsForPlaybackPin() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = cacheKey("invalidate-cache")
        try await completeCache(cache, key: key)

        await cache.beginPlayback(for: key)
        try await cache.invalidateCache(for: key)
        let invalidatedStatus = try await cache.cachedStatus(for: key)
        XCTAssertNil(invalidatedStatus)

        let replacementTask = Task {
            try await cache.prepare(
                key: key,
                coverageBitmap: [true],
                diskBudgetBytes: 1_000_000,
                requiredAdditionalBytes: 0
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        await cache.endPlayback(for: key)
        let replacement = try await replacementTask.value
        XCTAssertEqual(replacement.missingGroupIndices, [0])
    }

    func testCorruptEncodedChunkIsRejectedAndInvalidated() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EnhancedFrameDiskCache(rootDirectory: directory)
        let key = EnhancedFrameCacheKey(
            sourceFingerprint: "corrupt-encoded-chunk",
            configuration: .disabled,
            cacheFormatVersion: EnhancedFrameCacheKey.currentHEVCChunkFormatVersion,
            displayTargetFrameRate: 30
        )
        let preparation = UUID()
        _ = try await cache.prepare(
            key: key,
            coverageBitmap: [true],
            diskBudgetBytes: 10 * 1_024 * 1_024,
            requiredAdditionalBytes: 1 * 1_024 * 1_024,
            preparationIdentifier: preparation
        )
        try await cache.recordEncodedSourceGroup(
            0,
            presentationTime: .zero,
            chunkIndex: 0,
            preparationIdentifier: preparation
        )
        try await cache.appendEncodedFrame(
            makeFrame(value: 48, time: .zero, interpolated: false, width: 64, height: 64),
            groupIndex: 0,
            chunkIndex: 0,
            averageBitRate: 2_000_000,
            expectedFrameRate: 30,
            preparationIdentifier: preparation
        )
        _ = try await cache.finalizePreparation(preparationIdentifier: preparation)

        let chunkURL = directory
            .appendingPathComponent(key.directoryName, isDirectory: true)
            .appendingPathComponent("chunk-00000000.mov")
        var bytes = try Data(contentsOf: chunkURL)
        bytes[bytes.startIndex] ^= 0xff
        try bytes.write(to: chunkURL, options: .atomic)

        do {
            _ = try await cache.readEncodedChunkStreaming(0, for: key) { _ in }
            XCTFail("Expected digest validation to reject the modified chunk")
        } catch {
            XCTAssertNotNil(error)
        }
        let invalidatedStatus = try await cache.cachedStatus(for: key)
        XCTAssertNil(invalidatedStatus)
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

    private func makeFrame(
        value: UInt8,
        time: CMTime,
        interpolated: Bool,
        width: Int = 4,
        height: Int = 4
    ) throws -> VTFrame {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
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

    private func makeMain10Frame(time: CMTime) -> VTFrame {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            32,
            32,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attributes as CFDictionary,
            &buffer
        )
        XCTAssertEqual(result, kCVReturnSuccess)
        guard let buffer else { fatalError("Unable to allocate Main10 test frame") }
        let colorAttachments: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        ]
        for (key, value) in colorAttachments {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        return VTFrame(buffer: buffer, presentationTimeStamp: time, isInterpolated: false)
    }

    private func makeQualityFrame(time: CMTime, shift: Int) throws -> VTFrame {
        let width = 1_280
        let height = 720
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &buffer
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * bytesPerRow + x * 4
                let level = UInt8((x + shift) % 256)
                let checker = ((x / 16 + y / 16).isMultiple(of: 2)) ? 8 : 0
                baseAddress[index] = level
                baseAddress[index + 1] = UInt8(min(255, Int(level) + checker))
                baseAddress[index + 2] = UInt8(max(0, Int(level) - checker))
                baseAddress[index + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return VTFrame(buffer: pixelBuffer, presentationTimeStamp: time, isInterpolated: false)
    }

    private func imagePSNR(_ original: CVPixelBuffer, _ decoded: CVPixelBuffer) -> Double {
        XCTAssertEqual(CVPixelBufferGetWidth(original), CVPixelBufferGetWidth(decoded))
        XCTAssertEqual(CVPixelBufferGetHeight(original), CVPixelBufferGetHeight(decoded))
        CVPixelBufferLockBaseAddress(original, .readOnly)
        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(original, .readOnly)
            CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
        }
        let width = CVPixelBufferGetWidth(original)
        let height = CVPixelBufferGetHeight(original)
        let originalStride = CVPixelBufferGetBytesPerRow(original)
        let decodedStride = CVPixelBufferGetBytesPerRow(decoded)
        let originalBase = CVPixelBufferGetBaseAddress(original)!.assumingMemoryBound(to: UInt8.self)
        let decodedBase = CVPixelBufferGetBaseAddress(decoded)!.assumingMemoryBound(to: UInt8.self)
        var squaredError = 0.0
        var sampleCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let originalIndex = y * originalStride + x * 4
                let decodedIndex = y * decodedStride + x * 4
                for channel in 0..<3 {
                    let difference = Double(originalBase[originalIndex + channel]) -
                        Double(decodedBase[decodedIndex + channel])
                    squaredError += difference * difference
                    sampleCount += 1
                }
            }
        }
        let meanSquaredError = squaredError / Double(max(1, sampleCount))
        return meanSquaredError == 0
            ? .infinity
            : 10 * log10(Double(255 * 255) / meanSquaredError)
    }

    private func firstByte(of buffer: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self).pointee
    }
}

private actor EncodedChunkStreamProbe {
    private(set) var frames: [VTFrame] = []

    func append(_ frame: VTFrame) {
        frames.append(frame)
    }
}
