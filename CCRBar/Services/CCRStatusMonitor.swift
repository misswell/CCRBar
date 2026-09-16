import Foundation
import Network
import Combine

@MainActor
final class CCRStatusMonitor: ObservableObject {
    @Published private(set) var status: CCRStatus = .stopped
    @Published private(set) var gatewayUp = false
    @Published private(set) var managementUp = false

    private var monitorTask: Task<Void, Never>?
    private var managementPort = AppSettings.defaultManagementPort
    private var gatewayHost = AppSettings.defaultGatewayHost
    private var checkGeneration = 0
    private let portChecker: @Sendable (String, UInt16) async -> Bool

    init(
        portChecker: @escaping @Sendable (String, UInt16) async -> Bool = { host, port in
            await CCRStatusMonitor.checkPort(host: host, port: port)
        }
    ) {
        self.portChecker = portChecker
    }

    func start(managementPort: UInt16, gatewayHost: String = AppSettings.defaultGatewayHost) {
        self.managementPort = managementPort
        self.gatewayHost = AppSettings.validatedGatewayHost(gatewayHost)
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func setStarting() {
        checkGeneration += 1
        status = .starting
    }

    func setStopping() {
        checkGeneration += 1
        status = .stopping
    }

    func check(
        managementPort: UInt16? = nil,
        gatewayHost: String? = nil
    ) async {
        if let managementPort {
            self.managementPort = managementPort
        }
        if let gatewayHost {
            self.gatewayHost = AppSettings.validatedGatewayHost(gatewayHost)
        }

        checkGeneration += 1
        let generation = checkGeneration
        let managementPort = self.managementPort
        let gatewayHost = self.gatewayHost

        async let gateway = portChecker(gatewayHost, AppSettings.defaultGatewayPort)
        async let management = portChecker(AppSettings.defaultGatewayHost, managementPort)
        let (gatewayUp, managementUp) = await (gateway, management)

        guard generation == checkGeneration else { return }

        let newStatus: CCRStatus
        switch (gatewayUp, managementUp) {
        case (true, true):
            newStatus = .running
        case (false, true), (true, false):
            newStatus = .partiallyRunning
        case (false, false):
            newStatus = .stopped
        }

        if self.gatewayUp != gatewayUp {
            self.gatewayUp = gatewayUp
        }
        if self.managementUp != managementUp {
            self.managementUp = managementUp
        }
        if self.status != newStatus {
            self.status = newStatus
        }
    }

    private nonisolated static func checkPort(host: String, port: UInt16) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let endpointHost = normalizedProbeHost(host)

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(endpointHost),
                port: endpointPort,
                using: .tcp
            )
            let state = OnceFlag()

            @Sendable func finish(_ result: Bool) {
                guard state.trySet() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                finish(false)
            }
        }
    }

    private nonisolated static func normalizedProbeHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "0.0.0.0" || trimmed == "::" || trimmed == "[::]" {
            return AppSettings.defaultGatewayHost
        }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}
