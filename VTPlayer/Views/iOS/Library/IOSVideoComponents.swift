import SwiftUI
import AVKit
import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
enum VideoPreviewGenerator {
    private static let memoryCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func image(for asset: AVAsset, maximumSize: CGSize) async -> CGImage? {
        let cacheKey = cacheKey(for: asset, maximumSize: maximumSize)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        if let cached = loadCachedImage(forKey: cacheKey) {
            memoryCache.setObject(cached, forKey: cacheKey as NSString)
            return cached
        }

        let image = await generateImage(for: asset, maximumSize: maximumSize)
        if let image {
            let cost = image.bytesPerRow * image.height
            memoryCache.setObject(image, forKey: cacheKey as NSString, cost: cost)
            saveCachedImage(image, forKey: cacheKey)
        }
        return image
    }

    private static func generateImage(for asset: AVAsset, maximumSize: CGSize) async -> CGImage? {
        if let artwork = await artworkImage(for: asset, maximumSize: maximumSize) {
            return artwork
        }

        guard let durationTime = try? await asset.load(.duration) else { return nil }
        let duration = CMTimeGetSeconds(durationTime)
        let durationSeconds = duration.isFinite && duration > 0 ? duration : 0
        let candidateSeconds = candidateTimes(for: durationSeconds)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var bestImage: CGImage?
        var bestScore = -Double.infinity
        for seconds in candidateSeconds {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let image = try? await generateImage(generator, at: time) else { continue }
            let score = visualScore(for: image)
            if score > bestScore {
                bestScore = score
                bestImage = image
            }
        }
        return bestImage
    }

    private static func generateImage(
        _ generator: AVAssetImageGenerator,
        at time: CMTime
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? NSError(
                        domain: "VTPlayer.VideoPreviewGenerator",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Preview image generation failed"]
                    ))
                }
            }
        }
    }

    private static func cacheKey(for asset: AVAsset, maximumSize: CGSize) -> String {
        let url = (asset as? AVURLAsset)?.url.standardizedFileURL
        let values = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) }
        let path = url?.path ?? "asset"
        let size = values?.fileSize ?? 0
        let modificationDate = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(modificationDate)|\(Int(maximumSize.width))x\(Int(maximumSize.height))"
    }

    private static var cacheDirectory: URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let cacheDirectory = directory.appendingPathComponent("VTPlayer/VideoPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        return cacheDirectory
    }

    private static func cacheURL(forKey key: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest).appendingPathExtension("png")
    }

    private static func loadCachedImage(forKey key: String) -> CGImage? {
        guard let url = cacheURL(forKey: key),
              FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func saveCachedImage(_ image: CGImage, forKey key: String) {
        guard let url = cacheURL(forKey: key) else { return }
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, "public.png" as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try? FileManager.default.moveItem(at: temporaryURL, to: url)
        }
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    private static func candidateTimes(for duration: Double) -> [Double] {
        guard duration > 0 else { return [0] }
        let candidates = [
            0.0,
            min(0.5, duration * 0.02),
            min(1.0, duration * 0.05),
            min(3.0, duration * 0.10),
            duration * 0.25,
            duration * 0.50
        ]
        return Array(Set(candidates.filter { $0 >= 0 && $0 < duration }))
            .sorted()
    }

    private static func artworkImage(for asset: AVAsset, maximumSize: CGSize) async -> CGImage? {
        guard let metadata = try? await asset.load(.commonMetadata),
              let item = metadata.first(where: {
            $0.commonKey?.rawValue == "artwork" || $0.identifier?.rawValue.contains("artwork") == true
        }), let data = try? await item.load(.dataValue) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maximumSize.width, maximumSize.height)
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func visualScore(for image: CGImage) -> Double {
        let width = 64
        let height = 64
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let luminances = stride(from: 0, to: pixels.count, by: 4).map { index in
            0.2126 * Double(pixels[index]) +
                0.7152 * Double(pixels[index + 1]) +
                0.0722 * Double(pixels[index + 2])
        }
        let mean = luminances.reduce(0, +) / Double(luminances.count)
        let variance = luminances.reduce(0) { partial, luminance in
            partial + (luminance - mean) * (luminance - mean)
        } / Double(luminances.count)
        let visibleRatio = Double(luminances.filter { $0 > 12 }.count) / Double(luminances.count)
        let contrastScore = min(sqrt(variance) / 64.0, 1.0)
        return visibleRatio * 0.7 + contrastScore * 0.3
    }
}
struct VideoThumbnailView: View {
    let url: URL
    var width: CGFloat = 90
    var height: CGFloat = 60
    @State private var thumbnail: Image?
    @State private var durationString: String?
    @State private var didStartLoading = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail {
                thumbnail.resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height).clipped()
            } else {
                Color.gray.opacity(0.15).frame(width: width, height: height)
                    .overlay(Image(systemName: "video.fill").font(.body).foregroundStyle(.secondary))
            }
            if let durationString {
                Text(durationString).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color.black.opacity(0.75)).cornerRadius(3).padding(4)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear {
            guard !didStartLoading else { return }
            didStartLoading = true
            loadMetadata()
        }
    }

    private func loadMetadata() {
        Task.detached(priority: .userInitiated) { [url] in
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let asset = AVURLAsset(url: url)
            let duration = try? await asset.load(.duration)
            let image = await VideoPreviewGenerator.image(for: asset, maximumSize: CGSize(width: 180, height: 120))

            await MainActor.run {
                if let duration {
                    let seconds = CMTimeGetSeconds(duration)
                    if seconds.isFinite {
                        let totalSeconds = Int(seconds)
                        let hours = totalSeconds / 3600
                        let mins = (totalSeconds % 3600) / 60
                        let secs = totalSeconds % 60
                        if hours > 0 {
                            durationString = String(format: "%02d:%02d:%02d", hours, mins, secs)
                        } else {
                            durationString = String(format: "%d:%02d", mins, secs)
                        }
                    }
                }
                if let image {
                    thumbnail = Image(decorative: image, scale: 1)
                }
            }
        }
    }
}
