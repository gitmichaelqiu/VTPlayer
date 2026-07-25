import SwiftUI
import AVKit
import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

#if os(iOS)
final class CustomAVPlayerViewController: AVPlayerViewController {
    var onControlsVisibilityChange: ((Bool) -> Void)?
    var isPipelineActive = false {
        didSet {
            applyPipelinePresentationIfNeeded()
        }
    }
    private var lastKnownVisibility = true
    private var checkTimer: Timer?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopTimer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        disableFullscreenButton(in: view)
        applyPipelinePresentation()
        checkControlsVisibility()
    }

    private func applyPipelinePresentationIfNeeded() {
        guard isViewLoaded else { return }
        applyPipelinePresentation()
        view.setNeedsLayout()
    }

    private func applyPipelinePresentation() {
        makeBackgroundsClear(in: view)
        hideVideoLayer(in: view)
    }

    private func hideVideoLayer(in view: UIView) {
        if view.layer is AVPlayerLayer {
            view.layer.isHidden = isPipelineActive
        }
        view.layer.sublayers?.forEach { sublayer in
            if sublayer is AVPlayerLayer { sublayer.isHidden = isPipelineActive }
        }
        view.subviews.forEach { hideVideoLayer(in: $0) }
    }

    private func startTimer() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            checkControlsVisibility()
            disableFullscreenButton(in: view)
        }
    }

    private func stopTimer() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    private func checkControlsVisibility() {
        if let controls = findControlsView(in: view) {
            let visible = !controls.isHidden && controls.alpha > 0.1 && controls.superview != nil
            if visible != lastKnownVisibility {
                lastKnownVisibility = visible
                onControlsVisibilityChange?(visible)
            }
        } else if !lastKnownVisibility {
            lastKnownVisibility = true
            onControlsVisibilityChange?(true)
        }
    }

    private func findControlsView(in view: UIView) -> UIView? {
        let className = String(describing: type(of: view))
        if className.contains("PlaybackControls") || className.contains("ControlsContainer") || className.contains("TransportBar") {
            return view
        }
        for subview in view.subviews {
            if let found = findControlsView(in: subview) { return found }
        }
        return nil
    }

    private func disableFullscreenButton(in view: UIView) {
        let className = String(describing: type(of: view))
        if className.contains("FullScreen") || className.contains("Fullscreen") {
            view.isUserInteractionEnabled = false
            view.alpha = 0.35
            (view as? UIControl)?.isEnabled = false
        }
        if let button = view as? UIButton {
            let image = button.currentImage?.description.lowercased() ?? ""
            let label = button.accessibilityLabel?.lowercased() ?? ""
            if image.contains("fullscreen") || image.contains("full-screen") || image.contains("arrow.up.left") || image.contains("arrow.down.right") || label.contains("fullscreen") || label.contains("full screen") {
                button.isEnabled = false
                button.isUserInteractionEnabled = false
                button.alpha = 0.35
            }
        }
        view.subviews.forEach { disableFullscreenButton(in: $0) }
    }

    private func makeBackgroundsClear(in view: UIView) {
        let className = String(describing: type(of: view))
        if className.contains("AVPlayerLayer") || className.contains("AVDisplayView") || className.contains("AVBackgroundView") {
            view.backgroundColor = isPipelineActive ? .clear : .black
            view.isOpaque = !isPipelineActive
        }
        if view == self.view {
            view.backgroundColor = isPipelineActive ? .clear : .black
            view.isOpaque = !isPipelineActive
        }
        view.subviews.forEach { makeBackgroundsClear(in: $0) }
    }
}

struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let isPipelineActive: Bool
    @Binding var showControls: Bool

    func makeUIViewController(context: Context) -> CustomAVPlayerViewController {
        let controller = CustomAVPlayerViewController()
        controller.player = player
        controller.isPipelineActive = isPipelineActive
        controller.showsPlaybackControls = true
        applyTitle(to: player.currentItem)
        controller.onControlsVisibilityChange = { visible in
            // AVPlayerViewController reports visibility from its main-thread
            // timer/layout callbacks. Update the binding in that same turn so
            // the SwiftUI overlay fades with the native controls instead of
            // lagging by an extra run-loop pass.
            self.showControls = visible
        }
        return controller
    }

    func updateUIViewController(_ controller: CustomAVPlayerViewController, context: Context) {
        controller.isPipelineActive = isPipelineActive
        if let item = player.currentItem, item.externalMetadata.isEmpty { applyTitle(to: item) }
    }

    private func applyTitle(to item: AVPlayerItem?) {
        guard let item else { return }
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        item.externalMetadata = [titleItem]
    }
}

private final class IOSNavigationBarHostController: UIViewController {
    var isNavigationBarHidden = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyNavigationBarVisibility(animated: false)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        applyNavigationBarVisibility(animated: false)
    }

    func applyNavigationBarVisibility(animated: Bool) {
        guard let navigationController = containingNavigationController() else { return }
        guard navigationController.isNavigationBarHidden != isNavigationBarHidden else { return }
        navigationController.setNavigationBarHidden(isNavigationBarHidden, animated: animated)
    }

    private func containingNavigationController() -> UINavigationController? {
        var ancestor = parent
        while let current = ancestor {
            if let navigationController = current as? UINavigationController {
                return navigationController
            }
            ancestor = current.parent
        }

        guard let windowRoot = viewIfLoaded?.window?.rootViewController else { return nil }
        return findNavigationController(in: windowRoot)
    }

    private func findNavigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigationController = controller as? UINavigationController {
            return navigationController
        }
        for child in controller.children.reversed() {
            if let navigationController = findNavigationController(in: child) {
                return navigationController
            }
        }
        return nil
    }
}
#endif

enum VideoPreviewGenerator {
    private static let memoryCache = NSCache<NSString, CGImage>()

    static func image(for asset: AVAsset, maximumSize: CGSize) -> CGImage? {
        let cacheKey = cacheKey(for: asset, maximumSize: maximumSize)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        if let cached = loadCachedImage(forKey: cacheKey) {
            memoryCache.setObject(cached, forKey: cacheKey as NSString)
            return cached
        }

        let image = generateImage(for: asset, maximumSize: maximumSize)
        if let image {
            memoryCache.setObject(image, forKey: cacheKey as NSString)
            saveCachedImage(image, forKey: cacheKey)
        }
        return image
    }

    private static func generateImage(for asset: AVAsset, maximumSize: CGSize) -> CGImage? {
        if let artwork = artworkImage(for: asset, maximumSize: maximumSize) {
            return artwork
        }

        let duration = CMTimeGetSeconds(asset.duration)
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
            guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            let score = visualScore(for: image)
            if score > bestScore {
                bestScore = score
                bestImage = image
            }
        }
        return bestImage
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
        guard let url = cacheURL(forKey: key), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
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
            try? FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
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

    private static func artworkImage(for asset: AVAsset, maximumSize: CGSize) -> CGImage? {
        guard let item = asset.commonMetadata.first(where: {
            $0.commonKey?.rawValue == "artwork" || $0.identifier?.rawValue.contains("artwork") == true
        }), let data = item.dataValue else {
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
        DispatchQueue.global(qos: .userInitiated).async {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let asset = AVURLAsset(url: url)
            Task {
                if let duration = try? await asset.load(.duration) {
                    let seconds = CMTimeGetSeconds(duration)
                    if seconds.isFinite {
                        let totalSeconds = Int(seconds)
                        let hours = totalSeconds / 3600
                        let mins = (totalSeconds % 3600) / 60
                        let secs = totalSeconds % 60
                        await MainActor.run {
                            if hours > 0 {
                                durationString = String(format: "%02d:%02d:%02d", hours, mins, secs)
                            } else {
                                durationString = String(format: "%d:%02d", mins, secs)
                            }
                        }
                    }
                }
            }
            let image = VideoPreviewGenerator.image(for: asset, maximumSize: CGSize(width: 180, height: 120))
            if let image {
                DispatchQueue.main.async { thumbnail = Image(decorative: image, scale: 1) }
            }
        }
    }
}
