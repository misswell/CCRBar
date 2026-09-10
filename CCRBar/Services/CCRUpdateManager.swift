import Foundation
import Combine

enum CCRUpdateStatus: Equatable {
    case idle
    case checking
    case available(current: Version, latest: Version)
    case upToDate(Version)
    case updating
    case updated(Version)
    case desktopManaged
    case unavailable
    case failed(String)
}

private enum CCRInstallResult {
    case success
    case failure(String)
}

@MainActor
protocol CCRUpdateResolving: AnyObject {
    var runtime: CCRRuntime { get }
    var environment: [String: String]? { get }
    func refresh()
}

extension CCRExecutableResolver: CCRUpdateResolving {}

@MainActor
final class CCRUpdateManager: ObservableObject {
    nonisolated static let packageName = "@musistudio/claude-code-router"

    @Published private(set) var status: CCRUpdateStatus = .idle

    private let resolver: CCRUpdateResolving
    private let commandExecutor: @Sendable (String, [String], [String: String]?) -> CommandResult

    init(
        resolver: CCRUpdateResolving,
        commandExecutor: @escaping @Sendable (String, [String], [String: String]?) -> CommandResult = {
            CommandRunner.run(executable: $0, arguments: $1, environment: $2)
        }
    ) {
        self.resolver = resolver
        self.commandExecutor = commandExecutor
    }

    func check() async {
        guard !isBusy else { return }
        status = .checking

        let runtime = resolver.runtime
        let environment = resolver.environment
        let commandExecutor = commandExecutor
        let result = await Task.detached(priority: .utility) {
            Self.checkStatus(
                runtime: runtime,
                environment: environment,
                commandExecutor: commandExecutor
            )
        }.value

        guard !Task.isCancelled else { return }
        status = result
    }

    func update() async {
        guard case .available(_, let latest) = status, !isBusy else { return }

        let runtime = resolver.runtime
        let environment = resolver.environment
        let commandExecutor = commandExecutor
        status = .updating

        let result = await Task.detached(priority: .userInitiated) {
            Self.installLatest(
                runtime: runtime,
                environment: environment,
                commandExecutor: commandExecutor
            )
        }.value

        guard !Task.isCancelled else { return }

        switch result {
        case .success:
            resolver.refresh()
            status = .updated(latest)
        case .failure(let message):
            status = .failed(message)
        }
    }

    private var isBusy: Bool {
        switch status {
        case .checking, .updating:
            return true
        default:
            return false
        }
    }

    private nonisolated static func checkStatus(
        runtime: CCRRuntime,
        environment: [String: String]?,
        commandExecutor: @Sendable (String, [String], [String: String]?) -> CommandResult
    ) -> CCRUpdateStatus {
        guard runtime.source != .desktop else { return .desktopManaged }
        guard runtime.canRun, let ccrPath = runtime.ccrPath else { return .unavailable }

        let currentResult = commandExecutor(ccrPath, ["--version"], environment)
        guard currentResult.exitCode == 0,
              let current = Version(currentResult.stdout) else {
            return .failed(commandError(from: currentResult, fallback: "Unable to read the installed CCR version."))
        }

        guard let npmPath = executable(named: "npm", runtime: runtime, environment: environment) else {
            return .failed("npm was not found next to the selected Node.js runtime.")
        }

        let latestResult = commandExecutor(
            npmPath,
            ["view", packageName, "version", "--json", "--silent"],
            environment
        )
        guard latestResult.exitCode == 0,
              let latest = Version(latestResult.stdout) else {
            return .failed(commandError(from: latestResult, fallback: "Unable to check the latest CCR version."))
        }

        return latest > current
            ? .available(current: current, latest: latest)
            : .upToDate(current)
    }

    private nonisolated static func installLatest(
        runtime: CCRRuntime,
        environment: [String: String]?,
        commandExecutor: @Sendable (String, [String], [String: String]?) -> CommandResult
    ) -> CCRInstallResult {
        guard runtime.source != .desktop,
              runtime.canRun,
              let npmPath = executable(named: "npm", runtime: runtime, environment: environment) else {
            return .failure("npm was not found next to the selected Node.js runtime.")
        }

        let result = commandExecutor(
            npmPath,
            ["install", "--global", "\(packageName)@latest", "--no-fund", "--no-audit"],
            environment
        )
        guard result.exitCode == 0 else {
            return .failure(commandError(from: result, fallback: "CCR update failed."))
        }
        return .success
    }

    private nonisolated static func executable(
        named name: String,
        runtime: CCRRuntime,
        environment: [String: String]?
    ) -> String? {
        var directories = environment?["PATH"]?.split(separator: ":").map(String.init) ?? []
        if let nodePath = runtime.nodePath {
            directories.insert(URL(fileURLWithPath: nodePath).deletingLastPathComponent().path, at: 0)
        }

        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func commandError(from result: CommandResult, fallback: String) -> String {
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }
}
