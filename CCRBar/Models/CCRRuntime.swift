import Foundation

struct CCRRuntime: Equatable {
    static let minimumNodeVersion = Version(22, 0, 0)

    enum Source: Equatable {
        case system
        case desktop
        case unavailable
    }

    enum Issue: Equatable {
        case ccrNotFound
        case nodeNotFound
        case unsupportedNode(String)
        case desktopRuntimeUnavailable

        var message: String {
            switch self {
            case .ccrNotFound:
                return "CCR was not found in the login shell PATH."
            case .nodeNotFound:
                return "A compatible Node.js runtime was not found. Node.js 22+ is required."
            case .unsupportedNode(let version):
                return "Node.js 22+ is required (found \(version))."
            case .desktopRuntimeUnavailable:
                return "CCR Desktop's bundled Node.js runtime could not be detected."
            }
        }
    }

    let ccrPath: String?
    let nodePath: String?
    let nodeVersion: Version?
    let nodeVersionString: String?
    let source: Source
    let loginPath: String?
    let issue: Issue?

    init(
        ccrPath: String?,
        nodePath: String?,
        nodeVersion: Version?,
        nodeVersionString: String?,
        source: Source,
        loginPath: String? = nil,
        issue: Issue?
    ) {
        self.ccrPath = ccrPath
        self.nodePath = nodePath
        self.nodeVersion = nodeVersion
        self.nodeVersionString = nodeVersionString
        self.source = source
        self.loginPath = loginPath
        self.issue = issue
    }

    static let unavailable = CCRRuntime(
        ccrPath: nil,
        nodePath: nil,
        nodeVersion: nil,
        nodeVersionString: nil,
        source: .unavailable,
        issue: .ccrNotFound
    )

    var isCCRApp: Bool {
        source == .desktop
    }

    var isCCRInstalled: Bool {
        ccrPath != nil
    }

    var isNodeInstalled: Bool {
        nodePath != nil
    }

    var canRun: Bool {
        guard ccrPath != nil, issue == nil, let nodePath else { return false }
        if isCCRApp {
            return !nodePath.isEmpty
        }
        guard let nodeVersion else { return false }
        return nodeVersion >= Self.minimumNodeVersion
    }

    var nodeMeetsRequirement: Bool {
        canRun
    }

    var nodeRuntimeDescription: String? {
        guard let nodeVersionString else { return nil }
        if isCCRApp, nodeVersionString == "bundled" {
            return "Bundled Node.js"
        }
        return isCCRApp
            ? "Bundled Node.js \(nodeVersionString)"
            : "Node.js \(nodeVersionString)"
    }

    var environment: [String: String]? {
        var paths = (loginPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        // A system-installed ccr uses /usr/bin/env node. Put the selected
        // compatible Node version first without changing the user's shell setup.
        if !isCCRApp, let nodePath {
            let nodeDirectory = URL(fileURLWithPath: nodePath)
                .deletingLastPathComponent()
                .path
            paths.removeAll { $0 == nodeDirectory }
            paths.insert(nodeDirectory, at: 0)
        }

        guard !paths.isEmpty else { return nil }
        return ["PATH": paths.joined(separator: ":")]
    }
}
