import CoreMedia
@preconcurrency import CoreVideo
import CryptoKit
import Foundation

nonisolated struct EnhancedFrameCacheKey: Codable, Equatable, Hashable, Sendable {
    static let schemaVersion = 3

    var sourceFingerprint: String
    var configuration: AppliedPipelineConfiguration

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
        guard coverageBitmap.count == requiredCoverage.count else { return false }
        return requiredCoverage.indices.allSatisfy {
            !requiredCoverage[$0] || availableGroupIndices.contains($0)
        }
    }
}

nonisolated enum EnhancedFrameDiskCacheError: LocalizedError {
    case insufficientCapacity(requiredBytes: Int64, availableBytes: Int64)
    case cacheNotPrepared
    case invalidFrameData

    var errorDescription: String? {
        switch self {
        case let .insufficientCapacity(requiredBytes, availableBytes):
            return "Enhanced-frame cache needs \(requiredBytes) bytes, but only \(availableBytes) bytes are available."
        case .cacheNotPrepared:
            return "Enhanced-frame cache has not been prepared."
        case .invalidFrameData:
            return "Enhanced-frame cache contains invalid frame data."
        }
    }
}

/// Actor-isolated, raw-pixel disk storage for enhanced output. A completed
/// cache is never modified in place: preparation writes an adjacent partial
/// directory and atomically promotes it only after its manifest is complete.
actor EnhancedFrameDiskCache {
    static let shared = EnhancedFrameDiskCache()
    private static let manifestFilename = "manifest.json"
    private static let accessPersistenceInterval: TimeInterval = 30

    private struct Manifest: Codable, Sendable {
        var schemaVersion: Int
        var key: EnhancedFrameCacheKey
        var coverageBitmap: [Bool]
        var groups: [GroupEntry]
        var lastAccess: Date
        var byteCount: Int64
    }

    private struct GroupEntry: Codable, Equatable, Sendable {
        var groupIndex: Int
        var filename: String?
        var byteCount: Int64
        var sourcePresentationSeconds: Double
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
    private var completedManifests: [String: Manifest] = [:]
    private var activePlaybackCounts: [EnhancedFrameCacheKey: Int] = [:]

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
        digest.update(data: Data("\(resourceValues.fileSize ?? 0)|\(resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0)".utf8))

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sampleSize = 1_024 * 1_024
        let fileSize = Int64(resourceValues.fileSize ?? 0)
        if let first = try handle.read(upToCount: sampleSize) {
            digest.update(data: first)
        }
        if fileSize > Int64(sampleSize) {
            try handle.seek(toOffset: UInt64(fileSize - Int64(sampleSize)))
            if let last = try handle.read(upToCount: sampleSize) {
                digest.update(data: last)
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
    ) throws -> EnhancedFrameCacheStatus {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
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

        try discardPreparation()
        let partial = rootDirectory.appendingPathComponent("\(key.directoryName).partial", isDirectory: true)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)

        var entries: [GroupEntry] = []
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
        }

        let manifest = Manifest(
            schemaVersion: EnhancedFrameCacheKey.schemaVersion,
            key: key,
            coverageBitmap: coverageBitmap,
            groups: entries,
            lastAccess: .now,
            byteCount: entries.reduce(0) { $0 + $1.byteCount }
        )
        partialDirectory = partial
        preparedManifest = manifest
        activePreparationIdentifier = preparationIdentifier
        try writeManifest(manifest, to: partial)
        return status(for: manifest, preparationIdentifier: preparationIdentifier)
    }

    func writeGroup(
        _ frames: [VTFrame],
        for groupIndex: Int,
        sourcePresentationTime: CMTime? = nil,
        preparationIdentifier: UUID? = nil
    ) throws {
        guard let partialDirectory, var manifest = preparedManifest else {
            throw EnhancedFrameDiskCacheError.cacheNotPrepared
        }
        guard preparationIdentifier == nil || preparationIdentifier == activePreparationIdentifier else {
            throw CancellationError()
        }
        guard manifest.coverageBitmap.indices.contains(groupIndex), manifest.coverageBitmap[groupIndex] else { return }

        let filename = String(format: "group-%08d.raw", groupIndex)
        let destination = partialDirectory.appendingPathComponent(filename)
        let temporary = partialDirectory.appendingPathComponent("\(filename).tmp")
        let encoded = try encode(frames)
        try encoded.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)

        manifest.groups.removeAll { $0.groupIndex == groupIndex }
        let sourceSeconds = CMTimeGetSeconds(sourcePresentationTime ?? frames.last?.presentationTimeStamp ?? .zero)
        manifest.groups.append(GroupEntry(
            groupIndex: groupIndex,
            filename: filename,
            byteCount: Int64(encoded.count),
            sourcePresentationSeconds: sourceSeconds.isFinite ? sourceSeconds : 0
        ))
        manifest.groups.sort { $0.groupIndex < $1.groupIndex }
        manifest.byteCount = manifest.groups.reduce(0) { $0 + $1.byteCount }
        manifest.lastAccess = .now
        preparedManifest = manifest
        try writeManifest(manifest, to: partialDirectory)
    }

    func recordSourceGroup(
        _ groupIndex: Int,
        presentationTime: CMTime,
        preparationIdentifier: UUID? = nil
    ) throws {
        guard let partialDirectory, var manifest = preparedManifest else {
            throw EnhancedFrameDiskCacheError.cacheNotPrepared
        }
        guard preparationIdentifier == nil || preparationIdentifier == activePreparationIdentifier else {
            throw CancellationError()
        }
        guard !manifest.groups.contains(where: { $0.groupIndex == groupIndex }) else { return }
        let seconds = CMTimeGetSeconds(presentationTime)
        manifest.groups.append(GroupEntry(
            groupIndex: groupIndex,
            filename: nil,
            byteCount: 0,
            sourcePresentationSeconds: seconds.isFinite ? seconds : 0
        ))
        manifest.groups.sort { $0.groupIndex < $1.groupIndex }
        preparedManifest = manifest
        try writeManifest(manifest, to: partialDirectory)
    }

    func finalizePreparation(
        actualGroupCount: Int? = nil,
        preparationIdentifier: UUID? = nil
    ) throws -> EnhancedFrameCacheStatus {
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
        completedManifests[manifest.key.directoryName] = manifest
        return status(for: manifest)
    }

    func discardPreparation(preparationIdentifier: UUID? = nil) throws {
        guard preparationIdentifier == nil || preparationIdentifier == activePreparationIdentifier else { return }
        if let partialDirectory, fileManager.fileExists(atPath: partialDirectory.path) {
            try fileManager.removeItem(at: partialDirectory)
        }
        partialDirectory = nil
        preparedManifest = nil
        activePreparationIdentifier = nil
    }

    func readGroup(_ groupIndex: Int, for key: EnhancedFrameCacheKey) throws -> [VTFrame]? {
        let directory = directory(for: key)
        guard var manifest = try completedManifest(for: key), manifest.key == key,
              let entry = manifest.groups.first(where: { $0.groupIndex == groupIndex }),
              let filename = entry.filename else {
            return nil
        }
        let data = try Data(contentsOf: directory.appendingPathComponent(filename))
        let frames = try decode(data)
        let now = Date.now
        let directoryName = key.directoryName
        if now.timeIntervalSince(manifest.lastAccess) >= Self.accessPersistenceInterval {
            manifest.lastAccess = now
            try writeManifest(manifest, to: directory)
            completedManifests[directoryName] = manifest
        }
        return frames
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
        }
    }

    func diskUsageBytes() throws -> Int64 {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return 0 }
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
        let seconds = CMTimeGetSeconds(presentationTime)
        guard seconds.isFinite else { return manifest.groups.first?.groupIndex }
        return manifest.groups.first(where: { $0.sourcePresentationSeconds >= seconds })?.groupIndex
            ?? manifest.groups.last?.groupIndex
    }

    func groupIndex(closestTo presentationTime: CMTime, for key: EnhancedFrameCacheKey) throws -> Int? {
        guard let manifest = try completedManifest(for: key), manifest.key == key else { return nil }
        let seconds = CMTimeGetSeconds(presentationTime)
        guard seconds.isFinite else { return nil }
        return manifest.groups.min {
            abs($0.sourcePresentationSeconds - seconds) < abs($1.sourcePresentationSeconds - seconds)
        }?.groupIndex
    }

    private func directory(for key: EnhancedFrameCacheKey) -> URL {
        rootDirectory.appendingPathComponent(key.directoryName, isDirectory: true)
    }

    private func completedManifest(for key: EnhancedFrameCacheKey) throws -> Manifest? {
        let directoryName = key.directoryName
        if let manifest = completedManifests[directoryName] {
            return manifest
        }
        guard let manifest = try loadManifest(at: directory(for: key)), manifest.key == key else {
            return nil
        }
        completedManifests[directoryName] = manifest
        return manifest
    }

    private func status(
        for manifest: Manifest,
        preparationIdentifier: UUID? = nil
    ) -> EnhancedFrameCacheStatus {
        EnhancedFrameCacheStatus(
            key: manifest.key,
            coverageBitmap: manifest.coverageBitmap,
            availableGroupIndices: Set(manifest.groups.compactMap { $0.filename == nil ? nil : $0.groupIndex }),
            byteCount: manifest.byteCount,
            preparationIdentifier: preparationIdentifier
        )
    }

    private func loadManifest(at directory: URL) throws -> Manifest? {
        let url = directory.appendingPathComponent(Self.manifestFilename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == EnhancedFrameCacheKey.schemaVersion else { return nil }
        return manifest
    }

    private func writeManifest(_ manifest: Manifest, to directory: URL) throws {
        let data = try JSONEncoder().encode(manifest)
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
        let availableBeforeEviction = max(0, diskBudgetBytes - usedBytes)
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
            let available = max(0, diskBudgetBytes - usedBytes)
            if available >= requiredAdditionalBytes { return available }
        }
        return max(0, diskBudgetBytes - usedBytes)
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

    private func decode(_ data: Data) throws -> [VTFrame] {
        guard data.count >= MemoryLayout<UInt64>.size else { throw EnhancedFrameDiskCacheError.invalidFrameData }
        let headerLength = data.prefix(MemoryLayout<UInt64>.size).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let headerStart = MemoryLayout<UInt64>.size
        let headerEnd = headerStart + Int(headerLength)
        guard headerEnd <= data.count else { throw EnhancedFrameDiskCacheError.invalidFrameData }
        let header = try JSONDecoder().decode(GroupHeader.self, from: data[headerStart..<headerEnd])
        var payloadOffset = headerEnd
        return try header.frames.map { frameHeader in
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
            for (index, plane) in frameHeader.planes.enumerated() {
                let destinationBytesPerRow = planeCount == 0 ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
                let destinationHeight = planeCount == 0 ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, index)
                guard destinationBytesPerRow >= plane.bytesPerRow, destinationHeight >= plane.height,
                      payloadOffset + plane.byteCount <= data.count else {
                    throw EnhancedFrameDiskCacheError.invalidFrameData
                }
                let destination = planeCount == 0 ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, index)
                guard let destination else { throw EnhancedFrameDiskCacheError.invalidFrameData }
                data.withUnsafeBytes { source in
                    for row in 0..<plane.height {
                        memcpy(
                            destination.advanced(by: row * destinationBytesPerRow),
                            source.baseAddress!.advanced(by: payloadOffset + row * plane.bytesPerRow),
                            plane.bytesPerRow
                        )
                    }
                }
                payloadOffset += plane.byteCount
            }
            applyAttachments(frameHeader.attachmentData, to: buffer)
            let time = CMTime(
                value: frameHeader.presentationTimeValue,
                timescale: frameHeader.presentationTimeScale,
                flags: CMTimeFlags(rawValue: frameHeader.presentationTimeFlags),
                epoch: 0
            )
            return VTFrame(buffer: buffer, presentationTimeStamp: time, isInterpolated: frameHeader.isInterpolated)
        }
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

    private func applyAttachments(_ data: Data?, to buffer: CVPixelBuffer) {
        guard let data,
              let attachments = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return
        }
        for (key, value) in attachments {
            CVBufferSetAttachment(buffer, key as CFString, value as CFTypeRef, .shouldPropagate)
        }
    }
}
