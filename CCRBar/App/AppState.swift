import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let resolver: CCRExecutableResolver
    let serviceManager: CCRServiceManager
    let statusMonitor: CCRStatusMonitor
    let updateManager: UpdateManager

    @AppStorage("autoStartCCR") var autoStartCCR = false
    @AppStorage("launchAtLogin") var launchAtLogin = false

    private var hasStartedCCR = false
    private var observers: [NSObjectProtocol] = []

    init() {
        resolver = CCRExecutableResolver()
        statusMonitor = CCRStatusMonitor()
        serviceManager = CCRServiceManager(resolver: resolver, statusMonitor: statusMonitor)
        updateManager = UpdateManager()
        launchAtLogin = LoginItemManager.isEnabled
    }

    func start() {
        updateManager.start()
        resolver.refresh()
        statusMonitor.start()

        if autoStartCCR && resolver.isCCRInstalled && resolver.nodeMeetsRequirement {
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await statusMonitor.check()
                if statusMonitor.status == .stopped {
                    await serviceManager.start()
                    hasStartedCCR = true
                }
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.statusMonitor.check()
            }
        })
    }

    func refresh() {
        resolver.refresh()
        Task {
            await statusMonitor.check()
        }
    }

    func checkForUpdates() {
        updateManager.checkForUpdates()
    }
}
