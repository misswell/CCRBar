import Foundation
import Network
import Combine

@MainActor
final class CCRStatusMonitor: ObservableObject {
    @Published private(set) var status: CCRStatus = .stopped
    @Published private(set) var gatewayUp = false
    @Published private(set) var managementUp = false

    private var monitorTask: Task<Void, Never>?
    private var isChecking = false
    private var managementPort = AppSettings.defaultManagementPort

    func start(managementPort: UInt16) {
        self.managementPort = managementPort
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
        if status != .running && status != .partiallyRunning {
            status = .starting
        }
    }

    func check(managementPort: UInt16? = nil) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        if let managementPort {
            self.managementPort = managementPort
        }

        async let gateway = checkPort(3456)
        async let management = checkPort(self.managementPort)
        let (gatewayUp, managementUp) = await (gateway, management)

        let newStatus: CCRStatus
        switch (gatewayUp, managementUp) {
        case (true, true):
            newStatus = .running
        case (false, true), (true, false):
            newStatus = .partiallyRunning
        case (false, false):
            newStatus = .stopped
        }

        self.gatewayUp = gatewayUp
        self.managementUp = managementUp
        self.status = newStatus
    }

    private func checkPort(_ port: UInt16) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: "127.0.0.1",
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
