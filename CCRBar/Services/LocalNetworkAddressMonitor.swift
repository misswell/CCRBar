import Foundation
import Network
import Combine
import Darwin

/// Tracks the machine's primary LAN IPv4 address so the menu can show the
/// address other devices should use. The address is re-read when the network
/// path changes and on a slow timer, which covers DHCP lease changes that do
/// not flap the path.
@MainActor
final class LocalNetworkAddressMonitor: ObservableObject {
    @Published private(set) var ipv4Address: String?

    private static let refreshIntervalNanoseconds: UInt64 = 10_000_000_000

    private var pathMonitor: NWPathMonitor?
    private var refreshTask: Task<Void, Never>?

    struct InterfaceAddress: Equatable {
        let name: String
        let address: String
    }

    func start() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.ccrbar.local-network-path"))
        pathMonitor = monitor

        refresh()

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.refreshIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() {
        let address = Self.primaryIPv4Address()
        if ipv4Address != address {
            ipv4Address = address
        }
    }

    nonisolated static func primaryIPv4Address() -> String? {
        preferredIPv4(from: currentInterfaces())
    }

    nonisolated static func currentInterfaces() -> [InterfaceAddress] {
        var results: [InterfaceAddress] = []
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else {
            return []
        }
        defer { freeifaddrs(addressList) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard let socketAddress = current.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0 else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            results.append(InterfaceAddress(
                name: String(cString: current.pointee.ifa_name),
                address: String(cString: host)
            ))
        }
        return results
    }

    /// Picks the address a user should share: Wi‑Fi (`en0`) first, then the
    /// other Ethernet interfaces, skipping tunnels, AWDL, bridges and
    /// link-local addresses.
    nonisolated static func preferredIPv4(from interfaces: [InterfaceAddress]) -> String? {
        let excludedPrefixes = [
            "utun", "awdl", "llw", "bridge", "ap", "vmenet", "anpi", "ipsec", "gif", "stf"
        ]
        let candidates = interfaces.filter { interface in
            !excludedPrefixes.contains { interface.name.hasPrefix($0) }
                && !interface.address.hasPrefix("169.254.")
                && !interface.address.hasPrefix("127.")
        }
        guard !candidates.isEmpty else { return nil }

        for preferred in ["en0", "en1"] {
            if let match = candidates.first(where: { $0.name == preferred }) {
                return match.address
            }
        }
        if let ethernet = candidates.first(where: { $0.name.hasPrefix("en") }) {
            return ethernet.address
        }
        return candidates.first?.address
    }
}
