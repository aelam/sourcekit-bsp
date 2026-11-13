import Foundation

/// Batches adjacent output from one channel without delaying pipe reads.
actor ApplicationOutputBuffer {
    typealias Handler = @Sendable (ApplicationOutput) async -> Void
    private let maxBufferedBytes: Int
    private let batchBytes: Int
    private let batchDelay: Duration
    private var handler: Handler?
    private var pending: [ApplicationOutput?] = []
    private var head = 0
    private(set) var bufferedBytes = 0
    private var dropped = false
    private var closed = false
    private var finished = false
    private var timer: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var recent = Data()
    private(set) var simulatorPID: Int?

    var recentText: String {
        String(decoding: recent, as: UTF8.self)
    }

    init(maxBufferedBytes: Int = 4 * 1024 * 1024, batchBytes: Int = 32768, batchDelay: Duration = .milliseconds(20)) {
        self.maxBufferedBytes = maxBufferedBytes
        self.batchBytes = batchBytes
        self.batchDelay = batchDelay
    }

    func append(_ output: ApplicationOutput) {
        guard !closed, !output.text.isEmpty else { return }
        recent.append(contentsOf: output.text.utf8.suffix(8192))
        if recent.count > 8192 { recent.removeFirst(recent.count - 8192) }
        let bytes = output.text.utf8.count
        guard bytes <= maxBufferedBytes - bufferedBytes, pending.count - head < 4096 else {
            reportOverflow()
            return
        }
        bufferedBytes += bytes
        if pending.count > head, let last = pending.last ?? nil,
           last.channel == output.channel, last.text.utf8.count + bytes <= batchBytes {
            pending[pending.count - 1] = .init(channel: last.channel, text: last.text + output.text)
        } else {
            pending.append(output)
        }
        scheduleDrain()
    }

    func reportOverflow() {
        guard !closed else { return }
        dropped = true
        scheduleDrain()
    }

    func recordSimulatorPID(_ pid: Int) {
        simulatorPID = pid
    }

    func connect(_ handler: @escaping Handler) {
        guard !closed else { return }
        self.handler = handler
        scheduleDrain()
    }

    func finish() {
        finished = true
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard handler != nil, drainTask == nil, head < pending.count || dropped else { return }
        if finished || bufferedBytes >= batchBytes {
            startDraining()
        } else if timer == nil {
            timer = Task {
                do { try await Task.sleep(for: batchDelay) } catch { return }
                startDraining()
            }
        }
    }

    private func startDraining() {
        timer?.cancel()
        timer = nil
        guard !closed, drainTask == nil else { return }
        drainTask = Task { await drain() }
    }

    private func drain() async {
        while !closed, let handler {
            if head < pending.count, let output = pending[head] {
                pending[head] = nil
                head += 1
                bufferedBytes -= output.text.utf8.count
                if head == pending.count {
                    pending.removeAll(keepingCapacity: true)
                    head = 0
                } else if head >= 1024, head * 2 >= pending.count {
                    pending.removeFirst(head)
                    head = 0
                }
                await handler(output)
            } else if dropped {
                dropped = false
                await handler(.init(channel: .console, text: "Some application output exceeded the console buffer.\n"))
            } else {
                break
            }
        }
        drainTask = nil
    }

    func flush(timeout: Duration = .seconds(1)) async {
        guard handler != nil else { return }
        finish()
        let deadline = ContinuousClock.now + timeout
        while drainTask != nil, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func close() {
        closed = true
        handler = nil
        pending.removeAll()
        head = 0
        bufferedBytes = 0
        timer?.cancel()
        timer = nil
        drainTask?.cancel()
        drainTask = nil
    }
}
