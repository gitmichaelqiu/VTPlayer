import CoreMedia
@preconcurrency import CoreVideo
import CryptoKit
import Foundation

nonisolated struct EnhancedFrameCacheKey: Codable, Equatable, Hashable, Sendable {
    static let schemaVersion = 7
    static let currentHEVCChunkFormatVersion = 6
    static let currentProcessingPipelineVersion = 1
    static let currentFrameSelectionPolicyVersion = 1
    static let currentCodecSettingsVersion = 1

    var sourceFingerprint: String
    var configuration: AppliedPipelineConfiguration
    var cacheFormatVersion: Int = 1
    var displayTargetFrameRate: Int = 0
    var processingPipelineVersion: Int = currentProcessingPipelineVersion
    var frameSelectionPolicyVersion: Int = currentFrameSelectionPolicyVersion
    var codecSettingsVersion: Int = currentCodecSettingsVersion

    var directoryName: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct EnhancedFrameCacheStatus: Equatable, Sendable {
    var key: EnhancedFrameCacheKey
    var coverageBitmap: [Bool]
    var availableGroupIndices: Set<Int>
    var byteCount: Int64
    var preparationIdentifier: UUID?

    var missingGroupIndices: [Int] {
        coverageBitmap.indices.filter { coverageBitmap[$0] && !availableGroupIndices.contains($0) }
    }

    func satisfies(coverage requiredCoverage: [Bool]) -> Bool {
        if coverageBitmap.count != requiredCoverage.count {
            return requiredCoverage.allSatisfy { $0 } &&
                coverageBitmap.allSatisfy { $0 } &&
                coverageBitmap.count <= requiredCoverage.count &&
                availableGroupIndices.count == coverageBitmap.count
        }
        return requiredCoverage.indices.allSatisfy {
            !requiredCoverage[$0] || availableGroupIndices.contains($0)
        }
    }
}

nonisolated struct EnhancedFrameCacheChunkReference: Sendable {
    let chunk: EnhancedFrameCacheEncodedChunk
    let url: URL
}

nonisolated enum EnhancedFrameDiskCacheError: LocalizedError {
    case insufficientCapacity(requiredBytes: Int64, availableBytes: Int64)
    case cacheNotPrepared
    case invalidFrameData
    case unsupportedTimeline

    var errorDescription: String? {
        switch self {
        case let .insufficientCapacity(requiredBytes, availableBytes):
            return "Enhanced-frame cache needs \(requiredBytes) bytes, but only \(availableBytes) bytes are available."
        case .cacheNotPrepared:
            return "Enhanced-frame cache has not been prepared."
        case .invalidFrameData:
            return "Enhanced-frame cache contains invalid frame data."
        case .unsupportedTimeline:
            return "The source has a discontinuous or non-monotonic video timeline that cannot be cached safely."
        }
    }
}

/// Actor-isolated storage for enhanced output. A completed cache is never
/// modified in place: preparation writes an adjacent partial directory and
/// atomically promotes it only after its manifest is complete.
actor EnhancedFrameDiskCache {
    static let shared = EnhancedFrameDiskCache()
    private static let manifestFilename = "manifest.plist"
    private static let accessPersistenceInterval: TimeInterval = 30
    private static let minimumVolumeFreeBytes: Int64 = 1 * 1_024 * 1_024 * 1_024

    private struct Manifest: Codable, Sendable {
        var schemaVersion: Int
        var key: EnhancedFrameCacheKey
        var coverageBitmap: [Bool]
        var groups: [GroupEntry]
        var chunks: [EnhancedFrameCacheEncodedChunk]
        var lastAccess: Date
        var byteCount: Int64
    }

    private struct GroupEntry: Codable, Equatable, Sendable {
        var groupIndex: Int
        var filename: String?
        var chunkIndex: Int?
        var byteCount: Int64
        var sourcePresentationSeconds: Double
        var sourcePresentationTimeValue: Int64
        var sourcePresentationTimeScale: Int32
        var sourcePresentationTimeFlags: UInt32
        var sourcePresentationTimeEpoch: Int64

        var sourcePresentationTime: CMTime {
            CMTime(
                value: sourcePresentationTimeValue,
                timescale: sourcePresentationTimeScale,
                flags: CMTimeFlags(rawValue: sourcePresentationTimeFlags),
                epoch: sourcePresentationTimeEpoch
            )
        }
    }

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

    private let rootDirectory: URL
    private let fileManager: FileManager
    private var partialDirectory: URL?
    private var preparedManifest: Manifest?
    private var activePreparationIdentifier: UUID?
    private var activeChunkWriter: EnhancedFrameHEVCChunkWriter?
    private var activeChunkWriterIndex: Int?
    private var activeChunkWriterGeneration: UUID?
    private var activeChunkFileURL: URL?
    private var activeDiskAdditionalCapacityBytes: Int64 = .max
    private var activePreparationInitialByteCount: Int64 = 0
    private var activeVolumeAvailableAtPreparation: Int64 = .max
    private var completedManifests: [String: Manifest] = [:]
    private var activePlaybackCounts: [EnhancedFrameCacheKey: Int] = [:]
    private var invalidatedCacheDirectories: Set<String> = []

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.rootDirectory = applicationSupport
                .appendingPathComponent("VTPlayer", isDirectory: true)
                .appendingPathComponent("EnhancedFrameCache", isDirectory: true)
        }
    }

    static func sourceFingerprint(for url: URL) throws -> String {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var digest = SHA256()
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        digest.update(data: Data(canonicalPath.utf8))
        digest.update(data: Data("\(resourceValues.fileSize ?? 0)|\(resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0)".utf8))

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sampleSize = 256 * 1_024
        let fileSize = Int64(resourceValues.fileSize ?? 0)
        if fileSize <= Int64(sampleSize) {
            try handle.seek(toOffset: 0)
            if let contents = try handle.read(upToCount: sampleSize) {
                digest.update(data: contents)
            }
        } else {
            let finalOffset = fileSize - Int64(sampleSize)
            for sampleIndex in 0..<9 {
                let offset = finalOffset * Int64(sampleIndex) / 8
                try handle.seek(toOffset: UInt64(offset))
                if let sample = try handle.read(upToCount: sampleSize) {
                    digest.update(data: sample)
                }
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func prepare(
        key: EnhancedFrameCacheKey,
        coverageBitmap: [Bool],
        diskBudgetBytes: Int64,
        requiredAdditionalBytes: Int64,
        preparationIdentifier: UUID = UUID()
    ) async throws -> EnhancedFrameCacheStatus {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try await discardPreparation()
        try removeStalePartialDirectories()
        try recoverReplacedDirectories()
        try removeIncompatibleCacheDirectories()
        try recoverReplacedDirectory(for: key)
        if invalidatedCacheDirectories.contains(key.directoryName) {
            while activePlaybackCounts[key] != nil {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            let invalidDirectory = directory(for: key)
            if fileManager.fileExists(atPath: invalidDirectory.path) {
                try fileManager.removeItem(at: invalidDirectory)
            }
            completedManifests.removeValue(forKey: key.directoryName)
            invalidatedCacheDirectories.remove(key.directoryName)
        }
        let existingDirectory = directory(for: key)
        let existingManifest = try completedManifest(for: key)
        let availableBytes = try evictForCapacity(
            requiredAdditionalBytes: requiredAdditionalBytes,
            diskBudgetBytes: diskBudgetBytes,
            preserving: key.directoryName
        )
        guard availableBytes >= requiredAdditionalBytes else {
            throw EnhancedFrameDiskCacheError.insufficientCapacity(
                requiredBytes: requiredAdditionalBytes,
                availableBytes: availableBytes
            )
        }

        let partial = rootDirectory.appendingPathComponent("\(key.directoryName).partial", isDirectory: true)
        if fileManager.fileExists(atPath: partial.path) {
            try fileManager.removeItem(at: partial)
        }
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)

        var entries: [GroupEntry] = []
        var chunks: [EnhancedFrameCacheEncodedChunk] = []
        if let existingManifest, existingManifest.key == key {
            for entry in existingManifest.groups {
                if let filename = entry.filename {
                    let source = existingDirectory.appendingPathComponent(filename)
                    let destination = partial.appendingPathComponent(filename)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    do {
                        try fileManager.linkItem(at: source, to: destination)
                    } catch {
                        try fileManager.copyItem(at: source, to: destination)
                    }
                }
                entries.append(entry)
            }
            for chunk in existingManifest.chunks {
                let source = existingDirectory.appendingPathComponent(chunk.filename)
                let destination = partial.appendingPathComponent(chunk.filename)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                do {
                    try fileManager.linkItem(at: source, to: destination)
                } catch {
                    try fileManager.copyItem(at: source, to: destination)
                }
                chunks.append(chunk)
            }
        }

        let manifest = Manifest(
            schemaVersion: EnhancedFrameCacheKey.schemaVersion,
            key: key,
            coverageBitmap: coverageBitmap,
            groups: entries,
            chunks: chunks,
            lastAccess: .now,
            byteCount: entries.reduce(0) { $0 + $1.byteCount } + chunks.reduce(0) { $0 + $1.byteCount }
        )
        partialDirectory = partial
        preparedManifest = manifest
        activePreparationIdentifier = preparationIdentifier
        activeDiskAdditionalCapacityBytes = availableBytes
        activePreparationInitialByteCount = existingManifest?.byteCount ?? 0
        activeVolumeAvailableAtPreparation = Self.availableVolumeBytes(at: rootDirectory)
        try writeManifest(manifest, to: partial)
        return status(for: manifest, preparationIdentifier: preparationIdentifier)
    }

    func recordEncodedSourceGroup(
        _ groupIndex: Int,
        presentationTime: CMTime,
        chunkIndex: Int,
        preparationIdentifier: UUID
    ) throws {
        guard preparedManifest != nil else { throw EnhancedFrameDiskCacheError.cacheNotPrepared }
        guard preparationIdentifier == activePreparationIdentifier else {
            throw CancellationError()
        }
        let coverageCount = preparedManifest!.coverageBitmap.count
        if groupIndex >= coverageCount, preparedManifest!.key.cacheFormatVersion >= 2 {
            preparedManifest!.coverageBitmap.append(
                contentsOf: repeatElement(
                    true,
                    count: groupIndex - coverageCount + 1
                )
            )
        }
        guard preparedManifest!.coverageBitmap.indices.contains(groupIndex),
              preparedManifest!.coverageBitmap[groupIndex] else { return }
        let seconds = CMTimeGetSeconds(presentationTime)
        upsertGroupEntry(GroupEntry(
            groupIndex: groupIndex,
            filename: nil,
            chunkIndex: chunkIndex,
            byteCount: 0,
            sourcePresentationSeconds: seconds.isFinite ? seconds : 0,
            sourcePresentationTimeValue: presentationTime.value,
            sourcePresentationTimeScale: presentationTime.timescale,
            sourcePresentationTimeFlags: presentationTime.flags.rawValue,
            sourcePresentationTimeEpoch: presentationTime.epoch
        ))
    }

    func appendEncodedFrame(
        _ frame: VTFrame,
        groupIndex: Int,
        chunkIndex: Int,
        averageBitRate: Int,
        expectedFrameRate: Int,
        preparationIdentifier: UUID
    ) async throws {
        guard let partialDirectory else { throw EnhancedFrameDiskCacheError.cacheNotPrepared }
        guard preparationIdentifier == activePreparationIdentifier else { throw CancellationError() }
        guard preparedManifest?.coverageBitmap.indices.contains(groupIndex) == true,
              preparedManifest?.coverageBitmap[groupIndex] == true else { return }

        if activeChunkWriterIndex != chunkIndex {
            try await finishEncodedChunk(preparationIdentifier: preparationIdentifier)
            guard preparationIdentifier == activePreparationIdentifier else { throw CancellationError() }
            let filename = String(format: "chunk-%08d.mov", chunkIndex)
            let outputURL = partialDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            let writer = EnhancedFrameHEVCChunkWriter(
                outputURL: outputURL,
                chunkIndex: chunkIndex,
                averageBitRate: averageBitRate,
                expectedFrameRate: expectedFrameRate
            )
            activeChunkWriter = writer
            activeChunkWriterIndex = chunkIndex
            activeChunkWriterGeneration = preparationIdentifier
            activeChunkFileURL = outputURL
        }

        guard let writer = activeChunkWriter,
              activeChunkWriterGeneration == preparationIdentifier else {
            throw CancellationError()
        }
        try await writer.append(EnhancedFrameCacheEncodedFrame(groupIndex: groupIndex, frame: frame))
        guard preparationIdentifier == activePreparationIdentifier,
              activeChunkWriter === writer else {
            throw CancellationError()
        }
    }

    func finishEncodedChunk(preparationIdentifier: UUID) async throws {
        guard preparationIdentifier == activePreparationIdentifier else { throw CancellationError() }
        guard let writer = activeChunkWriter else { return }
        guard activeChunkWriterGeneration == preparationIdentifier else { throw CancellationError() }

        var chunk = try await writer.finish()
        guard preparationIdentifier == activePreparationIdentifier,
              activeChunkWriter === writer,
              preparedManifest != nil else {
            await writer.cancel()
            throw CancellationError()
        }
        chunk.sourceGroupCount = sourceGroupCountForNewlyFinishedChunk(chunk.chunkIndex)
        activeChunkWriter = nil
        activeChunkWriterIndex = nil
        activeChunkWriterGeneration = nil
        activeChunkFileURL = nil

        let previousChunkBytes = preparedManifest!.chunks.first {
            $0.chunkIndex == chunk.chunkIndex
        }?.byteCount ?? 0
        upsertEncodedChunk(chunk)
        preparedManifest!.byteCount += chunk.byteCount - previousChunkBytes
        preparedManifest!.lastAccess = .now
        let additionalBytes = max(0, preparedManifest!.byteCount - activePreparationInitialByteCount)
        guard additionalBytes <= activeDiskAdditionalCapacityBytes else {
            throw EnhancedFrameDiskCacheError.insufficientCapacity(
                requiredBytes: additionalBytes,
                availableBytes: activeDiskAdditionalCapacityBytes
            )
        }
        let availableVolumeBytes = Self.availableVolumeBytes(at: rootDirectory)
        let volumeBytesConsumed = max(0, activeVolumeAvailableAtPreparation - availableVolumeBytes)
        guard availableVolumeBytes >= Self.minimumVolumeFreeBytes,
              volumeBytesConsumed <= activeDiskAdditionalCapacityBytes else {
            throw EnhancedFrameDiskCacheError.insufficientCapacity(
                requiredBytes: volumeBytesConsumed + Self.minimumVolumeFreeBytes,
                availableBytes: activeDiskAdditionalCapacityBytes
            )
        }
    }

    func writeGroup(
        _ frames: [VTFrame],
        for groupIndex: Int,
        sourcePresentationTime: CMTime? = nil,
        preparationIdentifier: UUID? = nil
    ) throws {
        guard let partialDirectory, preparedManifest != nil else {
            throw EnhancedFrameDiskCacheError.cacheNotPrepared
        }
        guard preparationIdentifier == nil || preparationIdentifier == activePreparationIdentifier else {
            throw CancellationError()
        }
        guard preparedManifest!.coverageBitmap.indices.contains(groupIndex),
              preparedManifest!.coverageBitmap[groupIndex] else { return }

        let filename = String(format: "group-%08d.raw", groupIndex)
        let destination = partialDirectory.appendingPathComponent(filename)
        let temporary = partialDirectory.appendingPathComponent("\(filename).tmp")
        let encoded = try encode(frames)
        try encoded.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)

        let sourceSeconds = CMTimeGetSeconds(sourcePresentationTime ?? frames.last?.presentationTimeStamp ?? .zero)
        let entry = GroupEntry(
            groupIndex: groupIndex,
            filename: filename,
            chunkIndex: nil,
            byteCount: Int64(encoded.count),
            sourcePresentationSeconds: sourceSeconds.isFinite ? sourceSeconds : 0,
            sourcePresentationTimeValue: (sourcePresentationTime ?? frames.last?.presentationTimeStamp ?? .zero).value,
            sourcePresentationTimeScale: (sourcePresentationTime ?? frames.last?.presentationTimeStamp ?? .zero).timescale,
            sourcePresentationTimeFlags: (sourcePresentationTime ?? frames.last?.presentationTimeStamp ?? .zero).flags.rawValue,
            sourcePresentationTimeEpoch: (sourcePresentationTime ?? frames.last?.presentationTimeStamp ?? .zero).epoch
        )
        let previousByteCount = preparedManifest!.groups.first {
            $0.groupIndex == groupIndex
        }?.byteCount ?? 0
        upsertGroupEntry(entry)
        preparedManifest!.byteCount += entry.byteCount - previousByteCount
        preparedManifest!.lastAccess = .now
    }

    func recordSourceGroup(
        _ groupIndex: Int,
        presentationTime: CMTime,
        preparationIdentifier: UUID? = nil
    ) throws {
        guard preparedManifest != nil else { throw EnhancedFrameDiskCacheError.cacheNotPrepared }
        guard preparationIdentifier == nil || preparationIdentifier == activePreparationIdentifier else {
            throw CancellationError()
        }
        if let lastGroupIndex = preparedManifest!.groups.last?.groupIndex,
           lastGroupIndex == groupIndex {
            return
        }
        if let lastGroupIndex = preparedManifest!.groups.last?.groupIndex,
           lastGroupIndex < groupIndex {
            let seconds = CMTimeGetSeconds(presentationTime)
            preparedManifest!.groups.append(GroupEntry(
                groupIndex: groupIndex,
                filename: nil,
                chunkIndex: nil,
                byteCount: 0,
                sourcePresentationSeconds: seconds.isFinite ? seconds : 0,
                sourcePresentationTimeValue: presentationTime.value,
                sourcePresentationTimeScale: presentationTime.timescale,
                sourcePresentationTimeFlags: presentationTime.flags.rawValue,
                sourcePresentationTimeEpoch: presentationTime.epoch
            ))
            return
        }
        guard !preparedManifest!.groups.contains(where: { $0.groupIndex == groupIndex }) else { return }
        let seconds = CMTimeGetSeconds(presentationTime)
        upsertGroupEntry(GroupEntry(
            groupIndex: groupIndex,
            filename: nil,
            chunkIndex: nil,
            byteCount: 0,
            sourcePresentationSeconds: seconds.isFinite ? seconds : 0,
            sourcePresentationTimeValue: presentationTime.value,
            sourcePresentationTimeScale: presentationTime.timescale,
            sourcePresentationTimeFlags: presentationTime.flags.rawValue,
            sourcePresentationTimeEpoch: presentationTime.epoch
        ))
    }

    func finalizePreparation(
        actualGroupCount: Int? = nil,
        preparationIdentifier: UUID? = nil
    ) async throws -> EnhancedFrameCacheStatus {
        if let preparationIdentifier {
            try await finishEncodedChunk(preparationIdentifier: preparationIdentifier)
        } else if let activePreparationIdentifier {
            try await finishEncodedChunk(preparationIdentifier: activePreparationIdentifier)
        }
        guard let partialDirectory, var manifest = preparedManifest else {
            throw EnhancedFrameDiskCacheError.cacheNotPrepared
        }
        guard preparationIdentifier == nil || preparationIdentifier == activePreparationIdentifier else {
            throw CancellationError()
        }
        if let actualGroupCount {
            guard actualGroupCount >= 0, actualGroupCount <= manifest.coverageBitmap.count else {
                throw EnhancedFrameDiskCacheError.invalidFrameData
            }
            manifest.coverageBitmap = Array(manifest.coverageBitmap.prefix(actualGroupCount))
            manifest.groups.removeAll { $0.groupIndex >= actualGroupCount }
            manifest.byteCount = manifest.groups.reduce(0) { $0 + $1.byteCount }
                + manifest.chunks.reduce(0) { $0 + $1.byteCount }
        }
        let missing = status(for: manifest).missingGroupIndices
        guard missing.isEmpty else { throw EnhancedFrameDiskCacheError.invalidFrameData }

        manifest.lastAccess = .now
        try writeManifest(manifest, to: partialDirectory)
        let completed = directory(for: manifest.key)
        let replaced = rootDirectory.appendingPathComponent("\(manifest.key.directoryName).replaced", isDirectory: true)
        if fileManager.fileExists(atPath: replaced.path) {
            try fileManager.removeItem(at: replaced)
        }
        if fileManager.fileExists(atPath: completed.path) {
            try fileManager.moveItem(at: completed, to: replaced)
        }
        try fileManager.moveItem(at: partialDirectory, to: completed)
        if fileManager.fileExists(atPath: replaced.path) {
            try fileManager.removeItem(at: replaced)
        }
        self.partialDirectory = nil
        self.preparedManifest = nil
        self.activePreparationIdentifier = nil
        self.activeDiskAdditionalCapacityBytes = .max
        self.activePreparationInitialByteCount = 0
        self.activeVolumeAvailableAtPreparation = .max
        completedManifests[manifest.key.directoryName] = manifest
        return status(for: manifest)
    }

    func discardPreparation(preparationIdentifier: UUID? = nil) async throws {
        guard preparationIdentifier == nil || preparationIdentifier == activePreparationIdentifier else { return }
        if let activeChunkWriter {
            await activeChunkWriter.cancel()
        }
        if let partialDirectory, fileManager.fileExists(atPath: partialDirectory.path) {
            try fileManager.removeItem(at: partialDirectory)
        }
        partialDirectory = nil
        preparedManifest = nil
        activePreparationIdentifier = nil
        activeChunkWriter = nil
        activeChunkWriterIndex = nil
        activeChunkWriterGeneration = nil
        activeChunkFileURL = nil
        activeDiskAdditionalCapacityBytes = .max
        activePreparationInitialByteCount = 0
        activeVolumeAvailableAtPreparation = .max
    }

    func preparationByteCount(preparationIdentifier: UUID) -> Int64 {
        guard preparationIdentifier == activePreparationIdentifier,
              let manifest = preparedManifest else { return 0 }
        let activeBytes: Int64 = activeChunkFileURL.flatMap { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
            return (attributes[.size] as? NSNumber)?.int64Value
        } ?? 0
        return manifest.byteCount + activeBytes
    }

    func readGroup(
        _ groupIndex: Int,
        for key: EnhancedFrameCacheKey,
        maximumFrameCount: Int? = nil
    ) throws -> [VTFrame]? {
        guard var manifest = try completedManifest(for: key), manifest.key == key,
              let entry = manifest.groups.first(where: { $0.groupIndex == groupIndex }),
              let filename = entry.filename else {
            return nil
        }
        let cacheDirectory = directory(for: key)
        let frames = try Self.readFrames(
            at: cacheDirectory.appendingPathComponent(filename),
            maximumFrameCount: maximumFrameCount
        )
        let now = Date.now
        let directoryName = key.directoryName
        if now.timeIntervalSince(manifest.lastAccess) >= Self.accessPersistenceInterval {
            manifest.lastAccess = now
            try writeManifest(manifest, to: cacheDirectory)
            completedManifests[directoryName] = manifest
        }
        return frames
    }

    /// Resolves a completed group before its expensive raw-pixel decode is
    /// performed by a bounded playback read-ahead task.
    func groupFileURL(_ groupIndex: Int, for key: EnhancedFrameCacheKey) throws -> URL? {
        guard let manifest = try completedManifest(for: key), manifest.key == key,
              let entry = manifest.groups.first(where: { $0.groupIndex == groupIndex }),
              let filename = entry.filename else {
            return nil
        }
        return directory(for: key).appendingPathComponent(filename)
    }

    func encodedChunkIndex(atOrAfter presentationTime: CMTime, for key: EnhancedFrameCacheKey) throws -> Int? {
        guard let manifest = try completedManifest(for: key), manifest.key == key else { return nil }
        let seconds = CMTimeGetSeconds(presentationTime)
        guard !manifest.chunks.isEmpty else { return nil }
        guard seconds.isFinite else { return manifest.chunks.first?.chunkIndex }
        let requestedTime = presentationTime
        return manifest.chunks.first(where: { chunk in
            guard let lastFrame = chunk.frames.last else { return false }
            return CMTimeCompare(lastFrame.presentationTime, requestedTime) >= 0
        })?.chunkIndex ?? manifest.chunks.last?.chunkIndex
    }

    func nextEncodedChunkIndex(after chunkIndex: Int, for key: EnhancedFrameCacheKey) throws -> Int? {
        guard let manifest = try completedManifest(for: key), manifest.key == key else { return nil }
        return manifest.chunks.first(where: { $0.chunkIndex > chunkIndex })?.chunkIndex
    }

    func encodedChunkIndices(for key: EnhancedFrameCacheKey) throws -> [Int] {
        guard let manifest = try completedManifest(for: key), manifest.key == key else { return [] }
        return manifest.chunks.map(\.chunkIndex)
    }

    func readEncodedChunk(
        _ chunkIndex: Int,
        for key: EnhancedFrameCacheKey
    ) async throws -> EnhancedFrameCacheDecodedChunk? {
        guard let manifest = try completedManifest(for: key), manifest.key == key,
              let chunk = manifest.chunks.first(where: { $0.chunkIndex == chunkIndex }) else {
            return nil
        }
        let frames: [VTFrame]
        do {
            frames = try await EnhancedFrameHEVCChunkWriter.read(
                chunk: chunk,
                from: directory(for: key).appendingPathComponent(chunk.filename)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? invalidateCache(for: key)
            throw error
        }
        return EnhancedFrameCacheDecodedChunk(
            metadata: chunk,
            frames: frames,
            sourceGroupCount: sourceGroupCount(in: manifest, for: chunkIndex)
        )
    }

    func readEncodedChunkStreaming(
        _ chunkIndex: Int,
        for key: EnhancedFrameCacheKey,
        consumeFrame: @escaping @Sendable (VTFrame) async throws -> Void
    ) async throws -> Int? {
        guard let manifest = try completedManifest(for: key), manifest.key == key,
              let chunk = manifest.chunks.first(where: { $0.chunkIndex == chunkIndex }) else {
            return nil
        }
        do {
            _ = try await EnhancedFrameHEVCChunkWriter.read(
                chunk: chunk,
                from: directory(for: key).appendingPathComponent(chunk.filename),
                consumeFrame: consumeFrame
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? invalidateCache(for: key)
            throw error
        }
        return sourceGroupCount(in: manifest, for: chunkIndex)
    }

    private func sourceGroupCount(in manifest: Manifest, for chunkIndex: Int) -> Int {
        manifest.chunks.first(where: { $0.chunkIndex == chunkIndex })?.sourceGroupCount ?? 0
    }

    private func sourceGroupCountForNewlyFinishedChunk(_ chunkIndex: Int) -> Int {
        guard let preparedManifest else { return 0 }
        var count = 0
        var foundMatchingGroup = false
        for group in preparedManifest.groups.reversed() {
            guard let groupChunkIndex = group.chunkIndex else { continue }
            if groupChunkIndex == chunkIndex {
                count += 1
                foundMatchingGroup = true
            } else if foundMatchingGroup || groupChunkIndex < chunkIndex {
                break
            }
        }
        return count
    }

    private func upsertGroupEntry(_ entry: GroupEntry) {
        guard preparedManifest != nil else { return }
        if let last = preparedManifest!.groups.last {
            if last.groupIndex == entry.groupIndex {
                let lastIndex = preparedManifest!.groups.count - 1
                preparedManifest!.groups[lastIndex] = entry
                return
            }
            if last.groupIndex < entry.groupIndex {
                preparedManifest!.groups.append(entry)
                return
            }
        }
        if let index = preparedManifest!.groups.firstIndex(where: { $0.groupIndex == entry.groupIndex }) {
            preparedManifest!.groups[index] = entry
        } else {
            preparedManifest!.groups.append(entry)
            preparedManifest!.groups.sort { $0.groupIndex < $1.groupIndex }
        }
    }

    private func upsertEncodedChunk(_ chunk: EnhancedFrameCacheEncodedChunk) {
        guard preparedManifest != nil else { return }
        if let last = preparedManifest!.chunks.last {
            if last.chunkIndex == chunk.chunkIndex {
                let lastIndex = preparedManifest!.chunks.count - 1
                preparedManifest!.chunks[lastIndex] = chunk
                return
            }
            if last.chunkIndex < chunk.chunkIndex {
                preparedManifest!.chunks.append(chunk)
                return
            }
        }
        if let index = preparedManifest!.chunks.firstIndex(where: { $0.chunkIndex == chunk.chunkIndex }) {
            preparedManifest!.chunks[index] = chunk
        } else {
            preparedManifest!.chunks.append(chunk)
            preparedManifest!.chunks.sort { $0.chunkIndex < $1.chunkIndex }
        }
    }

    nonisolated static func readFrames(
        at url: URL,
        maximumFrameCount: Int? = nil
    ) throws -> [VTFrame] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decode(data, maximumFrameCount: maximumFrameCount)
    }

    func cachedStatus(for key: EnhancedFrameCacheKey) throws -> EnhancedFrameCacheStatus? {
        guard let manifest = try completedManifest(for: key), manifest.key == key else { return nil }
        return status(for: manifest)
    }

    func beginPlayback(for key: EnhancedFrameCacheKey) {
        activePlaybackCounts[key, default: 0] += 1
    }

    func endPlayback(for key: EnhancedFrameCacheKey) {
        guard let count = activePlaybackCounts[key] else { return }
        if count > 1 {
            activePlaybackCounts[key] = count - 1
        } else {
            activePlaybackCounts.removeValue(forKey: key)
            if invalidatedCacheDirectories.remove(key.directoryName) != nil {
                let invalidDirectory = directory(for: key)
                if fileManager.fileExists(atPath: invalidDirectory.path) {
                    try? fileManager.removeItem(at: invalidDirectory)
                }
                completedManifests.removeValue(forKey: key.directoryName)
            }
        }
    }

    /// Prevents a cache that failed integrity or decode validation from being
    /// selected again. If playback still holds a read pin, deletion is deferred
    /// until the producer releases it.
    func invalidateCache(for key: EnhancedFrameCacheKey) throws {
        let directoryName = key.directoryName
        invalidatedCacheDirectories.insert(directoryName)
        completedManifests.removeValue(forKey: directoryName)
        guard activePlaybackCounts[key] == nil else { return }
        let invalidDirectory = directory(for: key)
        if fileManager.fileExists(atPath: invalidDirectory.path) {
            try fileManager.removeItem(at: invalidDirectory)
        }
        invalidatedCacheDirectories.remove(directoryName)
    }

    func diskUsageBytes() throws -> Int64 {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return 0 }
        try recoverReplacedDirectories()
        try removeIncompatibleCacheDirectories()
        return allocatedSize(of: rootDirectory)
    }

    /// Removes completed cache entries that are not currently serving a
    /// playback producer. Active and partial entries remain intact.
    func clearUnpinnedCaches() throws -> Int64 {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return 0 }
        let protectedDirectories = Set(activePlaybackCounts.keys.map(\.directoryName))
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories where directory.pathExtension.isEmpty {
            guard !directory.lastPathComponent.hasSuffix(".partial"),
                  !protectedDirectories.contains(directory.lastPathComponent) else {
                continue
            }
            try fileManager.removeItem(at: directory)
            completedManifests.removeValue(forKey: directory.lastPathComponent)
        }
        return try diskUsageBytes()
    }

    func groupIndex(atOrAfter presentationTime: CMTime, for key: EnhancedFrameCacheKey) throws -> Int? {
        guard let manifest = try completedManifest(for: key), manifest.key == key else { return nil }
        guard presentationTime.isValid, presentationTime.isNumeric else {
            return manifest.groups.first?.groupIndex
        }
        return manifest.groups.first(where: {
            CMTimeCompare($0.sourcePresentationTime, presentationTime) >= 0
        })?.groupIndex
            ?? manifest.groups.last?.groupIndex
    }

    func groupIndex(closestTo presentationTime: CMTime, for key: EnhancedFrameCacheKey) throws -> Int? {
        guard let manifest = try completedManifest(for: key), manifest.key == key else { return nil }
        guard presentationTime.isValid, presentationTime.isNumeric else { return nil }
        return manifest.groups.min {
            abs(CMTimeGetSeconds(CMTimeSubtract($0.sourcePresentationTime, presentationTime))) <
                abs(CMTimeGetSeconds(CMTimeSubtract($1.sourcePresentationTime, presentationTime)))
        }?.groupIndex
    }

    private func directory(for key: EnhancedFrameCacheKey) -> URL {
        rootDirectory.appendingPathComponent(key.directoryName, isDirectory: true)
    }

    private func completedManifest(for key: EnhancedFrameCacheKey) throws -> Manifest? {
        guard !invalidatedCacheDirectories.contains(key.directoryName) else { return nil }
        try recoverReplacedDirectory(for: key)
        let directoryName = key.directoryName
        if let manifest = completedManifests[directoryName] {
            return manifest
        }
        guard let manifest = try loadManifest(at: directory(for: key)), manifest.key == key else {
            return nil
        }
        let cacheDirectory = directory(for: key)
        let chunkIndices = Set(manifest.chunks.map(\.chunkIndex))
        var groupsPerChunk: [Int: Int] = [:]
        let groupReferencesAreValid = manifest.groups.allSatisfy { group in
            guard let chunkIndex = group.chunkIndex else { return true }
            groupsPerChunk[chunkIndex, default: 0] += 1
            return chunkIndices.contains(chunkIndex)
        }
        let encodedChunksArePresent = manifest.chunks.allSatisfy { chunk in
            let chunkURL = cacheDirectory.appendingPathComponent(chunk.filename)
            guard let attributes = try? fileManager.attributesOfItem(atPath: chunkURL.path),
                  let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
                return false
            }
            return byteCount == chunk.byteCount &&
                !chunk.frames.isEmpty &&
                groupsPerChunk[chunk.chunkIndex, default: 0] == chunk.sourceGroupCount
        }
        guard groupReferencesAreValid, encodedChunksArePresent else {
            invalidatedCacheDirectories.insert(directoryName)
            return nil
        }
        completedManifests[directoryName] = manifest
        return manifest
    }

    private func status(
        for manifest: Manifest,
        preparationIdentifier: UUID? = nil
    ) -> EnhancedFrameCacheStatus {
        let encodedChunkIndices = Set(manifest.chunks.map(\.chunkIndex))
        return EnhancedFrameCacheStatus(
            key: manifest.key,
            coverageBitmap: manifest.coverageBitmap,
            availableGroupIndices: Set(manifest.groups.compactMap {
                if $0.filename != nil { return $0.groupIndex }
                guard let chunkIndex = $0.chunkIndex,
                      encodedChunkIndices.contains(chunkIndex) else { return nil }
                return $0.groupIndex
            }),
            byteCount: manifest.byteCount,
            preparationIdentifier: preparationIdentifier
        )
    }

    private func loadManifest(at directory: URL) throws -> Manifest? {
        let url = directory.appendingPathComponent(Self.manifestFilename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let manifest = try? PropertyListDecoder().decode(Manifest.self, from: Data(contentsOf: url)) else {
            return nil
        }
        guard manifest.schemaVersion == EnhancedFrameCacheKey.schemaVersion else { return nil }
        return manifest
    }

    private func writeManifest(_ manifest: Manifest, to directory: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent(Self.manifestFilename), options: .atomic)
    }

    private func evictForCapacity(
        requiredAdditionalBytes: Int64,
        diskBudgetBytes: Int64,
        preserving directoryName: String
    ) throws -> Int64 {
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.isEmpty && !$0.lastPathComponent.hasSuffix(".partial") }
        let entries = try directories.compactMap { directory -> (URL, Manifest, Int64)? in
            guard let manifest = try loadManifest(at: directory) else { return nil }
            return (directory, manifest, allocatedSize(of: directory))
        }
        var usedBytes = entries.reduce(Int64(0)) { $0 + $1.2 }
        let availableBeforeEviction = min(
            max(0, diskBudgetBytes - usedBytes),
            max(0, Self.availableVolumeBytes(at: rootDirectory) - Self.minimumVolumeFreeBytes)
        )
        if availableBeforeEviction >= requiredAdditionalBytes { return availableBeforeEviction }

        for (directory, _, size) in entries
            .filter({
                $0.0.lastPathComponent != directoryName
                    && activePlaybackCounts[$0.1.key] == nil
            })
            .sorted(by: { $0.1.lastAccess < $1.1.lastAccess }) {
            try fileManager.removeItem(at: directory)
            completedManifests.removeValue(forKey: directory.lastPathComponent)
            usedBytes -= size
            let available = min(
                max(0, diskBudgetBytes - usedBytes),
                max(0, Self.availableVolumeBytes(at: rootDirectory) - Self.minimumVolumeFreeBytes)
            )
            if available >= requiredAdditionalBytes { return available }
        }
        return min(
            max(0, diskBudgetBytes - usedBytes),
            max(0, Self.availableVolumeBytes(at: rootDirectory) - Self.minimumVolumeFreeBytes)
        )
    }

    private func recoverReplacedDirectory(for key: EnhancedFrameCacheKey) throws {
        let completed = directory(for: key)
        let replaced = rootDirectory.appendingPathComponent("\(key.directoryName).replaced", isDirectory: true)
        let hasCompleted = fileManager.fileExists(atPath: completed.path)
        let hasReplaced = fileManager.fileExists(atPath: replaced.path)
        guard hasReplaced else { return }
        if hasCompleted {
            try fileManager.removeItem(at: replaced)
        } else {
            try fileManager.moveItem(at: replaced, to: completed)
        }
    }

    private func removeStalePartialDirectories() throws {
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories where directory.pathExtension == "partial" {
            let isDirectory = (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            try fileManager.removeItem(at: directory)
        }
    }

    private func recoverReplacedDirectories() throws {
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for replaced in directories where replaced.lastPathComponent.hasSuffix(".replaced") {
            let baseName = String(replaced.lastPathComponent.dropLast(".replaced".count))
            let completed = rootDirectory.appendingPathComponent(baseName, isDirectory: true)
            if fileManager.fileExists(atPath: completed.path) {
                try fileManager.removeItem(at: replaced)
            } else if try loadManifest(at: replaced) != nil {
                try fileManager.moveItem(at: replaced, to: completed)
            } else {
                try fileManager.removeItem(at: replaced)
            }
        }
    }

    private func removeIncompatibleCacheDirectories() throws {
        let protectedDirectories = Set(activePlaybackCounts.keys.map(\.directoryName))
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories where directory.pathExtension.isEmpty {
            let name = directory.lastPathComponent
            guard !protectedDirectories.contains(name) else { continue }
            if invalidatedCacheDirectories.contains(name) {
                try fileManager.removeItem(at: directory)
                invalidatedCacheDirectories.remove(name)
                completedManifests.removeValue(forKey: name)
                continue
            }
            guard try loadManifest(at: directory) != nil else {
                try fileManager.removeItem(at: directory)
                completedManifests.removeValue(forKey: name)
                continue
            }
        }
    }

    private nonisolated static func availableVolumeBytes(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return .max
        }
        return available
    }

    private func allocatedSize(of directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.reduce(into: Int64(0)) { total, element in
            guard let url = element as? URL,
                  let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]) else { return }
            total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
    }

    private func encode(_ frames: [VTFrame]) throws -> Data {
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

    private nonisolated static func decode(_ data: Data, maximumFrameCount: Int?) throws -> [VTFrame] {
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

    private nonisolated static func selectedFrameIndices(totalCount: Int, maximumFrameCount: Int?) -> Set<Int> {
        guard let maximumFrameCount,
              maximumFrameCount > 0,
              maximumFrameCount < totalCount else {
            return Set(0..<totalCount)
        }
        return Set((0..<maximumFrameCount).map { index in
            (2 * index + 1) * totalCount / (2 * maximumFrameCount)
        })
    }

    private func encodedAttachments(for buffer: CVPixelBuffer) -> Data? {
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

    private nonisolated static func applyAttachments(_ data: Data?, to buffer: CVPixelBuffer) {
        guard let data,
              let attachments = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return
        }
        for (key, value) in attachments {
            CVBufferSetAttachment(buffer, key as CFString, value as CFTypeRef, .shouldPropagate)
        }
    }
}
