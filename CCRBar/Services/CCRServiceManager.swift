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
    private let commandExecutor: @Sendable (String, [String], [String: String]?) -> CommandResult
    private var operationTask: Task<Void, Never>?
    private var operationGeneration = 0
    private var activeOperationCount = 0
    private var stopRequestCount = 0

    init(
        resolver: CCRExecutableResolving,
        statusMonitor: CCRStatusMonitor,
        commandExecutor: @escaping @Sendable (String, [String], [String: String]?) -> CommandResult = {
            CommandRunner.run(executable: $0, arguments: $1, environment: $2)
        }
    ) {
        self.resolver = resolver
        self.statusMonitor = statusMonitor
        self.commandExecutor = commandExecutor
    }

    var lastErrorText: String? {
        guard let result = lastResult, result.exitCode != 0 else { return nil }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "Command failed with exit code \(result.exitCode)" : stderr
    }

    func start(port: UInt16, startGateway: Bool = true) async {
        beginOperation()
        defer { endOperation() }

        await enqueueOperation { [weak self] in
            guard let self else { return }
            self.statusMonitor.setStarting()
            var arguments = ["start", "--port", String(port), "--no-open"]
            if !startGateway {
                arguments.append("--no-gateway")
            }
            await self.runCommand(arguments)
            await self.statusMonitor.check(managementPort: port)
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
            await self.runCommand(["stop"])
            await self.statusMonitor.check()
        }
    }

    func restart(port: UInt16) async {
        beginOperation()
        defer { endOperation() }

        await enqueueOperation { [weak self] in
            guard let self else { return }
            self.statusMonitor.setStopping()
            await self.runCommand(["stop"])
            await self.statusMonitor.check()
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.statusMonitor.setStarting()
            await self.runCommand(["start", "--port", String(port), "--no-open"])
            await self.statusMonitor.check(managementPort: port)
        }
    }

    func openDashboard(port: UInt16) {
        guard resolver.runtime.canRun, let ccrPath = resolver.runtime.ccrPath else { return }
        lastCommand = "ccr ui --port \(port)"
        let launched = CommandRunner.launch(
            executable: ccrPath,
            arguments: ["ui", "--port", String(port)],
            environment: resolver.environment
        )
        lastResult = launched
            ? CommandResult(stdout: "", stderr: "", exitCode: 0)
            : CommandResult(stdout: "", stderr: "Failed to launch ccr ui", exitCode: -1)
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

    private func runCommand(_ arguments: [String]) async {
        guard resolver.runtime.canRun, let ccrPath = resolver.runtime.ccrPath else {
            lastResult = CommandResult(stdout: "", stderr: "ccr not installed", exitCode: -1)
            return
        }

        let command = "ccr \(arguments.joined(separator: " "))"
        lastCommand = command

        let environment = resolver.environment
        let commandExecutor = commandExecutor
        let result = await Task.detached(priority: .userInitiated) {
            commandExecutor(ccrPath, arguments, environment)
        }.value

        lastResult = result
    }
}
