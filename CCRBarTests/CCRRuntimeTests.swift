import XCTest
@testable import CCRBar

final class CCRRuntimeTests: XCTestCase {
    func testLaunchedProcessIsReleasedAfterTermination() {
        let baseline = CommandRunner.retainedProcessCount

        XCTAssertTrue(CommandRunner.launch(executable: "/usr/bin/true", arguments: []))

        let deadline = Date().addingTimeInterval(2)
        while CommandRunner.retainedProcessCount > baseline, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(CommandRunner.retainedProcessCount, baseline)
    }

    func testCommandOutputIsBounded() {
        let payload = String(
            repeating: "x",
            count: CommandRunner.maximumCapturedOutputBytes + 1_024
        )

        let result = CommandRunner.run(
            executable: "/usr/bin/printf",
            arguments: [payload]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, CommandRunner.maximumCapturedOutputBytes)
    }

    @MainActor
    func testUnchangedStatusCheckDoesNotPublish() async {
        let statusMonitor = CCRStatusMonitor(portChecker: { _, _ in false })
        var publicationCount = 0
        let subscription = statusMonitor.objectWillChange.sink {
            publicationCount += 1
        }

        await statusMonitor.check()

        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testStatusCheckUsesConfiguredGatewayHost() async {
        let probe = GatewayHostProbe()
        let statusMonitor = CCRStatusMonitor { host, port in
            await probe.check(host: host, port: port)
        }

        await statusMonitor.check(
            managementPort: AppSettings.defaultManagementPort,
            gatewayHost: "172.16.80.3"
        )

        let requests = await probe.requests
        XCTAssertTrue(requests.contains { request in
            request.host == "172.16.80.3" && request.port == 3456
        })
        XCTAssertTrue(requests.contains { request in
            request.host == AppSettings.defaultGatewayHost
                && request.port == AppSettings.defaultManagementPort
        })
    }

    @MainActor
    func testAppStatePublishesNestedStatusChanges() async {
        let appState = AppState()
        let expectation = expectation(description: "AppState forwards status changes")
        let subscription = appState.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        appState.statusMonitor.setStarting()

        await fulfillment(of: [expectation], timeout: 1.0)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testCancellingPendingAutoStartPreventsStart() async {
        let coordinator = CCRAutoStartCoordinator()
        var startCount = 0

        coordinator.schedule(delayNanoseconds: 50_000_000) {
            startCount += 1
        }
        coordinator.cancel()

        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testLatestStatusCheckWinsWhenEarlierCheckIsInFlight() async {
        let probe = StatusCheckProbe()
        let statusMonitor = CCRStatusMonitor(portChecker: { _, port in
            await probe.check(port)
        })

        let initialCheck = Task { @MainActor in
            await statusMonitor.check()
        }
        await probe.waitForFirstCheck()

        let latestCheck = Task { @MainActor in
            await statusMonitor.check()
        }
        await latestCheck.value

        await probe.releaseFirstCheck()
        await initialCheck.value

        XCTAssertEqual(statusMonitor.status, .stopped)
    }

    @MainActor
    func testStopRefreshesStatusAfterCommandCompletes() async {
        let resolver = TestExecutableResolver()
        let statusMonitor = CCRStatusMonitor(portChecker: { _, _ in false })
        statusMonitor.setStarting()
        let manager = CCRServiceManager(
            resolver: resolver,
            statusMonitor: statusMonitor,
            commandExecutor: { _, arguments, _ in
                XCTAssertEqual(arguments, ["stop"])
                return CommandResult(stdout: "", stderr: "", exitCode: 0)
            }
        )

        await manager.stop()

        XCTAssertEqual(statusMonitor.status, .stopped)
    }

    @MainActor
    func testStartAppliesConfiguredGatewayHost() async {
        let resolver = TestExecutableResolver()
        let statusMonitor = CCRStatusMonitor(portChecker: { _, _ in false })
        let configurationManager = TestGatewayConfigurationManager()
        let manager = CCRServiceManager(
            resolver: resolver,
            statusMonitor: statusMonitor,
            gatewayConfigurationManager: configurationManager,
            commandExecutor: { _, arguments, _ in
                XCTAssertEqual(arguments, ["start", "--port", "3458", "--no-open"])
                return CommandResult(stdout: "", stderr: "", exitCode: 0)
            }
        )

        await manager.start(port: 3458, gatewayHost: "0.0.0.0")

        XCTAssertEqual(configurationManager.updatedHosts, ["0.0.0.0"])
    }

    @MainActor
    func testGatewayConfigurationClientUpdatesBothHostFields() async throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccrbar-config-tests-\(UUID().uuidString)")
        let ccrDirectory = homeDirectory.appendingPathComponent(".claude-code-router")
        try FileManager.default.createDirectory(at: ccrDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let serviceURL = "http://127.0.0.1:3458/?ccr_web_token=test-token"
        try Data("{\"url\":\"\(serviceURL)\"}".utf8)
            .write(to: ccrDirectory.appendingPathComponent("service.json"))

        let configuration: [String: Any] = [
            "HOST": "127.0.0.1",
            "PORT": 3456,
            "gateway": [
                "host": "127.0.0.1",
                "port": 3456
            ]
        ]
        let getConfigResponse = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "value": configuration
        ])
        let saveConfigResponse = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "value": configuration
        ])
        let requests = LockedRPCRequests()
        let client = CCRWebConfigurationClient(
            homeDirectory: homeDirectory.path,
            dataLoader: { request in
                requests.append(request)
                let responseData = requests.count == 1 ? getConfigResponse : saveConfigResponse
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (responseData, response)
            }
        )

        try await client.updateGatewayHost("0.0.0.0")

        let capturedRequests = requests.values
        XCTAssertEqual(capturedRequests.count, 2)
        XCTAssertEqual(
            capturedRequests[0].value(forHTTPHeaderField: "x-ccr-web-auth"),
            "test-token"
        )
        let saveBody = try XCTUnwrap(
            capturedRequests[1].httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        )
        let arguments = try XCTUnwrap(saveBody["args"] as? [Any])
        let savedConfiguration = try XCTUnwrap(arguments[0] as? [String: Any])
        XCTAssertEqual(savedConfiguration["HOST"] as? String, "0.0.0.0")
        let savedGateway = try XCTUnwrap(savedConfiguration["gateway"] as? [String: Any])
        XCTAssertEqual(savedGateway["host"] as? String, "0.0.0.0")
        let options = try XCTUnwrap(arguments[1] as? [String: Any])
        XCTAssertEqual(options["applyProfile"] as? Bool, false)
    }

    func testCCRCandidateSearchIncludesDesktopBinOutsideLoginPath() {
        let paths = CCRExecutableResolver.ccrSearchPaths(
            home: "/Users/test",
            loginPath: "/usr/local/bin:/usr/bin:/bin"
        )

        XCTAssertEqual(paths.first, "/Users/test/.claude-code-router/bin")
    }

    func testDesktopRuntimeUsesBundledNodeAsSingleSourceOfTruth() throws {
        let runtime = CCRRuntime(
            ccrPath: "/Users/test/.claude-code-router/bin/ccr-app",
            nodePath: "/Applications/Claude Code Router.app/Contents/MacOS/Claude Code Router",
            nodeVersion: Version(24, 16, 0),
            nodeVersionString: "v24.16.0",
            source: .desktop,
            issue: nil
        )

        XCTAssertTrue(runtime.canRun)
        XCTAssertTrue(runtime.isCCRApp)
        XCTAssertNil(runtime.issue)
        let description = try XCTUnwrap(runtime.nodeRuntimeDescription)
        XCTAssertTrue(description.contains("v24.16.0"))
        XCTAssertTrue(description.contains(String(localized: "Bundled Node.js")))
    }

    func testSystemNodeFourteenIsRejectedOnlyForSystemRuntime() {
        let runtime = CCRRuntime(
            ccrPath: "/usr/local/bin/ccr",
            nodePath: "/usr/local/bin/node",
            nodeVersion: Version(14, 16, 0),
            nodeVersionString: "v14.16.0",
            source: .system,
            issue: .unsupportedNode("v14.16.0")
        )

        XCTAssertFalse(runtime.canRun)
        XCTAssertFalse(runtime.isCCRApp)
        XCTAssertEqual(runtime.issue, .unsupportedNode("v14.16.0"))
    }

    @MainActor
    func testCCRUpdateCheckReportsAvailableCLIUpdate() async {
        let resolver = TestCCRUpdateResolver(
            runtime: CCRRuntime(
                ccrPath: "/usr/local/bin/ccr",
                nodePath: "/usr/local/bin/node",
                nodeVersion: Version(22, 0, 0),
                nodeVersionString: "v22.0.0",
                source: .system,
                issue: nil
            )
        )
        let manager = CCRUpdateManager(
            resolver: resolver,
            commandExecutor: { executable, arguments, _ in
                if executable == "/usr/local/bin/ccr" {
                    return CommandResult(stdout: "ccr 1.2.3\n", stderr: "", exitCode: 0)
                }
                XCTAssertEqual(arguments, ["view", "@musistudio/claude-code-router", "version", "--json", "--silent"])
                return CommandResult(stdout: "\"1.3.0\"\n", stderr: "", exitCode: 0)
            }
        )

        await manager.check()

        XCTAssertEqual(
            manager.status,
            .available(current: Version(1, 2, 3), latest: Version(1, 3, 0))
        )
    }

    @MainActor
    func testCCRUpdateInstallsLatestCLIAndRefreshesRuntime() async {
        let resolver = TestCCRUpdateResolver(
            runtime: CCRRuntime(
                ccrPath: "/usr/local/bin/ccr",
                nodePath: "/usr/local/bin/node",
                nodeVersion: Version(22, 0, 0),
                nodeVersionString: "v22.0.0",
                source: .system,
                issue: nil
            )
        )
        let calls = LockedCommandCalls()
        let manager = CCRUpdateManager(
            resolver: resolver,
            commandExecutor: { executable, arguments, _ in
                calls.append(executable: executable, arguments: arguments)
                switch arguments.first {
                case "--version":
                    return CommandResult(stdout: "1.2.3\n", stderr: "", exitCode: 0)
                case "view":
                    return CommandResult(stdout: "\"1.3.0\"\n", stderr: "", exitCode: 0)
                case "install":
                    return CommandResult(stdout: "updated\n", stderr: "", exitCode: 0)
                default:
                    XCTFail("Unexpected command: \(arguments)")
                    return CommandResult(stdout: "", stderr: "", exitCode: 1)
                }
            }
        )

        await manager.check()
        await manager.update()

        XCTAssertEqual(manager.status, .updated(Version(1, 3, 0)))
        XCTAssertEqual(resolver.refreshCount, 1)
        XCTAssertTrue(calls.contains(arguments: [
            "install", "--global", "@musistudio/claude-code-router@latest", "--no-fund", "--no-audit"
        ]))
    }

    @MainActor
    func testCCRDesktopDetectsInstalledVersionAndAvailableUpdate() async throws {
        let bundlePath = try makeTemporaryDesktopAppBundle(version: "3.1.0")
        defer { try? FileManager.default.removeItem(atPath: bundlePath) }

        let resolver = TestCCRUpdateResolver(
            runtime: CCRRuntime(
                ccrPath: "/Users/test/.claude-code-router/bin/ccr-app",
                nodePath: bundlePath + "/Contents/MacOS/Claude Code Router",
                nodeVersion: Version(22, 0, 0),
                nodeVersionString: "bundled",
                source: .desktop,
                issue: nil
            )
        )
        let manager = CCRUpdateManager(
            resolver: resolver,
            commandExecutor: { _, _, _ in
                XCTFail("Desktop update checks must not run the CLI or npm")
                return CommandResult(stdout: "", stderr: "", exitCode: 1)
            },
            releaseVersionProvider: { Version(3, 2, 0) }
        )

        await manager.check()

        XCTAssertEqual(
            manager.status,
            .available(current: Version(3, 1, 0), latest: Version(3, 2, 0))
        )
        XCTAssertFalse(manager.canInstallAvailableUpdate)
    }

    @MainActor
    func testCCRDesktopReportsUpToDateAgainstReleaseFeed() async throws {
        let bundlePath = try makeTemporaryDesktopAppBundle(version: "3.1.0")
        defer { try? FileManager.default.removeItem(atPath: bundlePath) }

        let resolver = TestCCRUpdateResolver(
            runtime: CCRRuntime(
                ccrPath: "/Users/test/.claude-code-router/bin/ccr-app",
                nodePath: bundlePath + "/Contents/MacOS/Claude Code Router",
                nodeVersion: Version(22, 0, 0),
                nodeVersionString: "bundled",
                source: .desktop,
                issue: nil
            )
        )
        let manager = CCRUpdateManager(
            resolver: resolver,
            commandExecutor: { _, _, _ in
                XCTFail("Desktop update checks must not run the CLI or npm")
                return CommandResult(stdout: "", stderr: "", exitCode: 1)
            },
            releaseVersionProvider: { Version(3, 1, 0) }
        )

        await manager.check()

        XCTAssertEqual(manager.status, .upToDate(Version(3, 1, 0)))
    }

    @MainActor
    func testCCRUpdateFallsBackToReleaseFeedWhenNpmFails() async {
        let resolver = TestCCRUpdateResolver(
            runtime: CCRRuntime(
                ccrPath: "/usr/local/bin/ccr",
                nodePath: "/usr/local/bin/node",
                nodeVersion: Version(22, 0, 0),
                nodeVersionString: "v22.0.0",
                source: .system,
                issue: nil
            )
        )
        let manager = CCRUpdateManager(
            resolver: resolver,
            commandExecutor: { _, arguments, _ in
                if arguments == ["--version"] {
                    return CommandResult(stdout: "1.2.3\n", stderr: "", exitCode: 0)
                }
                return CommandResult(stdout: "", stderr: "npm unavailable", exitCode: 1)
            },
            releaseVersionProvider: { Version(1, 3, 0) }
        )

        await manager.check()

        XCTAssertEqual(
            manager.status,
            .available(current: Version(1, 2, 3), latest: Version(1, 3, 0))
        )
        XCTAssertTrue(manager.canInstallAvailableUpdate)
    }

    @MainActor
    func testCCRUpdateKeepsInstalledVersionWhenLatestLookupFails() async {
        let resolver = TestCCRUpdateResolver(
            runtime: CCRRuntime(
                ccrPath: "/usr/local/bin/ccr",
                nodePath: "/usr/local/bin/node",
                nodeVersion: Version(22, 0, 0),
                nodeVersionString: "v22.0.0",
                source: .system,
                issue: nil
            )
        )
        let manager = CCRUpdateManager(
            resolver: resolver,
            commandExecutor: { _, arguments, _ in
                if arguments == ["--version"] {
                    return CommandResult(stdout: "1.2.3\n", stderr: "", exitCode: 0)
                }
                return CommandResult(stdout: "", stderr: "offline", exitCode: 1)
            },
            releaseVersionProvider: { nil }
        )

        await manager.check()

        XCTAssertEqual(manager.installedVersion, Version(1, 2, 3))
        guard case .failed = manager.status else {
            return XCTFail("Expected a failed check, got \(manager.status)")
        }
    }

    private func makeTemporaryDesktopAppBundle(version: String) throws -> String {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccrbar-tests-\(UUID().uuidString)")
            .appendingPathComponent("Claude Code Router.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle.path
    }
}

private actor StatusCheckProbe {
    private var invocationCount = 0
    private var firstCheckStarted = false
    private var firstCheckWaiter: CheckedContinuation<Void, Never>?
    private var firstCheckRelease: CheckedContinuation<Void, Never>?

    func check(_ port: UInt16) async -> Bool {
        let invocation = invocationCount
        invocationCount += 1

        if invocation == 0 {
            firstCheckStarted = true
            firstCheckWaiter?.resume()
            firstCheckWaiter = nil
            await withCheckedContinuation { continuation in
                firstCheckRelease = continuation
            }
            return true
        }

        return invocation == 1
    }

    func waitForFirstCheck() async {
        guard !firstCheckStarted else { return }
        await withCheckedContinuation { continuation in
            firstCheckWaiter = continuation
        }
    }

    func releaseFirstCheck() {
        firstCheckRelease?.resume()
        firstCheckRelease = nil
    }
}

private actor GatewayHostProbe {
    private(set) var requests: [(host: String, port: UInt16)] = []

    func check(host: String, port: UInt16) -> Bool {
        requests.append((host, port))
        return false
    }
}

@MainActor
private final class TestGatewayConfigurationManager: CCRGatewayConfigurationManaging {
    var updatedHosts: [String] = []

    func currentGatewayHost() async throws -> String {
        AppSettings.defaultGatewayHost
    }

    func updateGatewayHost(_ host: String) async throws {
        updatedHosts.append(host)
    }
}

private final class LockedRPCRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [URLRequest] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValues.count
    }

    var values: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        storedValues.append(request)
    }
}

@MainActor
private final class TestExecutableResolver: CCRExecutableResolving {
    let runtime = CCRRuntime(
        ccrPath: "/test/ccr-app",
        nodePath: "/test/node",
        nodeVersion: Version(24, 0, 0),
        nodeVersionString: "v24.0.0",
        source: .desktop,
        issue: nil
    )

    let environment: [String: String]? = nil
}

@MainActor
private final class TestCCRUpdateResolver: CCRUpdateResolving {
    let runtime: CCRRuntime
    let environment: [String: String]? = ["PATH": "/usr/local/bin:/usr/bin:/bin"]
    private(set) var refreshCount = 0

    init(runtime: CCRRuntime) {
        self.runtime = runtime
    }

    func refresh() {
        refreshCount += 1
    }
}

private final class LockedCommandCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(executable: String, arguments: [String])] = []

    func append(executable: String, arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        values.append((executable, arguments))
    }

    func contains(arguments expected: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.contains { $0.arguments == expected }
    }
}
