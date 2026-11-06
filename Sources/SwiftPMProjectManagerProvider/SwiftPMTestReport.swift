import BuildServerProtocol
import Foundation

struct SwiftPMTestReport {
    private struct State {
        var started = false
        var status: TestStatus?
        var messages: [String] = []
    }

    private struct Record: Decodable {
        struct Issue: Decodable { let isKnown: Bool? }
        struct Message: Decodable { let text: String }
        struct Payload: Decodable {
            let kind: String
            let id: String?
            let testID: String?
            let issue: Issue?
            let messages: [Message]?
        }

        let version: Int
        let kind: String
        let payload: Payload
    }

    private var states: [String: State] = [:]
    private(set) var problems: [String] = []
    let module: String

    init(module: String) {
        self.module = module
    }

    mutating func readSwiftTesting(_ data: Data) {
        let decoder = JSONDecoder()
        var records: [Record] = []
        for line in data.split(separator: 10) where !line.isEmpty {
            guard let record = try? decoder.decode(Record.self, from: Data(line)), record.version == 0 else {
                problems.append("Swift Testing returned an invalid event record.")
                continue
            }
            records.append(record)
        }
        var identifiers: [String: String] = [:]
        var sources: [String: String] = [:]
        for record in records where record.kind == "test" && record.payload.kind == "function" {
            guard let raw = record.payload.id, let id = swiftTestingID(raw) else { continue }
            if let source = sources[id], source != raw {
                problems.append("More than one test has the identifier '\(id)'.")
            }
            sources[id] = raw
            identifiers[raw] = id
            if states[id] == nil { states[id] = State() }
        }
        for record in records where record.kind == "event" {
            guard let raw = record.payload.testID, let id = identifiers[raw] else { continue }
            recordEvent(record.payload, id: id)
        }
    }

    private mutating func recordEvent(_ payload: Record.Payload, id: String) {
        switch payload.kind {
        case "testStarted":
            states[id, default: State()].started = true
        case "issueRecorded":
            if payload.issue?.isKnown != true {
                states[id, default: State()].status = .failed
                states[id, default: State()].messages += payload.messages?.map(\.text) ?? []
            }
        case "testEnded":
            if states[id]?.status != .failed { states[id, default: State()].status = .passed }
        case "testSkipped":
            states[id, default: State()].status = .skipped
            states[id, default: State()].messages += payload.messages?.map(\.text) ?? []
        default:
            break
        }
    }

    mutating func readXCTest(_ output: String) {
        let pattern = #"^Test Case '(.+)' (started|passed|failed|skipped)(?:\.| \([0-9.]+ seconds\)\.)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return }
        for match in expression.matches(in: output, range: NSRange(output.startIndex..., in: output)) {
            guard let nameRange = Range(match.range(at: 1), in: output),
                  let statusRange = Range(match.range(at: 2), in: output),
                  let id = xctestID(String(output[nameRange])) else { continue }
            switch output[statusRange] {
            case "started": states[id, default: State()].started = true
            case "passed": states[id, default: State()].status = .passed
            case "skipped": states[id, default: State()].status = .skipped
            case "failed":
                states[id, default: State()].status = .failed
                states[id, default: State()].messages.append("XCTest reported a failure. See the test output.")
            default: break
            }
        }
    }

    mutating func finish(selected: [SwiftPMTestSelection.Test]?, cancelled: Bool) -> [TestCaseResult] {
        if !cancelled {
            for (id, state) in states where state.status == nil {
                problems.append("No result was reported for '\(id)'.")
            }
        }
        let results = states.sorted { $0.key < $1.key }.compactMap { id, state -> TestCaseResult? in
            guard let status = state.status ?? (cancelled && state.started ? .cancelled : nil) else { return nil }
            return TestCaseResult(
                displayName: id,
                status: status,
                message: state.messages.isEmpty ? nil : state.messages.joined(separator: "\n"),
                testId: id
            )
        }
        if !cancelled, results.isEmpty { problems.append("No test results were reported for module '\(module)'.") }
        if !cancelled, let selected {
            let requested = Set(selected.map(\.id))
            let completed = Set(results.compactMap(\.testId))
            for id in requested.subtracting(completed).sorted() {
                problems.append("No result was reported for selected test '\(id)'.")
            }
            for id in completed.subtracting(requested).sorted() {
                problems.append("A test outside the selection ran: '\(id)'.")
            }
        }
        return results
    }

    private func swiftTestingID(_ raw: String) -> String? {
        guard raw.hasPrefix(module + ".") else { return nil }
        let scoped = String(raw.dropFirst(module.count + 1))
        guard let suffix = scoped.range(of: ")/", options: .backwards) else {
            return scoped.hasSuffix(")") ? scoped : nil
        }
        return String(scoped[...suffix.lowerBound])
    }

    private func xctestID(_ raw: String) -> String? {
        let identifier: String
        if raw.hasPrefix("-["), raw.hasSuffix("]") {
            let parts = raw.dropFirst(2).dropLast().split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].hasPrefix(module + ".") else { return nil }
            identifier = String(parts[0].dropFirst(module.count + 1)) + "/" + parts[1]
        } else {
            let scoped = raw.hasPrefix(module + ".") ? String(raw.dropFirst(module.count + 1)) : raw
            guard let separator = scoped.lastIndex(of: ".") else { return nil }
            identifier = String(scoped[..<separator]) + "/" + scoped[scoped.index(after: separator)...]
        }
        return identifier.hasSuffix("()") ? identifier : identifier + "()"
    }
}

final class SwiftPMTestOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var text: String {
        lock.withLock { storage }
    }

    func append(_ text: String) {
        lock.withLock { storage += text }
    }
}
