import Foundation
import Darwin

@MainActor
protocol CCRStartLocking: AnyObject {
    func acquire() async -> Bool
    func release()
}

/// Coordinates CCR starts between multiple CCRBar processes.
///
/// `CCRBar` is a menu-bar app and can be launched from both a login item and
/// a manually opened copy. A BSD advisory lock is released automatically when
/// the owning process exits, so a crashed app cannot leave a permanent lock.
@MainActor
final class CCRStartLock: CCRStartLocking {
    private let fileDescriptor: Int32

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let lockURL = homeDirectory
            .appendingPathComponent(".claude-code-router", isDirectory: true)
            .appendingPathComponent("ccrbar-start.lock")

        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        fileDescriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
    }

    deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    func acquire() async -> Bool {
        guard fileDescriptor >= 0 else {
            // The lock is a coordination aid, not a reason to make CCR
            // unusable when the user's home directory is temporarily
            // unavailable.
            return true
        }

        let descriptor = fileDescriptor
        return await Task.detached(priority: .utility) {
            flock(descriptor, LOCK_EX) == 0
        }.value
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        _ = flock(fileDescriptor, LOCK_UN)
    }
}
