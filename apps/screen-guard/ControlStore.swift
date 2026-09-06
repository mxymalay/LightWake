import Foundation
import Darwin

final class ScreenControlStore {
    let directory: URL
    var modeFile: URL { directory.appendingPathComponent("mode") }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenGuard", isDirectory: true)) {
        self.directory = directory
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }

    func write(_ value: String) throws {
        try locked { try value.write(to: modeFile, atomically: true, encoding: .utf8) }
    }

    func matches(_ token: String) -> Bool {
        (try? String(contentsOf: modeFile, encoding: .utf8)) == token
    }

    // Serialize authorization and the actual command with any concurrent on action.
    // Once write("off") completes, an older sleep command can no longer follow it.
    func performIfMatches(_ token: String, action: () throws -> Void) throws -> Bool {
        try locked {
            guard matches(token) else { return false }
            try action()
            return true
        }
    }
}
