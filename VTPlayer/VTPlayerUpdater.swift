#if os(macOS)
import AppKit
import Sparkle

/// Owns the application's Sparkle updater for the lifetime of the app.
///
/// Sparkle requires both an appcast URL and an EdDSA public key before it can
/// start safely. Keeping the controller optional prevents a development build
/// from presenting a configuration error when those release settings have not
/// been added yet.
@MainActor
final class VTPlayerUpdater: NSObject {
    static let shared = VTPlayerUpdater()

    private let controller: SPUStandardUpdaterController?

    private override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let hasFeedURL = (info["SUFeedURL"] as? String)?.isEmpty == false
        let hasPublicKey = (info["SUPublicEDKey"] as? String)?.isEmpty == false

        if hasFeedURL && hasPublicKey {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            controller = nil
        }

        super.init()
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
#endif
