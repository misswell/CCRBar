import Foundation

enum AppSettings {
    static let defaultManagementPort: UInt16 = 3458
    static let managementPortKey = "ccrManagementPort"

    static func validatedManagementPort(_ port: Int) -> UInt16 {
        UInt16(min(max(port, 1), 65_535))
    }
}
