import SwiftUI
import Combine

@MainActor
final class CCRAutoStartCoordinator {
    private var task: Task<Void, Never>?
    private var generation = 0

    func schedule(
        delayNanoseconds: UInt64,
        operation: @escaping @MainActor () async -> Void
    ) {
        cancel()
        generation += 1
        let scheduledGeneration = generation
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await operation()
            guard let self, self.generation == scheduledGeneration else { return }
            self.task = nil
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}

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

    private let autoStartCoordinator = CCRAutoStartCoordinator()
    private var autoStartGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var stateSubscriptions: Set<AnyCancellable> = []

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

        // MenuBarView observes AppState as its single environment object. Forward
        // nested model changes so status text, buttons, and runtime errors refresh
        // immediately after start/stop commands complete.
        for publisher in [
            resolver.objectWillChange,
            serviceManager.objectWillChange,
            statusMonitor.objectWillChange
        ] {
            publisher
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &stateSubscriptions)
        }
    }

    func start() {
        updateManager.start()
        resolver.refresh()
        statusMonitor.start(managementPort: managementPortValue)

        if autoStartCCR && resolver.canRunCCR {
            statusMonitor.setStarting()
            let generation = autoStartGeneration
            autoStartCoordinator.schedule(delayNanoseconds: 1_500_000_000) { [weak self] in
                guard let self else { return }
                await self.startAutomaticallyIfNeeded(generation: generation)
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
        refreshStatus()
    }

    func refreshStatus() {
        Task {
            await statusMonitor.check(managementPort: managementPortValue)
        }
    }

    func startCCR(port: UInt16, startGateway: Bool) async {
        cancelPendingAutoStart()
        await serviceManager.start(port: port, startGateway: startGateway)
    }

    func stopCCR() async {
        cancelPendingAutoStart()
        await serviceManager.stop()
    }

    func restartCCR(port: UInt16) async {
        cancelPendingAutoStart()
        await serviceManager.restart(port: port)
    }

    func managementPortChanged() {
        let port = managementPortValue
        let wasRunning = statusMonitor.status != .stopped
        Task {
            await statusMonitor.check(managementPort: port)
            guard wasRunning else { return }
            await restartCCR(port: port)
        }
    }

    func checkForUpdates() {
        updateManager.checkForUpdates()
    }

    private func cancelPendingAutoStart() {
        autoStartGeneration += 1
        autoStartCoordinator.cancel()
    }

    private func startAutomaticallyIfNeeded(generation: Int) async {
        guard generation == autoStartGeneration, !Task.isCancelled else { return }
        await statusMonitor.check(managementPort: managementPortValue)
        guard generation == autoStartGeneration, !Task.isCancelled else { return }
        guard statusMonitor.status != .running else { return }
        await serviceManager.start(
            port: managementPortValue,
            startGateway: !statusMonitor.gatewayUp
        )
    }
}
