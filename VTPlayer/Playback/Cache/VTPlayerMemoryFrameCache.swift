import Foundation
import CoreVideo
import CoreMedia

extension VTPlayerViewModel {
    func compactProcessedFrameCacheIfNeeded(force: Bool = false) {
        guard processedFrameCacheStart > 0 else { return }
        let totalCount = processedFrameCache.count
        if force || processedFrameCacheStart >= 64 || processedFrameCacheStart * 2 >= totalCount {
            let releasedBytes = processedFrameCache[..<processedFrameCacheStart].reduce(into: 0) { total, frame in
                total += CVPixelBufferGetDataSize(frame.buffer)
            }
            // Keep the cache storage and release only the consumed pixel
            // buffers. Rebuilding the array here briefly duplicates every
            // queued frame reference, which is costly for a large 4x cache.
            processedFrameCache.removeFirst(processedFrameCacheStart)
            processedFrameCacheStart = 0
            processedFrameCacheByteUsage = max(0, processedFrameCacheByteUsage - releasedBytes)
        }
    }

    func cacheCanAccept(_ byteCount: Int) -> Bool {
        guard byteCount <= frameCacheMemoryBudget else { return false }
        return processedFrameCacheByteUsage <= frameCacheMemoryBudget - byteCount
    }

    @discardableResult
    func insertProcessedFrameIntoCache(_ frame: VTFrame) -> Bool {
        let byteCount = CVPixelBufferGetDataSize(frame.buffer)
        guard cacheCanAccept(byteCount) else { return false }
        if byteCount > processedFrameByteEstimate {
            processedFrameByteEstimate = byteCount
        }

        let pts = frame.presentationTimeStamp
        if let last = processedFrameCache.last {
            let comparison = CMTimeCompare(last.presentationTimeStamp, pts)
            if comparison == 0 { return false }
            if comparison < 0 {
                processedFrameCache.append(frame)
                processedFrameCacheByteUsage += byteCount
                return true
            }
        } else {
            processedFrameCache.append(frame)
            processedFrameCacheByteUsage += byteCount
            return true
        }

        var lo = processedFrameCacheStart
        var hi = processedFrameCache.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if processedFrameCache[mid].presentationTimeStamp < pts {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo < processedFrameCache.count,
           CMTimeCompare(processedFrameCache[lo].presentationTimeStamp, pts) == 0 {
            return false
        }
        processedFrameCache.insert(frame, at: lo)
        processedFrameCacheByteUsage += byteCount
        return true
    }

    var bufferedFrameLimit: Int {
        let scale = max(1, max(superResolutionLevel, Float(qualitySuperResolutionScaleFactor)))
        let outputPixels = Double(videoWidth) * Double(videoHeight) * Double(scale * scale)
        guard outputPixels > 0 else { return maximumFrameCacheCount }

        // VideoToolbox normally returns YUV. Refine this fallback from the
        // actual processed buffers as soon as the producer has one, avoiding
        // an unnecessarily shallow cache for 4:2:0 output.
        let estimatedBytesPerFrame = processedFrameByteEstimate > 0
            ? Double(processedFrameByteEstimate)
            : max(1.0, outputPixels * 2.0)
        let budgetedFrames = Int(Double(frameCacheMemoryBudget) / estimatedBytesPerFrame)
        return min(maximumFrameCacheCount, max(2, budgetedFrames))
    }

    var resumeBufferFrameCount: Int {
        min(8, max(2, bufferedFrameLimit / 2))
    }

    var initialPrerollFrameCount: Int {
        // Startup only needs a small presentation reserve. Waiting for the
        // full cache capacity makes high-resolution videos appear frozen while
        // the producer fills several gigabytes, even though the consumer can
        // already render continuously. Keep the reserve bounded and reuse the
        // same conservative depth used when resuming from a pause.
        return min(bufferedFrameLimit, resumeBufferFrameCount)
    }

    var outputPresentationInterval: Double {
        guard sourceFrameRate > 0 else { return 1.0 / 30.0 }
        let multiplier: Double
        switch frameInterpolationLevel {
        case 4: multiplier = 4.0
        case 2: multiplier = 2.0
        default: multiplier = 1.0
        }
        return 1.0 / (sourceFrameRate * multiplier)
    }
}
