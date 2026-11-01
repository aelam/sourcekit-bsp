import Foundation

/// Parses consecutive frames. The transport feeds bytes from one ordered consumer.
struct JSONRPCParser {
    typealias Result = Swift.Result<JSONRPCMessage, JSONRPCTransportError>

    private let jsonDecoder = JSONDecoder()
    private let separator = Data("\r\n\r\n".utf8)
    private var buffer = Data()
    private var failed = false

    mutating func feed(chunk: Data) -> [Result] {
        guard !failed else { return [] }
        buffer.append(chunk)
        var results: [Result] = []
        do {
            while let range = buffer.range(of: separator) {
                let headerEnd = range.upperBound
                let length = try contentLength(in: buffer.subdata(in: 0 ..< range.lowerBound))
                guard length <= Int.max - headerEnd else { throw JSONRPCTransportError.invalidContentLength }
                let end = headerEnd + length
                guard buffer.count >= end else { break }
                let body = buffer.subdata(in: headerEnd ..< end)
                buffer.removeSubrange(0 ..< end)
                guard let request = try? jsonDecoder.decode(JSONRPCRequest.self, from: body) else {
                    throw JSONRPCTransportError.invalidMessage
                }
                results.append(.success(JSONRPCMessage(request: request, rawData: body)))
            }
        } catch {
            failed = true
            buffer.removeAll()
            results.append(.failure(error as? JSONRPCTransportError ?? .invalidMessage))
        }
        return results
    }

    func finish() -> JSONRPCTransportError? {
        !failed && !buffer.isEmpty ? .receiveFailed : nil
    }

    private func contentLength(in header: Data) throws -> Int {
        guard let text = String(data: header, encoding: .ascii) else {
            throw JSONRPCTransportError.invalidHeader
        }
        var length: Int?
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { throw JSONRPCTransportError.invalidHeader }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw JSONRPCTransportError.invalidHeader }
            guard name.lowercased() == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard length == nil, !value.isEmpty, value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let parsed = Int(value) else { throw JSONRPCTransportError.invalidContentLength }
            length = parsed
        }
        guard let length else { throw JSONRPCTransportError.missingContentLength }
        return length
    }
}
