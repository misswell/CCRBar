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
        guard let candidate = string.split(whereSeparator: { character in
            !(character.isNumber || character == ".")
        }).first(where: { candidate in
            let parts = candidate.split(separator: ".")
            return !parts.isEmpty
                && parts.count <= 3
                && parts.allSatisfy { Int($0) != nil }
        }) else {
            return nil
        }

        let parts = candidate.split(separator: ".")

        major = Int(parts[0])!
        minor = parts.count > 1 ? Int(parts[1])! : 0
        patch = parts.count > 2 ? Int(parts[2])! : 0
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
