import Foundation
import Combine

@MainActor
final class CCRExecutableResolver: ObservableObject {
    @Published private(set) var ccrPath: String?
    @Published private(set) var nodePath: String?
    @Published private(set) var nodeVersion: Version?
    @Published private(set) var nodeVersionString: String?
    @Published private(set) var loginPath: String?
    @Published private(set) var lastError: String?

    var isCCRInstalled: Bool { ccrPath != nil }
    var isNodeInstalled: Bool { nodePath != nil }
    var isCCRApp: Bool { ccrPath?.hasSuffix("/ccr-app") == true }

    var nodeMeetsRequirement: Bool {
        guard let nodeVersion else { return false }
        return nodeVersion >= Version(22, 0, 0)
    }

    var environment: [String: String]? {
        guard let loginPath else { return nil }
        return ["PATH": loginPath]
    }

    func refresh() {
        loginPath = queryLoginPath()
        ccrPath = resolveCCRExecutable()
        nodePath = resolveExecutable(named: "node")

        if let nodePath {
            let result = CommandRunner.run(executable: nodePath, arguments: ["--version"])
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            nodeVersionString = trimmed.isEmpty ? nil : trimmed
            nodeVersion = trimmed.isEmpty ? nil : Version(trimmed)
        } else {
            nodeVersionString = nil
            nodeVersion = nil
        }

        if ccrPath == nil {
            lastError = "ccr was not found in the login shell PATH."
        } else if isCCRApp {
            // Desktop app ships its own bundled Node runtime via Electron.
            lastError = nil
        } else if nodePath == nil {
            lastError = "Node.js was not found in the login shell PATH."
        } else if !nodeMeetsRequirement {
            lastError = "Node.js 22+ is required (found \(nodeVersionString ?? "unknown"))."
        } else {
            lastError = nil
        }
    }

    private func resolveCCRExecutable() -> String? {
        if let path = resolveExecutable(named: "ccr") {
            return path
        }
        return resolveExecutable(named: "ccr-app")
    }

    private func queryLoginPath() -> String? {
        let result = CommandRunner.run(executable: "/bin/zsh", arguments: ["-lc", "echo $PATH"])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func resolveExecutable(named name: String) -> String? {
        let result = CommandRunner.run(executable: "/bin/zsh", arguments: ["-lc", "command -v \(name)"])
        guard result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
