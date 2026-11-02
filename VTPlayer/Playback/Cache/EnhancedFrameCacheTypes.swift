import CryptoKit
import Foundation

nonisolated struct EnhancedFrameCacheKey: Codable, Equatable, Hashable, Sendable {
    static let schemaVersion = 7
    static let currentHEVCChunkFormatVersion = 6
    static let currentProcessingPipelineVersion = 2
    static let currentQualitySRProcessingPipelineVersion = 3
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

