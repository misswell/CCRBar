import Foundation

struct CommandResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum CommandRunner {
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

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment {
                env[key] = value
            }
        }
        process.environment = env

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            return CommandResult(
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
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

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment {
                env[key] = value
            }
        }
        process.environment = env

        do {
            try process.run()
            launchedProcesses.append(process)
            return true
        } catch {
            return false
        }
    }

    private static var launchedProcesses: [Process] = []
}
