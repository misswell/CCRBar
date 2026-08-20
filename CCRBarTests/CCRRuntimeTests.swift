import XCTest
@testable import CCRBar

final class CCRRuntimeTests: XCTestCase {
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
