import Foundation

struct CommandResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum CommandRunner {
    static let maximumCapturedOutputBytes = 64 * 1_024

    static var retainedProcessCount: Int {
        launchedProcessesLock.lock()
        defer { launchedProcessesLock.unlock() }
        return launchedProcesses.count
    }

    @discardableResult
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var env = sanitizedEnvironment()
        if let environment {
            for (key, value) in environment {
                env[key] = value
            }
        }
        process.environment = env

        do {
            try process.run()

            let outputCapture = BoundedOutputCapture(limit: maximumCapturedOutputBytes)
            let errorCapture = BoundedOutputCapture(limit: maximumCapturedOutputBytes)
            let captureGroup = DispatchGroup()

            captureGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                outputCapture.readToEnd(from: outputPipe.fileHandleForReading)
                captureGroup.leave()
            }

            captureGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                errorCapture.readToEnd(from: errorPipe.fileHandleForReading)
                captureGroup.leave()
            }

            process.waitUntilExit()
            captureGroup.wait()

            return CommandResult(
                stdout: outputCapture.string,
                stderr: errorCapture.string,
                exitCode: process.terminationStatus
            )
        } catch {
            return CommandResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
    }

    @discardableResult
    static func launch(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = sanitizedEnvironment()
        if let environment {
            for (key, value) in environment {
                env[key] = value
            }
        }
        process.environment = env

        let identifier = ObjectIdentifier(process)
        process.terminationHandler = { _ in
            removeLaunchedProcess(identifier)
        }
        retainLaunchedProcess(process, identifier: identifier)

        do {
            try process.run()
            return true
        } catch {
            process.terminationHandler = nil
            removeLaunchedProcess(identifier)
            return false
        }
    }

    private static func retainLaunchedProcess(_ process: Process, identifier: ObjectIdentifier) {
        launchedProcessesLock.lock()
        defer { launchedProcessesLock.unlock() }
        launchedProcesses[identifier] = process
    }

    private static func removeLaunchedProcess(_ identifier: ObjectIdentifier) {
        launchedProcessesLock.lock()
        defer { launchedProcessesLock.unlock() }
        launchedProcesses.removeValue(forKey: identifier)
    }

    private static func sanitizedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let injectedKeys = environment.keys.filter {
            $0.hasPrefix("DYLD_") || $0.hasPrefix("XCTest")
        }
        for key in injectedKeys {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    private static let launchedProcessesLock = NSLock()
    private static var launchedProcesses: [ObjectIdentifier: Process] = [:]
}

private final class BoundedOutputCapture: @unchecked Sendable {
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
        data.reserveCapacity(limit)
    }

    func readToEnd(from fileHandle: FileHandle) {
        while let chunk = try? fileHandle.read(upToCount: 16 * 1_024),
              !chunk.isEmpty {
            let remainingCapacity = limit - data.count
            if remainingCapacity > 0 {
                data.append(chunk.prefix(remainingCapacity))
            }
        }
    }

    var string: String {
        var validData = data
        while !validData.isEmpty {
            if let value = String(data: validData, encoding: .utf8) {
                return value
            }
            validData.removeLast()
        }
        return ""
    }
}
