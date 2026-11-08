import Foundation

public enum DebugAdapterRelayError: Error, LocalizedError {
    case invalidFrame
    case closed
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidFrame: "Invalid DAP message"
        case .closed: "The debug connection closed"
        case .timedOut: "The debug session did not start before the session timeout"
        }
    }
}

/// Buffers fragmented DAP frames, with limits for both headers and message bodies.
public struct DebugAdapterFrameBuffer {
    public init() {}
    private var buffer = Data()

    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var messages: [Data] = []
        while let separator = buffer.range(of: Data("\r\n\r\n".utf8)) {
            guard separator.lowerBound <= 8192,
                  let header = String(data: buffer[..<separator.lowerBound], encoding: .ascii) else {
                throw DebugAdapterRelayError.invalidFrame
            }
            var length: Int?
            for line in header.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { throw DebugAdapterRelayError.invalidFrame }
                guard line[..<colon].lowercased() == "content-length" else { continue }
                let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard length == nil, !text.isEmpty, text.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                      let count = Int(text),
                      count <= 64 * 1024 * 1024 else { throw DebugAdapterRelayError.invalidFrame }
                length = count
            }
            guard let length else { throw DebugAdapterRelayError.invalidFrame }
            let end = separator.upperBound + length
            guard buffer.count >= end else { return messages }
            messages.append(buffer.subdata(in: separator.upperBound ..< end))
            buffer = Data(buffer[end...])
        }
        guard buffer.count <= 8192 else { throw DebugAdapterRelayError.invalidFrame }
        return messages
    }

    public static func frame(_ body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}
