import SwiftUI
import AVKit
import AVFoundation

#if os(iOS)
final class CustomAVPlayerViewController: AVPlayerViewController {
    var onControlsVisibilityChange: ((Bool) -> Void)?
    var isPipelineActive = false
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
        makeBackgroundsClear(in: view)
        hideVideoLayer(in: view)
        checkControlsVisibility()
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

    func updatePipelinePresentation() {
        hideVideoLayer(in: view)
        makeBackgroundsClear(in: view)
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
        controller.player = player
        controller.isPipelineActive = isPipelineActive
        controller.updatePipelinePresentation()
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
#endif

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
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 120)
            let previewTime = CMTime(seconds: 1, preferredTimescale: 600)
            let image = (try? generator.copyCGImage(at: previewTime, actualTime: nil))
                ?? (try? generator.copyCGImage(at: .zero, actualTime: nil))
            if let image {
                DispatchQueue.main.async { thumbnail = Image(decorative: image, scale: 1) }
            }
        }
    }
}
