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
    @Published private(set) var lastCommand: String?
    @Published private(set) var lastResult: CommandResult?

    private let resolver: CCRExecutableResolving
    private let statusMonitor: CCRStatusMonitor
    private let commandExecutor: @Sendable (String, [String], [String: String]?) -> CommandResult

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
        statusMonitor.setStarting()
        var arguments = ["start", "--port", String(port), "--no-open"]
        if !startGateway {
            arguments.append("--no-gateway")
        }
        await runCommand(arguments)
        await statusMonitor.check(managementPort: port)
    }

    func stop() async {
        await runCommand(["stop"])
        await statusMonitor.check()
    }

    func restart(port: UInt16) async {
        await stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await start(port: port)
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

    private func runCommand(_ arguments: [String]) async {
        guard resolver.runtime.canRun, let ccrPath = resolver.runtime.ccrPath else {
            lastResult = CommandResult(stdout: "", stderr: "ccr not installed", exitCode: -1)
            return
        }

        isBusy = true
        defer { isBusy = false }

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
