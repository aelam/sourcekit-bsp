import Foundation

/// Adapter-specific commands stay on the server. Clients send an ordinary attach request.
struct DAPAttachConfiguration: Sendable {
    let pid: Int
    let program: String
    let commands: [String]

    static func device(id: String, pid: Int, executable: String) -> Self {
        Self(pid: pid, program: executable, commands: deviceCommandSetup + [
            checkedDeviceCommand("device select \(quote(id))"),
            checkedDeviceCommand("device process attach --pid \(pid)")
        ])
    }

    /// Xcode's device commands can return eReturnStatusStarted on success.
    /// A scripted command preserves real failures while accepting that status.
    static var deviceCommandSetup: [String] {
        let script = """
        def _bsp_device_command(debugger, command, result, internal_dict):
            inner = lldb.SBCommandReturnObject()
            debugger.GetCommandInterpreter().HandleCommand(command, inner)
            if inner.GetOutput():
                result.AppendMessage(inner.GetOutput())
            if inner.Succeeded() or (inner.GetStatus() == lldb.eReturnStatusStarted and not inner.GetError()):
                result.SetStatus(lldb.eReturnStatusSuccessFinishResult)
            else:
                result.SetError(inner.GetError() or 'LLDB device command failed')
        """
        return [
            "!script exec(\(quote(script)))",
            "!command script add -f _bsp_device_command bsp-device-command"
        ]
    }

    static func checkedDeviceCommand(_ command: String) -> String {
        "!bsp-device-command \(command)"
    }

    func configure(_ body: Data) throws -> Data {
        guard var message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw DAPRelayError.invalidFrame
        }
        guard message["type"] as? String == "request", message["command"] as? String == "attach" else {
            return body
        }
        var arguments = message["arguments"] as? [String: Any] ?? [:]
        arguments["pid"] = pid
        arguments["program"] = program
        arguments["attachCommands"] = commands
        message["arguments"] = arguments
        return try JSONSerialization.data(withJSONObject: message)
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}

enum DAPRelayError: Error, LocalizedError {
    case invalidFrame
    case closed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidFrame: "Invalid DAP message"
        case .closed: "The device debug connection closed"
        case .timedOut: "The device debugger did not attach before the session timeout"
        }
    }
}

/// Buffers fragmented DAP frames, with limits for both headers and message bodies.
struct DAPFrameBuffer {
    private var buffer = Data()

    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var messages: [Data] = []
        while let separator = buffer.range(of: Data("\r\n\r\n".utf8)) {
            guard separator.lowerBound <= 8192,
                  let header = String(data: buffer[..<separator.lowerBound], encoding: .ascii) else {
                throw DAPRelayError.invalidFrame
            }
            var length: Int?
            for line in header.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { throw DAPRelayError.invalidFrame }
                guard line[..<colon].lowercased() == "content-length" else { continue }
                let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard length == nil, !text.isEmpty, text.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                      let count = Int(text), count <= 64 * 1024 * 1024 else { throw DAPRelayError.invalidFrame }
                length = count
            }
            guard let length else { throw DAPRelayError.invalidFrame }
            let end = separator.upperBound + length
            guard buffer.count >= end else { return messages }
            messages.append(buffer.subdata(in: separator.upperBound ..< end))
            buffer = Data(buffer[end...])
        }
        guard buffer.count <= 8192 else { throw DAPRelayError.invalidFrame }
        return messages
    }

    static func frame(_ body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}
