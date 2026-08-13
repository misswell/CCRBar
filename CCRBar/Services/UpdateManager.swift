import Sparkle

@MainActor
final class UpdateManager {
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func start() {
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        guard updaterController.updater.canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }
}
