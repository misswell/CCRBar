import Foundation

enum AppSettings {
    static let defaultManagementPort: UInt16 = 3458
    static let managementPortKey = "ccrManagementPort"
    static let defaultGatewayHost = "127.0.0.1"
    static let gatewayHostKey = "ccrGatewayHost"

    static func validatedManagementPort(_ port: Int) -> UInt16 {
        UInt16(min(max(port, 1), 65_535))
    }

    static func validatedGatewayHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultGatewayHost : trimmed
    }
}
