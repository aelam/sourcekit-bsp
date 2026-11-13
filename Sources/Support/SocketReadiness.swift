import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Coalesces socket readiness, deadline expiry, and explicit state changes.
package final class SocketReadiness: Sendable {
    private struct Key: Hashable, Sendable {
        let fd: Int32
        let writable: Bool
    }

    private struct State: Sendable {
        var watches: [Key: SocketWatch] = [:]
        var deadline: ContinuousClock.Instant?
        var timer: Task<Void, Never>?
        var closed = false
    }

    private let state = CrossPlatformLock(initialState: State())
    private let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    package init() {}
    deinit { finish() }

    package func signal() {
        events.continuation.yield(())
    }

    package func remove(fd: Int32) {
        state.withLock { state in
            for key in Array(state.watches.keys) where key.fd == fd {
                state.watches.removeValue(forKey: key)?.cancel()
            }
        }
    }

    package func wait(read: [Int32], write: [Int32], until deadline: ContinuousClock.Instant?) async throws {
        let keys = Set(read.filter { $0 >= 0 }.map { Key(fd: $0, writable: false) }
            + write.filter { $0 >= 0 }.map { Key(fd: $0, writable: true) })
        let continuation = events.continuation
        let error: (any Error)? = state.withLock { state in
            guard !state.closed else { return nil }
            for key in Array(state.watches.keys) where !keys.contains(key) {
                state.watches.removeValue(forKey: key)?.cancel()
            }
            for key in keys {
                if state.watches[key] == nil {
                    do {
                        state.watches[key] = try SocketWatch(fd: key.fd, writable: key.writable) {
                            continuation.yield(())
                        }
                    } catch { return error }
                }
                state.watches[key]?.arm()
            }
            if state.deadline != deadline {
                state.timer?.cancel()
                state.deadline = deadline
                state.timer = deadline.map { deadline in
                    Task { [events] in
                        do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                        events.continuation.yield(())
                    }
                }
            }
            return nil
        }
        if let error { throw error }
        await withTaskCancellationHandler {
            var iterator = events.stream.makeAsyncIterator()
            _ = await iterator.next()
        } onCancel: { self.signal() }
        try Task.checkCancellation()
    }

    package func finish() {
        state.withLock { state in
            state.closed = true
            for watch in state.watches.values {
                watch.cancel()
            }
            state.watches.removeAll()
            state.timer?.cancel()
            state.timer = nil
        }
        events.continuation.finish()
    }
}

private final class SocketWatch: @unchecked Sendable {
    private struct State: Sendable {
        var armed = false
        var cancelled = false
    }

    private let state = CrossPlatformLock(initialState: State())
    private let source: any DispatchSourceProtocol

    init(fd: Int32, writable: Bool, ready: @escaping @Sendable () -> Void) throws {
        // The source owns a duplicate so cancellation cannot race reuse of the caller's descriptor.
        let watched = dup(fd)
        guard watched >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF) }
        _ = fcntl(watched, F_SETFD, FD_CLOEXEC)
        if writable {
            source = DispatchSource.makeWriteSource(fileDescriptor: watched)
        } else {
            source = DispatchSource.makeReadSource(fileDescriptor: watched)
        }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let notify = state.withLock { state in
                guard state.armed, !state.cancelled else { return false }
                source.suspend()
                state.armed = false
                return true
            }
            if notify { ready() }
        }
        source.setCancelHandler { close(watched) }
    }

    deinit { cancel() }

    func arm() {
        state.withLock { state in
            guard !state.cancelled, !state.armed else { return }
            state.armed = true
            source.resume()
        }
    }

    func cancel() {
        state.withLock { state in
            guard !state.cancelled else { return }
            state.cancelled = true
            source.cancel()
            if !state.armed { source.resume() }
        }
    }
}
