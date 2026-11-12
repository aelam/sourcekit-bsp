import BuildServerProtocol
import Foundation
import Logger
import Support

/// Routes one Attach summary through the existing BSP log channel.
public enum XcodeAttachTiming {
    @TaskLocal
    public static var report: (@Sendable (String) async -> Void)?
}

/// Stages can overlap. The total is elapsed time, not the sum of the stages.
final class AttachTiming: Sendable {
    @TaskLocal
    static var current: AttachTiming?

    private let id = String(UUID().uuidString.prefix(8))
    private let started = ContinuousClock.now
    private let report = XcodeAttachTiming.report
    private let state = CrossPlatformLock(initialState: State())

    enum Outcome: String, Sendable {
        case ok, failed, cancelled, incomplete

        static func failure(_ error: any Error) -> Self {
            error is CancellationError || Task.isCancelled ? .cancelled : .failed
        }
    }

    private struct Stage: Sendable {
        var duration: Duration = .zero
        var count = 0
    }

    private struct State: Sendable {
        var order: [String] = []
        var stages: [String: Stage] = [:]
        var failure: Outcome?
        var failureStage: String?
        var emitted = false
    }

    struct Span: Sendable {
        let timing: AttachTiming
        let stage: String
        let started = ContinuousClock.now

        func finish(_ outcome: Outcome) {
            timing.record(stage, duration: started.duration(to: .now), outcome: outcome)
        }
    }

    func start(_ stage: String) -> Span {
        Span(timing: self, stage: stage)
    }

    func measure<Value>(
        _ stage: String,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Value
    ) async rethrows -> Value {
        let span = start(stage)
        do {
            let value = try await operation()
            span.finish(Task.isCancelled ? .cancelled : .ok)
            return value
        } catch {
            span.finish(.failure(error))
            throw error
        }
    }

    private func record(_ stage: String, duration: Duration, outcome: Outcome) {
        let recorded = state.withLock { state in
            guard !state.emitted else { return false }
            if state.stages[stage] == nil { state.order.append(stage) }
            state.stages[stage, default: Stage()].duration += duration
            state.stages[stage, default: Stage()].count += 1
            if state.failure == nil, outcome == .failed || outcome == .cancelled {
                state.failure = outcome
                state.failureStage = stage
            }
            return true
        }
        if recorded {
            logger.debug("Attach[\(id)] \(stage): \(outcome.rawValue) \(Self.milliseconds(duration))ms")
        }
    }

    func finish(_ outcome: Outcome) async {
        let summary = state.withLock { state -> String? in
            guard !state.emitted else { return nil }
            state.emitted = true
            let stages = state.order.map { name in
                let stage = state.stages[name, default: Stage()]
                let count = stage.count > 1 ? "(n=\(stage.count))" : ""
                return "\(name)=\(Self.milliseconds(stage.duration))ms\(count)"
            }
            let details = stages.joined(separator: " ")
            let failure = state.failureStage.map { "at=\($0) " } ?? ""
            return "Attach[\(id)] \((state.failure ?? outcome).rawValue) \(failure)" +
                "total=\(Self.milliseconds(started.duration(to: .now)))ms \(details)"
        }
        guard let summary else { return }
        logger.info(summary)
        if let report {
            // Cancellation must not prevent the final BSP log message.
            await Task.detached { await report(summary) }.value
        }
    }

    /// Keeps validation and cleanup callbacks intact and reports only after they finish.
    func track(_ backend: DebugSessionBackend) -> DebugSessionBackend {
        let handshake = AttachHandshakeTiming(timing: self)
        return DebugSessionBackend(
            connection: backend.connection,
            validate: {
                try await self.measure("identity.recheck") { try await backend.validate() }
            },
            didStart: {
                await backend.didStart()
                await handshake.finish(.ok)
            },
            recordRequestTiming: { command, duration, success in
                backend.recordRequestTiming(command, duration, success)
                self.record(
                    "dap.\(command)",
                    duration: duration,
                    outcome: success.map { $0 ? .ok : .failed } ?? .incomplete
                )
            },
            stop: {
                await backend.stop()
                await handshake.finish(Task.isCancelled ? .cancelled : .incomplete)
            }
        )
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let value = duration.components
        return String(format: "%.1f", Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15)
    }
}

/// Includes native initialization, Attach, and the final identity check.
private actor AttachHandshakeTiming {
    private let timing: AttachTiming
    private var span: AttachTiming.Span?

    init(timing: AttachTiming) {
        self.timing = timing
        self.span = timing.start("dap.handshake")
    }

    func finish(_ outcome: AttachTiming.Outcome) async {
        guard let pending = span else { return }
        span = nil
        pending.finish(outcome)
        await timing.finish(outcome)
    }
}
