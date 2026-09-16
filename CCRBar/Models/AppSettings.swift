import Foundation

enum AppSettings {
    static let defaultManagementPort: UInt16 = 3458
    static let managementPortKey = "ccrManagementPort"
    static let defaultGatewayPort: UInt16 = 3456
    static let defaultGatewayHost = "127.0.0.1"
    /// Binding to the wildcard address keeps loopback working and lets every
    /// local interface (including a LAN address that changes) reach the gateway.
    static let allInterfacesGatewayHost = "0.0.0.0"
    static let gatewayHostKey = "ccrGatewayHost"
    static let gatewayHostModeKey = "ccrGatewayHostMode"

    enum GatewayHostMode: String, CaseIterable {
        /// 127.0.0.1 only; other devices cannot reach the gateway.
        case loopback
        /// 0.0.0.0; loopback and the current LAN address both work.
        case lan
        /// A single operator-supplied address.
        case custom
    }

    static let defaultGatewayHostMode: GatewayHostMode = .lan

    static func validatedManagementPort(_ port: Int) -> UInt16 {
        UInt16(min(max(port, 1), 65_535))
    }

    static func validatedGatewayHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultGatewayHost : trimmed
    }

    static func gatewayHostMode(from rawValue: String) -> GatewayHostMode {
        GatewayHostMode(rawValue: rawValue) ?? defaultGatewayHostMode
    }

    static func effectiveGatewayHost(mode: GatewayHostMode, customHost: String) -> String {
        switch mode {
        case .loopback:
            return defaultGatewayHost
        case .lan:
            return allInterfacesGatewayHost
        case .custom:
            return validatedGatewayHost(customHost)
        }
    }
}
