import Foundation
import Testing
@testable import JSONRPCConnection

struct JSONRPCParserTests {
    @Test
    func acceptsEverySplitPointIncludingUTF8AndMultipleHeaders() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"buildTarget/compile","params":{"text":"编译📦"}}"#.utf8)
        for headers in [
            "Content-Length: \(body.count)\r\n\r\n",
            "Content-Length: \(body.count)\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n",
            "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncOnTeNt-LeNgTh: \(body.count)\r\n\r\n"
        ] {
            let frame = Data(headers.utf8) + body
            for offset in 0 ... frame.count {
                var parser = JSONRPCParser()
                let results = parser.feed(chunk: Data(frame.prefix(offset))) + parser
                    .feed(chunk: Data(frame.dropFirst(offset)))
                try #require(results.count == 1)
                #expect(try results[0].get().rawData == body)
                #expect(parser.finish() == nil)
            }
        }
    }

    @Test
    func parsesCoalescedFramesAndRetainsPartialNextFrame() throws {
        let first = frame(id: 1)
        let second = frame(id: 2)
        let third = frame(id: 3)
        var parser = JSONRPCParser()
        let complete = parser.feed(chunk: first + second + third.prefix(12))
        #expect(try complete.map { try $0.get().request.id } == [.int(1), .int(2)])
        let remaining = parser.feed(chunk: Data(third.dropFirst(12)))
        #expect(try remaining.map { try $0.get().request.id } == [.int(3)])
    }

    @Test
    func rejectsInvalidLengthsWithoutCrashingOrReusingBrokenBuffer() throws {
        let headers = [
            "Content-Length: -1",
            "Content-Length: +1",
            "Content-Length: words",
            "Content-Length: \(Int.max)",
            "Content-Length: \(Int.max)0",
            "Content-Length: 1\r\nContent-Length: 1"
        ]
        for header in headers {
            var parser = JSONRPCParser()
            let result = try #require(parser.feed(chunk: Data((header + "\r\n\r\n").utf8)).first)
            guard case .failure(.invalidContentLength) = result else {
                Issue.record("Expected invalidContentLength")
                continue
            }
            #expect(parser.feed(chunk: frame(id: 1)).isEmpty)
        }
    }

    @Test
    func distinguishesMissingLengthAndInvalidMessage() throws {
        var parser = JSONRPCParser()
        let missing = try #require(parser.feed(chunk: Data("Content-Length-Extra: 0\r\n\r\n".utf8)).first)
        if case .failure(.missingContentLength) = missing {} else { Issue.record("Expected missingContentLength") }
        parser = JSONRPCParser()
        let invalid = try #require(parser.feed(chunk: Data("Content-Length: 1\r\n\r\n{".utf8)).first)
        if case .failure(.invalidMessage) = invalid {} else { Issue.record("Expected invalidMessage") }
    }
}

struct StdioTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func preservesOrderAcrossSeparateHeaderAndBodyWrites() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = StdioJSONRPCConnectionTransport(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )
        let listening = Task { try await transport.listen() }
        defer { transport.close() }
        let writing = Task.detached {
            for id in 0 ..< 2000 {
                let body = Data(
                    "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"buildTarget/compile\",\"params\":{\"text\":\"编译📦\"}}"
                        .utf8
                )
                try input.fileHandleForWriting.write(contentsOf: Data("Content-Length: \(body.count)\r\n\r\n".utf8))
                await Task.yield()
                try input.fileHandleForWriting.write(contentsOf: body.prefix(31))
                await Task.yield()
                try input.fileHandleForWriting.write(contentsOf: body.dropFirst(31))
            }
            try input.fileHandleForWriting.close()
        }
        var ids: [JSONRPCID?] = []
        for await message in transport.messageStream {
            ids.append(message.request.id)
        }
        try await writing.value
        try await listening.value
        #expect(ids == (0 ..< 2000).map { .int($0) })
        var errors: [JSONRPCTransportError] = []
        for await error in transport.errorStream {
            errors.append(error)
        }
        #expect(errors.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func closesOnMalformedHeaderInsteadOfLeavingRequestsPending() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = StdioJSONRPCConnectionTransport(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )
        let listening = Task { try await transport.listen() }
        defer { transport.close() }
        try input.fileHandleForWriting.write(contentsOf: Data("Content-Type: application/json\r\n\r\n".utf8))
        var errors = transport.errorStream.makeAsyncIterator()
        let error = try #require(await errors.next())
        if case .missingContentLength = error {} else { Issue.record("Expected missingContentLength") }
        try await listening.value
        var messages = transport.messageStream.makeAsyncIterator()
        #expect(await messages.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func closesOnEOFAndReportsTruncatedFrames() async throws {
        for data in [Data(), Data("Content-Length: 20\r\n\r\n{".utf8)] {
            let input = Pipe()
            let output = Pipe()
            let transport = StdioJSONRPCConnectionTransport(
                input: input.fileHandleForReading,
                output: output.fileHandleForWriting
            )
            let listening = Task { try await transport.listen() }
            defer { transport.close() }
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
            try await listening.value
            var errors = transport.errorStream.makeAsyncIterator()
            let error = await errors.next()
            if data.isEmpty {
                #expect(error == nil)
            } else if case .receiveFailed = error {} else {
                Issue.record("Expected a truncated frame error")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func handlesImmediateCancellationAndRepeatedClose() async throws {
        for _ in 0 ..< 30 {
            let input = Pipe()
            let output = Pipe()
            let transport = StdioJSONRPCConnectionTransport(
                input: input.fileHandleForReading,
                output: output.fileHandleForWriting
            )
            let listening = Task { try await transport.listen() }
            listening.cancel()
            _ = await listening.result
            transport.close()
            transport.close()
            await #expect(throws: JSONRPCTransportError.self) { try await transport.listen() }
        }
    }
}

private func frame(id: Int) -> Data {
    let body = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"test\"}".utf8)
    return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
}
