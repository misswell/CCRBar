import Foundation
import Combine

@MainActor
final class CCRServiceManager: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var lastCommand: String?
    @Published private(set) var lastResult: CommandResult?

    private let resolver: CCRExecutableResolver
    private let statusMonitor: CCRStatusMonitor

    init(resolver: CCRExecutableResolver, statusMonitor: CCRStatusMonitor) {
        self.resolver = resolver
        self.statusMonitor = statusMonitor
    }

    var lastErrorText: String? {
        guard let result = lastResult, result.exitCode != 0 else { return nil }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "Command failed with exit code \(result.exitCode)" : stderr
    }

    func start() async {
        statusMonitor.setStarting()
        await runCommand(["start", "--no-open"])
    }

    func stop() async {
        await runCommand(["stop"])
    }

    func restart() async {
        await stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await start()
    }

    func openDashboard() {
        guard let ccrPath = resolver.ccrPath else { return }
        lastCommand = "ccr ui"
        let launched = CommandRunner.launch(
            executable: ccrPath,
            arguments: ["ui"],
            environment: resolver.environment
        )
        lastResult = launched
            ? CommandResult(stdout: "", stderr: "", exitCode: 0)
            : CommandResult(stdout: "", stderr: "Failed to launch ccr ui", exitCode: -1)
    }

    private func runCommand(_ arguments: [String]) async {
        guard let ccrPath = resolver.ccrPath else {
            lastResult = CommandResult(stdout: "", stderr: "ccr not installed", exitCode: -1)
            return
        }

        isBusy = true
        defer { isBusy = false }

        let command = "ccr \(arguments.joined(separator: " "))"
        lastCommand = command

        let environment = resolver.environment
        let result = await Task.detached(priority: .userInitiated) {
            CommandRunner.run(
                executable: ccrPath,
                arguments: arguments,
                environment: environment
            )
        }.value

        lastResult = result
    }
}
