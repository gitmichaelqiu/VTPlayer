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

struct IOSPlayerLifecycleObserver: UIViewControllerRepresentable {
    let isTabBarHidden: Bool
    let onDidAppear: () -> Void
    let onWillDisappear: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = IOSPlayerLifecycleViewController()
        controller.isTabBarHidden = isTabBarHidden
        controller.onDidAppear = onDidAppear
        controller.onWillDisappear = onWillDisappear
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let controller = controller as? IOSPlayerLifecycleViewController else { return }
        controller.isTabBarHidden = isTabBarHidden
        controller.onDidAppear = onDidAppear
        controller.onWillDisappear = onWillDisappear
        controller.applyTabBarVisibility(animated: true)
    }
}

private final class IOSPlayerLifecycleViewController: UIViewController {
    var isTabBarHidden = false
    var onDidAppear: (() -> Void)?
    var onWillDisappear: (() -> Void)?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hideNavigationBackButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyTabBarVisibility(animated: false)
        hideNavigationBackButton()
        onDidAppear?()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        hideNavigationBackButton()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onWillDisappear?()
    }

    func applyTabBarVisibility(animated: Bool) {
        IOSPlayerTabBarController.setHidden(isTabBarHidden, animated: animated)
        hideNavigationBackButton()
    }

    private func hideNavigationBackButton() {
        var ancestor = parent
        while let current = ancestor {
            if let navigationController = current as? UINavigationController {
                navigationController.topViewController?.navigationItem.hidesBackButton = true
                return
            }
            ancestor = current.parent
        }
    }
}

enum IOSPlayerTabBarController {
    static func setHidden(_ hidden: Bool, animated: Bool) {
        guard let tabBarController = activeTabBarController() else { return }
        let tabBar = tabBarController.tabBar
        if hidden {
            guard !tabBar.isHidden else { return }
            if animated {
                UIView.animate(withDuration: 0.25, animations: {
                    tabBar.alpha = 0
                }, completion: { _ in
                    tabBar.isHidden = true
                    tabBar.alpha = 1
                })
            } else {
                tabBar.isHidden = true
            }
        } else {
            guard tabBar.isHidden || tabBar.alpha < 1 else { return }
            tabBar.isHidden = false
            if animated {
                tabBar.alpha = 0
                UIView.animate(withDuration: 0.25) {
                    tabBar.alpha = 1
                }
            } else {
                tabBar.alpha = 1
            }
        }
    }

    private static func activeTabBarController() -> UITabBarController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState != .unattached {
            for window in scene.windows where window.isKeyWindow || window.windowLevel == .normal {
                if let controller = findTabBarController(in: window.rootViewController) {
                    return controller
                }
            }
        }
        return nil
    }

    private static func findTabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabBarController = controller as? UITabBarController { return tabBarController }
        for child in controller.children.reversed() {
            if let tabBarController = findTabBarController(in: child) { return tabBarController }
        }
        return nil
    }
}
#endif


