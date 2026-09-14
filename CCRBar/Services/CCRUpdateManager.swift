import Foundation
import Combine

enum CCRUpdateStatus: Equatable {
    case idle
    case checking
    case available(current: Version, latest: Version)
    case upToDate(Version)
    case updating
    case updated(Version)
    case unavailable
    case failed(String)
}

private enum CCRInstallResult {
    case success
    case failure(String)
}

private struct CCRInstalledVersionResult {
    let version: Version?
    let error: String?
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
    nonisolated static let releaseAPIURL = URL(
        string: "https://api.github.com/repos/musistudio/claude-code-router/releases/latest"
    )!
    nonisolated static let releasesPageURL = URL(
        string: "https://github.com/musistudio/claude-code-router/releases/latest"
    )!

    @Published private(set) var status: CCRUpdateStatus = .idle
    /// Last installed CCR version CCRBar could read, kept even when the
    /// latest-version lookup fails so the menu can still show what is installed.
    @Published private(set) var installedVersion: Version?

    private let resolver: CCRUpdateResolving
    private let commandExecutor: @Sendable (String, [String], [String: String]?) -> CommandResult
    private let releaseVersionProvider: @Sendable () async -> Version?

    init(
        resolver: CCRUpdateResolving,
        commandExecutor: @escaping @Sendable (String, [String], [String: String]?) -> CommandResult = {
            CommandRunner.run(executable: $0, arguments: $1, environment: $2)
        },
        releaseVersionProvider: @escaping @Sendable () async -> Version? = {
            await CCRUpdateManager.fetchLatestReleaseVersion()
        }
    ) {
        self.resolver = resolver
        self.commandExecutor = commandExecutor
        self.releaseVersionProvider = releaseVersionProvider
    }

    /// Whether an available update can be installed with npm. Desktop CCR is
    /// updated by its own installer, so CCRBar only links to the download page.
    var canInstallAvailableUpdate: Bool {
        resolver.runtime.source != .desktop
    }

    func check() async {
        guard !isBusy else { return }
        status = .checking

        let runtime = resolver.runtime
        let environment = resolver.environment
        let commandExecutor = commandExecutor

        guard runtime.ccrPath != nil else {
            installedVersion = nil
            status = .unavailable
            return
        }
        // A system CLI needs a compatible Node runtime before we can ask it
        // for its version; the setup section already explains that failure.
        guard runtime.source == .desktop || runtime.canRun else {
            status = .unavailable
            return
        }

        let installedResult = await Task.detached(priority: .utility) {
            Self.installedVersion(
                runtime: runtime,
                environment: environment,
                commandExecutor: commandExecutor
            )
        }.value

        guard !Task.isCancelled else { return }
        guard let installed = installedResult.version else {
            installedVersion = nil
            status = .failed(
                installedResult.error
                    ?? String(localized: "Unable to read the installed CCR version.")
            )
            return
        }
        installedVersion = installed

        let latest: Version?
        if runtime.source == .desktop {
            latest = await releaseVersionProvider()
        } else {
            let npmLatest = await Task.detached(priority: .utility) {
                Self.npmLatestVersion(
                    runtime: runtime,
                    environment: environment,
                    commandExecutor: commandExecutor
                )
            }.value
            guard !Task.isCancelled else { return }
            // npm is authoritative for what `npm install -g ...@latest` would
            // fetch; fall back to the release feed when npm is unavailable.
            if let npmLatest {
                latest = npmLatest
            } else {
                latest = await releaseVersionProvider()
            }
        }

        guard !Task.isCancelled else { return }
        guard let latest else {
            status = .failed(String(localized: "Unable to check the latest CCR version."))
            return
        }

        status = latest > installed
            ? .available(current: installed, latest: latest)
            : .upToDate(installed)
    }

    func update() async {
        guard case .available(_, let latest) = status, !isBusy else { return }
        guard canInstallAvailableUpdate else { return }

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

    private nonisolated static func installedVersion(
        runtime: CCRRuntime,
        environment: [String: String]?,
        commandExecutor: @Sendable (String, [String], [String: String]?) -> CommandResult
    ) -> CCRInstalledVersionResult {
        if runtime.source == .desktop {
            guard let bundlePath = CCRExecutableResolver.desktopAppBundlePath(
                ccrPath: runtime.ccrPath,
                nodePath: runtime.nodePath
            ),
            let version = CCRExecutableResolver.appBundleShortVersion(at: bundlePath) else {
                return CCRInstalledVersionResult(
                    version: nil,
                    error: String(localized: "Unable to read the installed CCR Desktop version.")
                )
            }
            return CCRInstalledVersionResult(version: version, error: nil)
        }

        guard let ccrPath = runtime.ccrPath else {
            return CCRInstalledVersionResult(
                version: nil,
                error: String(localized: "CCR runtime is unavailable.")
            )
        }

        let result = commandExecutor(ccrPath, ["--version"], environment)
        guard result.exitCode == 0,
              let version = Version(result.stdout) else {
            return CCRInstalledVersionResult(
                version: nil,
                error: commandError(
                    from: result,
                    fallback: String(localized: "Unable to read the installed CCR version.")
                )
            )
        }
        return CCRInstalledVersionResult(version: version, error: nil)
    }

    private nonisolated static func npmLatestVersion(
        runtime: CCRRuntime,
        environment: [String: String]?,
        commandExecutor: @Sendable (String, [String], [String: String]?) -> CommandResult
    ) -> Version? {
        guard let npmPath = executable(named: "npm", runtime: runtime, environment: environment) else {
            return nil
        }

        let result = commandExecutor(
            npmPath,
            ["view", packageName, "version", "--json", "--silent"],
            environment
        )
        guard result.exitCode == 0 else { return nil }
        return Version(result.stdout)
    }

    private nonisolated static func installLatest(
        runtime: CCRRuntime,
        environment: [String: String]?,
        commandExecutor: @Sendable (String, [String], [String: String]?) -> CommandResult
    ) -> CCRInstallResult {
        guard runtime.source != .desktop,
              runtime.canRun,
              let npmPath = executable(named: "npm", runtime: runtime, environment: environment) else {
            return .failure(String(localized: "npm was not found next to the selected Node.js runtime."))
        }

        let result = commandExecutor(
            npmPath,
            ["install", "--global", "\(packageName)@latest", "--no-fund", "--no-audit"],
            environment
        )
        guard result.exitCode == 0 else {
            return .failure(
                commandError(from: result, fallback: String(localized: "CCR update failed."))
            )
        }
        return .success
    }

    /// Reads the newest published CCR version from the GitHub release feed.
    /// Used for the desktop app, whose version tracks the release tag.
    nonisolated static func fetchLatestReleaseVersion() async -> Version? {
        var request = URLRequest(url: releaseAPIURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CCRBar", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else {
            return nil
        }
        return Version(tag)
    }

    private nonisolated static func executable(
        named name: String,
        runtime: CCRRuntime,
        environment: [String: String]?
    ) -> String? {
        var directories: [String] = []
        // npm lives next to the selected Node.js runtime for every common
        // version manager. The GUI app's launchd PATH does not include
        // Homebrew or /usr/local/bin, so add those explicitly.
        if let nodePath = runtime.nodePath {
            directories.append(URL(fileURLWithPath: nodePath).deletingLastPathComponent().path)
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        directories += environment?["PATH"]?.split(separator: ":").map(String.init) ?? []

        for directory in directories where !directory.isEmpty {
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
