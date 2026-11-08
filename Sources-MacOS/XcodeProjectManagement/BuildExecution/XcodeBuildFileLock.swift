import CryptoKit
import Darwin
import Foundation

enum XcodeBuildFileLock {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sourcekit-bsp/build-locks", isDirectory: true)
    }

    static func withLock<Result: Sendable>(
        in directory: URL,
        lockDirectory: URL = defaultDirectory,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let file = lockFile(in: directory, lockDirectory: lockDirectory)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw lockError(errno, file: file) }
        // Keep the inode stable for processes that already opened this lock file.
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        while true {
            try Task.checkCancellation()
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK || code == EAGAIN else { throw lockError(code, file: file) }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        return try await operation()
    }

    static func lockFile(in directory: URL, lockDirectory: URL = defaultDirectory) -> URL {
        let path = canonicalDirectory(directory).path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        // Cache cleanup can remove DerivedData while another process is waiting.
        return lockDirectory.appendingPathComponent(digest + ".lock")
    }

    static func canonicalDirectory(_ directory: URL) -> URL {
        var ancestor = directory
        var components: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            components.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        let resolved = components.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.standardizedFileURL
        return URL(fileURLWithPath: resolved.path, isDirectory: true)
    }

    private static func lockError(_ code: Int32, file: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: file.path,
            NSLocalizedDescriptionKey: "Cannot lock the Xcode build directory: \(String(cString: strerror(code)))"
        ])
    }
}
