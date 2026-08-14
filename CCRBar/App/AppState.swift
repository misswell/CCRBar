import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let resolver: CCRExecutableResolver
    let serviceManager: CCRServiceManager
    let statusMonitor: CCRStatusMonitor
    let updateManager: UpdateManager

    @AppStorage("autoStartCCR") var autoStartCCR = true
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage(AppSettings.managementPortKey) private var storedManagementPort = Int(AppSettings.defaultManagementPort)

    private var observers: [NSObjectProtocol] = []

    var managementPort: Int {
        get { Int(AppSettings.validatedManagementPort(storedManagementPort)) }
        set { storedManagementPort = Int(AppSettings.validatedManagementPort(newValue)) }
    }

    var managementPortValue: UInt16 {
        AppSettings.validatedManagementPort(managementPort)
    }

    init() {
        resolver = CCRExecutableResolver()
        statusMonitor = CCRStatusMonitor()
        serviceManager = CCRServiceManager(resolver: resolver, statusMonitor: statusMonitor)
        updateManager = UpdateManager()

        // Preserve an explicit old opt-out, while making the new default apply
        // to existing installs that never changed the setting.
        if UserDefaults.standard.object(forKey: "autoStartCCR") == nil {
            UserDefaults.standard.set(true, forKey: "autoStartCCR")
        }
        launchAtLogin = LoginItemManager.isEnabled
    }

    func start() {
        updateManager.start()
        resolver.refresh()
        statusMonitor.start(managementPort: managementPortValue)

        if autoStartCCR && resolver.canRunCCR {
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await statusMonitor.check(managementPort: managementPortValue)
                if statusMonitor.status != .running {
                    await serviceManager.start(
                        port: managementPortValue,
                        startGateway: !statusMonitor.gatewayUp
                    )
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
                guard let self else { return }
                await self.statusMonitor.check(managementPort: self.managementPortValue)
            }
        })
    }

    func refresh() {
        resolver.refresh()
        Task {
            await statusMonitor.check(managementPort: managementPortValue)
        }
    }

    func managementPortChanged() {
        let port = managementPortValue
        let wasRunning = statusMonitor.status != .stopped
        Task {
            await statusMonitor.check(managementPort: port)
            guard wasRunning else { return }
            await serviceManager.restart(port: port)
        }
    }

    func checkForUpdates() {
        updateManager.checkForUpdates()
    }
}
