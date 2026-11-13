import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct ApplicationOutputBatchTests {
    @Test
    func batchesBurstOutputAndFlushesItsTailInOrder() async {
        let buffer = ApplicationOutputBuffer()
        let lines = (0 ..< 20000).map { "line \($0)\n" }
        for line in lines {
            await buffer.append(.init(channel: .stdout, text: line))
        }
        await buffer.append(.init(channel: .stderr, text: "error\n"))
        await buffer.append(.init(channel: .stdout, text: "tail\n"))
        let received = CrossPlatformLock(initialState: [ApplicationOutput]())
        await buffer.connect { output in received.withLock { $0.append(output) } }
        await buffer.flush()
        let output = received.withLock { $0 }
        #expect(output.count < 20)
        #expect(output.map(\.text).joined() == lines.joined() + "error\ntail\n")
        #expect(output.suffix(2).map(\.channel) == [.stderr, .stdout])
        #expect(output.allSatisfy { $0.text.utf8.count <= 32768 })
        #expect(await buffer.bufferedBytes == 0)
        await buffer.close()
    }

    @Test
    func boundsTheQueueAndReportsOverflow() async {
        let buffer = ApplicationOutputBuffer(maxBufferedBytes: 65536)
        let text = String(repeating: "a", count: 8192)
        for _ in 0 ..< 100 {
            await buffer.append(.init(channel: .stdout, text: text))
        }
        #expect(await buffer.bufferedBytes == 65536)
        #expect(await buffer.recentText.utf8.count == 8192)
        let received = CrossPlatformLock(initialState: [ApplicationOutput]())
        await buffer.connect { output in received.withLock { $0.append(output) } }
        await buffer.flush()
        #expect(received.withLock { $0.filter { $0.channel == .stdout }.map(\.text).joined().utf8.count } == 65536)
        #expect(received.withLock { $0.count(where: { $0.channel == .console }) } == 1)
        await buffer.close()
    }

    @Test
    func longUnicodeOutputWithoutNewlinesHasBoundedDecodingMemory() {
        let original = String(repeating: "中文🙂", count: 10000) + "\r\nlast"
        let bytes = Array(original.utf8)
        var decoder = ApplicationConsoleText()
        var batches: [String] = []
        for start in stride(from: 0, to: bytes.count, by: 8191) {
            decoder.append(Data(bytes[start ..< min(start + 8191, bytes.count)]))
            while let text = decoder.take() {
                batches.append(text)
            }
            #expect(decoder.bufferedBytes < 32768)
        }
        if let tail = decoder.finish() { batches.append(tail) }
        #expect(batches.joined() == original.replacingOccurrences(of: "\r\n", with: "\n") + "\n")
        #expect(batches.allSatisfy { $0.utf8.count <= 32768 })
    }

    @Test
    func resetsAnIncompleteLineAfterDroppedPipeBytes() {
        var decoder = ApplicationConsoleText()
        decoder.append(Data("partial".utf8))
        decoder.discardPartialLine()
        decoder.append(Data("lost suffix\nnext line\n".utf8))
        #expect(decoder.take() == "next line\n")
        #expect(decoder.finish() == nil)
    }

    @Test
    func removesEachAppleTimestampInABatch() {
        let line = "2026-11-12 16:51:50.715363+0900 App[123:456] message\n"
        #expect(ApplicationOutput(channel: .stdout, text: line + "continuation\n" + line).runMessage
            == "App[123:456] message\ncontinuation\nApp[123:456] message")
    }

    @Test(.timeLimit(.minutes(1)))
    func pipeReaderKeepsDrainingWhenItsConsumerIsPaused() async throws {
        let pipe = Pipe()
        let release = AsyncStream<Void>.makeStream()
        let state = CrossPlatformLock(initialState: (entered: false, bytes: 0, overflows: 0))
        let reader = Task {
            await ApplicationConsoleReader.stream(pipe.fileHandleForReading, text: { text in
                let first = state.withLock { state in
                    let first = !state.entered
                    state.entered = true
                    state.bytes += text.utf8.count
                    return first
                }
                if first { for await _ in release.stream {
                    break
                } }
            }, overflow: { state.withLock { $0.overflows += 1 } })
        }
        defer {
            release.continuation.finish()
            reader.cancel()
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        while !state.withLock({ $0.entered }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let writer = Task.detached {
            try pipe.fileHandleForWriting.write(contentsOf: Data(String(repeating: "line\n", count: 400_000).utf8))
            try pipe.fileHandleForWriting.close()
        }
        try await writer.value
        release.continuation.yield(())
        release.continuation.finish()
        await reader.value
        #expect(state.withLock { $0.overflows } > 0)
        #expect(state.withLock { $0.bytes } < 1024 * 1024)
    }
}
