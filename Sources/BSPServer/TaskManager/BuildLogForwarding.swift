//
//  BuildLogForwarding.swift
//  sourcekit-bsp
//
//  Streams batched build output to the client via `build/logMessage`.
//

import Foundation

/// Params for the standard BSP `build/logMessage` notification.
public struct BuildLogMessageParams: Codable, Sendable {
    /// 1 = error, 2 = warning, 3 = info, 4 = log.
    public let type: Int
    public let originId: String?
    public let message: String

    public init(type: Int = 4, originId: String? = nil, message: String) {
        self.type = type
        self.originId = originId
        self.message = message
    }
}

/// Thread-safe line buffer. Build output is appended synchronously (from the
/// process reader) and drained periodically by a flush task, so we send a few
/// batched `build/logMessage` notifications instead of one per line — avoiding
/// head-of-line contention with normal BSP traffic on the shared stdout.
final class BuildLogBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(line)
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let lines = buffer
        buffer.removeAll(keepingCapacity: true)
        return lines
    }
}
