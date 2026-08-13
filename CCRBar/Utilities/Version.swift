import Foundation

struct Version: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ string: String) {
        let cleaned = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "")

        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }

        major = parts[0]
        minor = parts.count > 1 ? parts[1] : 0
        patch = parts.count > 2 ? parts[2] : 0
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }
}
