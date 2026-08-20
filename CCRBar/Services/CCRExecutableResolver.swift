import Foundation
import Combine

@MainActor
final class CCRExecutableResolver: ObservableObject {
    static let minimumNodeVersion = CCRRuntime.minimumNodeVersion

    @Published private(set) var runtime = CCRRuntime.unavailable

    var ccrPath: String? { runtime.ccrPath }
    var nodePath: String? { runtime.nodePath }
    var nodeVersion: Version? { runtime.nodeVersion }
    var nodeVersionString: String? { runtime.nodeVersionString }
    var nodeRuntimeDescription: String? { runtime.nodeRuntimeDescription }
    var loginPath: String? { runtime.loginPath }
    var lastError: String? { runtime.issue?.message }

    var isCCRInstalled: Bool { runtime.isCCRInstalled }
    var isNodeInstalled: Bool { runtime.isNodeInstalled }
    var isCCRApp: Bool { runtime.isCCRApp }
    var nodeMeetsRequirement: Bool { runtime.nodeMeetsRequirement }
    var canRunCCR: Bool { runtime.canRun }
    var environment: [String: String]? { runtime.environment }

    func refresh() {
        let loginPath = queryLoginPath()
        let candidates = resolveCCRCandidates(loginPath: loginPath)
        let normalCandidate = candidates.first {
            URL(fileURLWithPath: $0).lastPathComponent != "ccr-app"
        }
        let desktopCandidate = candidates.first {
            URL(fileURLWithPath: $0).lastPathComponent == "ccr-app"
        }
        let normalRuntime = resolveCompatibleNodeRuntime(loginPath: loginPath)

        if let normalCandidate, let normalRuntime,
           normalRuntime.version >= Self.minimumNodeVersion {
            runtime = CCRRuntime(
                ccrPath: normalCandidate,
                nodePath: normalRuntime.path,
                nodeVersion: normalRuntime.version,
                nodeVersionString: normalRuntime.versionString,
                source: .system,
                loginPath: loginPath,
                issue: nil
            )
        } else if let desktopCandidate,
                  let bundledRuntime = resolveBundledNodeRuntime(at: desktopCandidate) {
            runtime = CCRRuntime(
                ccrPath: desktopCandidate,
                nodePath: bundledRuntime.path,
                nodeVersion: bundledRuntime.version,
                nodeVersionString: bundledRuntime.versionString,
                source: .desktop,
                loginPath: loginPath,
                issue: nil
            )
        } else if let desktopCandidate {
            runtime = CCRRuntime(
                ccrPath: desktopCandidate,
                nodePath: nil,
                nodeVersion: nil,
                nodeVersionString: nil,
                source: .desktop,
                loginPath: loginPath,
                issue: .desktopRuntimeUnavailable
            )
        } else if let normalCandidate {
            let issue: CCRRuntime.Issue
            if let normalRuntime {
                issue = .unsupportedNode(normalRuntime.versionString)
            } else {
                issue = .nodeNotFound
            }

            runtime = CCRRuntime(
                ccrPath: normalCandidate,
                nodePath: normalRuntime?.path,
                nodeVersion: normalRuntime?.version,
                nodeVersionString: normalRuntime?.versionString,
                source: .system,
                loginPath: loginPath,
                issue: issue
            )
        } else {
            runtime = CCRRuntime(
                ccrPath: nil,
                nodePath: nil,
                nodeVersion: nil,
                nodeVersionString: nil,
                source: .unavailable,
                loginPath: loginPath,
                issue: .ccrNotFound
            )
        }
    }

    private func resolveCCRCandidates(loginPath: String?) -> [String] {
        let home = NSHomeDirectory()
        let knownPaths = Self.knownCCRCandidatePaths(home: home)
        let searchPaths = Self.ccrSearchPaths(home: home, loginPath: loginPath)
        var candidates: [String] = []
        if let path = resolveExecutable(named: "ccr", searchPaths: searchPaths) {
            candidates.append(path)
        }
        if let path = resolveExecutable(named: "ccr-app", searchPaths: searchPaths) {
            candidates.append(path)
        }

        candidates += knownPaths.filter {
            FileManager.default.isExecutableFile(atPath: $0)
        }

        var uniqueCandidates: [String] = []
        for candidate in candidates where !uniqueCandidates.contains(candidate) {
            uniqueCandidates.append(candidate)
        }
        return uniqueCandidates
    }

    nonisolated static func knownCCRCandidatePaths(home: String) -> [String] {
        [
            URL(fileURLWithPath: home)
                .appendingPathComponent(".claude-code-router/bin/ccr-app")
                .path,
            "/usr/local/bin/ccr",
            "/opt/homebrew/bin/ccr"
        ]
    }

    nonisolated static func ccrSearchPaths(home: String, loginPath: String?) -> [String] {
        let desktopDirectory = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude-code-router/bin")
            .path
        var paths = [desktopDirectory, "/usr/local/bin", "/opt/homebrew/bin"]
        if let loginPath {
            paths += loginPath.split(separator: ":").map(String.init)
        }

        var uniquePaths: [String] = []
        for path in paths where !path.isEmpty && !uniquePaths.contains(path) {
            uniquePaths.append(path)
        }
        return uniquePaths
    }

    private func queryLoginPath() -> String? {
        let result = CommandRunner.run(executable: "/bin/zsh", arguments: ["-lc", "echo $PATH"])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func resolveExecutable(named name: String, searchPaths: [String]? = nil) -> String? {
        let environment = searchPaths.map { ["PATH": $0.joined(separator: ":")] }
        let result = CommandRunner.run(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v \(name)"],
            environment: environment
        )
        guard result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private struct NodeRuntime {
        let path: String
        let version: Version
        let versionString: String
    }

    private func resolveCompatibleNodeRuntime(loginPath: String?) -> NodeRuntime? {
        var candidatePaths: [String] = []

        if let path = resolveExecutable(named: "node") {
            candidatePaths.append(path)
        }

        if let loginPath {
            candidatePaths += loginPath
                .split(separator: ":")
                .map(String.init)
                .map { URL(fileURLWithPath: $0).appendingPathComponent("node").path }
        }

        let home = NSHomeDirectory()
        candidatePaths += [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            home + "/.volta/bin/node",
            home + "/.asdf/shims/node",
            home + "/.local/share/mise/shims/node",
            home + "/.nvm/current/bin/node"
        ]

        candidatePaths += nodeExecutables(
            in: home + "/.nvm/versions/node",
            relativePath: "bin/node"
        )
        candidatePaths += nodeExecutables(
            in: home + "/.local/share/fnm/node-versions",
            relativePath: "installation/bin/node"
        )
        candidatePaths += nodeExecutables(
            in: home + "/.fnm/node-versions",
            relativePath: "installation/bin/node"
        )
        candidatePaths += nodeExecutables(
            in: home + "/.asdf/installs/nodejs",
            relativePath: "bin/node"
        )
        candidatePaths += nodeExecutables(
            in: home + "/.local/share/mise/installs/node",
            relativePath: "bin/node"
        )

        let uniquePaths = Set(candidatePaths)
        let runtimes = uniquePaths.compactMap { makeNodeRuntime(at: $0) }

        let sortedRuntimes = runtimes.sorted { lhs, rhs in
            if lhs.version != rhs.version {
                return lhs.version > rhs.version
            }
            return lhs.path < rhs.path
        }

        // Prefer the newest runtime that satisfies CCR's requirement. If there
        // is no compatible installation, retain the newest one for diagnostics.
        return sortedRuntimes.first(where: {
            $0.version >= Self.minimumNodeVersion
        }) ?? sortedRuntimes.first
    }

    private func nodeExecutables(in directory: String, relativePath: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }

        return entries.map {
            URL(fileURLWithPath: directory)
                .appendingPathComponent($0)
                .appendingPathComponent(relativePath)
                .path
        }
    }

    private func makeNodeRuntime(at path: String) -> NodeRuntime? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }

        let result = CommandRunner.run(executable: path, arguments: ["--version"])
        guard result.exitCode == 0 else { return nil }

        let versionString = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = Version(versionString) else { return nil }

        return NodeRuntime(path: path, version: version, versionString: versionString)
    }

    private func resolveBundledNodeRuntime(at ccrPath: String) -> NodeRuntime? {
        guard let wrapper = try? String(
            contentsOf: URL(fileURLWithPath: ccrPath),
            encoding: .utf8
        ) else {
            return nil
        }

        var runtimePaths: [String] = []
        let marker = "ELECTRON_RUN_AS_NODE=1 exec '"
        if let markerRange = wrapper.range(of: marker) {
            let remainder = wrapper[markerRange.upperBound...]
            if let end = remainder.firstIndex(of: "'") {
                runtimePaths.append(String(remainder[..<end]))
            }
        }

        runtimePaths.append(
            "/Applications/Claude Code Router.app/Contents/MacOS/Claude Code Router"
        )

        for runtimePath in Set(runtimePaths) {
            guard FileManager.default.isExecutableFile(atPath: runtimePath) else { continue }

            let result = CommandRunner.run(
                executable: runtimePath,
                arguments: ["-p", "process.version"],
                environment: ["ELECTRON_RUN_AS_NODE": "1"]
            )
            guard result.exitCode == 0 else { continue }

            let versionString = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let version = Version(versionString) {
                return NodeRuntime(
                    path: runtimePath,
                    version: version,
                    versionString: versionString
                )
            }
        }

        return nil
    }
}
