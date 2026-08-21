import XCTest
@testable import CCRBar

final class CCRRuntimeTests: XCTestCase {
    @MainActor
    func testLatestStatusCheckWinsWhenEarlierCheckIsInFlight() async {
        let probe = StatusCheckProbe()
        let statusMonitor = CCRStatusMonitor(portChecker: { port in
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
        let statusMonitor = CCRStatusMonitor()
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

    func testCCRCandidateSearchIncludesDesktopBinOutsideLoginPath() {
        let paths = CCRExecutableResolver.ccrSearchPaths(
            home: "/Users/test",
            loginPath: "/usr/local/bin:/usr/bin:/bin"
        )

        XCTAssertEqual(paths.first, "/Users/test/.claude-code-router/bin")
    }

    func testDesktopRuntimeUsesBundledNodeAsSingleSourceOfTruth() {
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
        XCTAssertEqual(runtime.nodeRuntimeDescription, "Bundled Node.js v24.16.0")
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
