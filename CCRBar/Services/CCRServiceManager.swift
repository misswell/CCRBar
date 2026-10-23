import AppKit
import Foundation
import Combine

@MainActor
protocol CCRExecutableResolving: AnyObject {
    var runtime: CCRRuntime { get }
    var environment: [String: String]? { get }
}

extension CCRExecutableResolver: CCRExecutableResolving {}

@MainActor
final class CCRServiceManager: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var isStopping = false
    @Published private(set) var lastCommand: String?
    @Published private(set) var lastResult: CommandResult?

    private let resolver: CCRExecutableResolving
    private let statusMonitor: CCRStatusMonitor
    private let gatewayConfigurationManager: CCRGatewayConfigurationManaging
    private let startLock: CCRStartLocking
    private let commandExecutor: @Sendable (String, [String], [String: String]?) -> CommandResult
    private var operationTask: Task<Void, Never>?
    private var operationGeneration = 0
    private var activeOperationCount = 0
    private var stopRequestCount = 0

    init(
        resolver: CCRExecutableResolving,
        statusMonitor: CCRStatusMonitor,
        gatewayConfigurationManager: CCRGatewayConfigurationManaging? = nil,
        startLock: CCRStartLocking? = nil,
        commandExecutor: @escaping @Sendable (String, [String], [String: String]?) -> CommandResult = {
            CommandRunner.run(executable: $0, arguments: $1, environment: $2)
        }
    ) {
        self.resolver = resolver
        self.statusMonitor = statusMonitor
        self.gatewayConfigurationManager = gatewayConfigurationManager ?? CCRWebConfigurationClient()
        self.startLock = startLock ?? CCRStartLock()
        self.commandExecutor = commandExecutor
    }

    var lastErrorText: String? {
        guard let result = lastResult, result.exitCode != 0 else { return nil }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty
            ? String(localized: "Command failed with exit code \(Int(result.exitCode))")
            : stderr
    }

    func start(
        port: UInt16,
        gatewayHost: String = AppSettings.defaultGatewayHost,
        startGateway: Bool = true
    ) async {
        beginOperation()
        defer { endOperation() }

        await enqueueOperation { [weak self] in
            guard let self else { return }
            guard await self.startLock.acquire() else { return }
            defer { self.startLock.release() }

            _ = await self.startIfNeeded(
                managementPort: port,
                gatewayHost: gatewayHost,
                startGateway: startGateway
            )
        }
    }

    func currentGatewayHost() async -> String? {
        try? await gatewayConfigurationManager.currentGatewayHost()
    }

    @discardableResult
    func updateGatewayHost(_ host: String) async -> Bool {
        do {
            try await gatewayConfigurationManager.updateGatewayHost(host)
            lastResult = CommandResult(stdout: "", stderr: "", exitCode: 0)
            return true
        } catch {
            lastCommand = "CCR Gateway configuration"
            lastResult = CommandResult(
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: -1
            )
            return false
        }
    }

    func stop() async {
        beginOperation()
        beginStopRequest()
        defer {
            endStopRequest()
            endOperation()
        }

        statusMonitor.setStopping()
        await enqueueOperation { [weak self] in
            guard let self else { return }
            self.statusMonitor.setStopping()
            _ = await self.runCommand(["stop"])
            await self.statusMonitor.check()
        }
    }

    func restart(
        port: UInt16,
        gatewayHost: String = AppSettings.defaultGatewayHost
    ) async {
        beginOperation()
        defer { endOperation() }

        await enqueueOperation { [weak self] in
            guard let self else { return }
            guard await self.startLock.acquire() else { return }
            defer { self.startLock.release() }

            self.statusMonitor.setStopping()
            _ = await self.runCommand(["stop"])
            await self.statusMonitor.check()
            try? await Task.sleep(nanoseconds: 500_000_000)

            _ = await self.startIfNeeded(
                managementPort: port,
                gatewayHost: gatewayHost,
                startGateway: true
            )
        }
    }

    private func finishStarting(
        managementPort: UInt16,
        gatewayHost: String,
        commandSucceeded: Bool,
        updateGateway: Bool
    ) async {
        if commandSucceeded && updateGateway {
            _ = await updateGatewayHost(gatewayHost)
        }
        await statusMonitor.check(
            managementPort: managementPort,
            gatewayHost: gatewayHost
        )
    }

    @discardableResult
    private func startIfNeeded(
        managementPort: UInt16,
        gatewayHost: String,
        startGateway: Bool
    ) async -> Bool {
        // A second CCRBar instance can enter this method after the first one
        // has already started CCR. Re-check while holding the cross-process
        // lock so the second instance reuses the running service instead of
        // launching another gateway.
        await statusMonitor.check(
            managementPort: managementPort,
            gatewayHost: gatewayHost
        )
        if statusMonitor.managementUp || statusMonitor.gatewayUp {
            markStartSatisfied()
            return true
        }

        statusMonitor.setStarting()
        var arguments = ["start", "--port", String(managementPort), "--no-open"]
        if !startGateway {
            arguments.append("--no-gateway")
        }

        let commandSucceeded = await runCommand(arguments)
        let serviceBecameReachable: Bool
        if commandSucceeded {
            serviceBecameReachable = false
        } else {
            serviceBecameReachable = await serviceIsReachable(
                managementPort: managementPort,
                gatewayHost: gatewayHost
            )
        }
        let succeeded = commandSucceeded || serviceBecameReachable

        await finishStarting(
            managementPort: managementPort,
            gatewayHost: gatewayHost,
            commandSucceeded: succeeded,
            updateGateway: startGateway
        )
        return succeeded
    }

    private func serviceIsReachable(
        managementPort: UInt16,
        gatewayHost: String
    ) async -> Bool {
        await statusMonitor.check(
            managementPort: managementPort,
            gatewayHost: gatewayHost
        )
        return statusMonitor.managementUp || statusMonitor.gatewayUp
    }

    private func markStartSatisfied() {
        lastResult = CommandResult(stdout: "", stderr: "", exitCode: 0)
    }

    func openDashboard(port: UInt16, managementIsUp: Bool) {
        // A running management service already serves the UI, but the page's
        // RPC calls need the token from service.json. That descriptor lives in
        // the CCR data folder and can disappear independently of the process.
        if managementIsUp, let url = Self.managementURL(port: port) {
            lastCommand = "open http://\(AppSettings.defaultGatewayHost):\(port)/"
            let opened = NSWorkspace.shared.open(url)
            lastResult = opened
                ? CommandResult(stdout: "", stderr: "", exitCode: 0)
                : CommandResult(stdout: "", stderr: String(localized: "Failed to open the CCR management page"), exitCode: -1)
            return
        }

        guard resolver.runtime.canRun, let ccrPath = resolver.runtime.ccrPath else {
            lastResult = CommandResult(
                stdout: "",
                stderr: String(localized: "The CCR management page is unavailable. Restart CCR to recreate it."),
                exitCode: -1
            )
            return
        }
        lastCommand = "ccr ui --port \(port)"
        let launched = CommandRunner.launch(
            executable: ccrPath,
            arguments: resolver.runtime.launchArguments + ["ui", "--port", String(port)],
            environment: resolver.environment
        )
        lastResult = launched
            ? CommandResult(stdout: "", stderr: "", exitCode: 0)
            : CommandResult(stdout: "", stderr: String(localized: "Failed to launch ccr ui"), exitCode: -1)
    }

    nonisolated static func managementURL(
        port: UInt16,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL? {
        let descriptorURL = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".claude-code-router/service.json")
        guard let data = try? Data(contentsOf: descriptorURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = object["url"] as? String,
              let url = URL(string: urlString),
              url.port == Int(port),
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "ccr_web_token" })?.value,
              !token.isEmpty else {
            return nil
        }
        return url
    }

    func clearLastError() {
        lastCommand = nil
        lastResult = nil
    }

    private func beginOperation() {
        activeOperationCount += 1
        isBusy = true
    }

    private func endOperation() {
        activeOperationCount = max(0, activeOperationCount - 1)
        isBusy = activeOperationCount > 0
    }

    private func beginStopRequest() {
        stopRequestCount += 1
        isStopping = true
    }

    private func endStopRequest() {
        stopRequestCount = max(0, stopRequestCount - 1)
        isStopping = stopRequestCount > 0
    }

    private func enqueueOperation(_ operation: @escaping @MainActor () async -> Void) async {
        operationGeneration += 1
        let generation = operationGeneration
        let previous = operationTask
        let current = Task { @MainActor [weak self] in
            await previous?.value
            await operation()
            guard let self, self.operationGeneration == generation else { return }
            self.operationTask = nil
        }
        operationTask = current
        await current.value
    }

    private func runCommand(_ arguments: [String]) async -> Bool {
        guard resolver.runtime.canRun, let ccrPath = resolver.runtime.ccrPath else {
            lastResult = CommandResult(stdout: "", stderr: String(localized: "ccr not installed"), exitCode: -1)
            return false
        }

        let command = "ccr \(arguments.joined(separator: " "))"
        lastCommand = command

        let environment = resolver.environment
        let commandExecutor = commandExecutor
        let launchArguments = resolver.runtime.launchArguments + arguments
        let result = await Task.detached(priority: .userInitiated) {
            commandExecutor(ccrPath, launchArguments, environment)
        }.value

        lastResult = result
        return result.exitCode == 0
    }
}
