import Foundation
import Testing
@testable import FocusQueueCore

/// A recorded `events/stream` body: active, a heartbeat, and two events.
private let recordedStream = """
    event: message
    data: {"jsonrpc":"2.0","method":"notifications/events/active","params":{"cursor":"EPOCH.0","truncated":false,"heartbeatMs":15000}}

    : comment lines are ignored
    event: message
    data: {"jsonrpc":"2.0","method":"notifications/events/heartbeat","params":{"cursor":"EPOCH.0"}}

    event: message
    data: {"jsonrpc":"2.0","method":"notifications/events/event","params":{"eventId":"ev-1","name":"thread.needs_input","timestamp":"2026-11-23T10:00:00.000Z","cursor":"EPOCH.1","data":{"threadId":"t1","requestId":"r1","kind":"user_input"}}}

    event: message
    data: {"jsonrpc":"2.0","method":"notifications/events/unknown_future_thing","params":{}}

    event: message
    data: {"jsonrpc":"2.0","method":"notifications/events/event","params":{"eventId":"ev-2","name":"thread.run_settled","timestamp":"2026-11-23T10:00:05.000Z","cursor":"EPOCH.2","data":{"threadId":"t1","runId":"run-1","outcome":"completed"}}}


    """

private let recordedMessages: [T3StreamMessage] = [
    .active(cursor: "EPOCH.0", truncated: false, heartbeatMs: 15000),
    .heartbeat(cursor: "EPOCH.0"),
    .event(T3EventOccurrence(
        eventId: "ev-1", name: "thread.needs_input", timestamp: "2026-11-23T10:00:00.000Z", cursor: "EPOCH.1",
        data: ["threadId": "t1", "requestId": "r1", "kind": "user_input"])),
    .event(T3EventOccurrence(
        eventId: "ev-2", name: "thread.run_settled", timestamp: "2026-11-23T10:00:05.000Z", cursor: "EPOCH.2",
        data: ["threadId": "t1", "runId": "run-1", "outcome": "completed"])),
]

private func decodeAll(_ messages: [T3SSEMessage]) -> [T3StreamMessage] {
    messages.compactMap {
        if case .message(let message) = T3StreamDecoder.decode($0) { return message }
        return nil
    }
}

/// Reads a stream to its end or until `count` messages arrive.
private func collect(
    _ stream: AsyncThrowingStream<T3StreamMessage, any Error>, upTo count: Int = .max
) async throws -> [T3StreamMessage] {
    var messages: [T3StreamMessage] = []
    for try await message in stream {
        messages.append(message)
        if messages.count >= count { break }
    }
    return messages
}

@Suite("T3 SSE parser and stream")
struct T3StreamParserTests {
    // MARK: Pure parser

    @Test("The recorded body yields its messages in order with correct fields")
    func recordedBody() {
        #expect(decodeAll(T3SSEParser.parse(Data(recordedStream.utf8))) == recordedMessages)
    }

    @Test("The captured Task 0 fixture parses into known messages, when present")
    func capturedFixture() throws {
        let url = T3Fixtures.directory.appendingPathComponent("stream.sse")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let messages = decodeAll(T3SSEParser.parse(try Data(contentsOf: url)))
        guard case .active(let cursor, _, _) = try #require(messages.first) else {
            Issue.record("first message is not active: \(messages)"); return
        }
        #expect(T3Cursor(cursor) != nil)
        for message in messages {
            switch message {
            case .event(let event):
                #expect(!event.eventId.isEmpty)
                #expect(!event.name.isEmpty)
                #expect(T3Cursor(event.cursor) != nil)
            case .heartbeat(let cursor):
                #expect(T3Cursor(cursor) != nil)
            default: break
            }
        }
    }

    @Test("A data line split across chunks parses as one message")
    func splitAcrossChunks() {
        var parser = T3SSEParser()
        var out: [T3SSEMessage] = []
        out += parser.feed("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/ev")
        #expect(out.isEmpty)
        out += parser.feed("ents/heartbeat\",\"params\":{\"cursor\":\"mwsp6cxs.26\"}}\r")
        #expect(out.isEmpty)
        out += parser.feed("\n\r")
        out += parser.feed("\n")
        #expect(out.count == 1)
        #expect(decodeAll(out) == [.heartbeat(cursor: "mwsp6cxs.26")])
    }

    @Test("Every byte-level split of the recorded body yields the same messages")
    func everySplit() {
        let bytes = Array(recordedStream.utf8)
        for split in stride(from: 1, to: bytes.count, by: 7) {
            var parser = T3SSEParser()
            var out = parser.feed(bytes[..<split])
            out += parser.feed(bytes[split...])
            if let last = parser.finish() { out.append(last) }
            #expect(decodeAll(out) == recordedMessages, "split at \(split)")
        }
    }

    @Test("Multi-line data, CRLF, CR, comments, ids and event names")
    func fieldRules() {
        let text = ":hello\r\nevent: custom\r\nid: 7\r\ndata: line one\r\ndata:line two\r\n\r\ndata\rid\r\r: only comment\n\nretry: 10\nfoo: bar\n\n"
        let messages = T3SSEParser.parse(Data(text.utf8))
        #expect(messages == [
            T3SSEMessage(event: "custom", data: "line one\nline two", id: "7"),
            T3SSEMessage(event: nil, data: "", id: ""),
        ])
    }

    @Test("A final message without its blank line is dispatched on finish")
    func finishDispatches() {
        var parser = T3SSEParser()
        #expect(parser.feed("data: tail").isEmpty)
        #expect(parser.finish() == T3SSEMessage(event: nil, data: "tail", id: nil))
        #expect(parser.finish() == nil)
    }

    @Test("A leading BOM is skipped")
    func bom() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("data: x\n\n".utf8)
        #expect(T3SSEParser.parse(data) == [T3SSEMessage(event: nil, data: "x", id: nil)])
    }

    @Test("Error and terminated notifications map; unknown methods and junk are ignored")
    func mapping() {
        func decode(_ json: String) -> T3StreamDecoder.Decoded {
            T3StreamDecoder.decode(T3SSEMessage(event: nil, data: json, id: nil))
        }
        #expect(decode(#"{"jsonrpc":"2.0","method":"notifications/events/error","params":{"message":"buffer overflow"}}"#)
            == .message(.error("buffer overflow")))
        #expect(decode(#"{"jsonrpc":"2.0","method":"notifications/events/error","params":{"error":{"code":-1,"message":"nested"}}}"#)
            == .message(.error("nested")))
        #expect(decode(#"{"jsonrpc":"2.0","method":"notifications/events/terminated","params":{}}"#) == .message(.terminated))
        #expect(decode(#"{"jsonrpc":"2.0","method":"notifications/events/terminated"}"#) == .message(.terminated))
        #expect(decode(#"{"jsonrpc":"2.0","method":"notifications/other","params":{}}"#) == .ignored)
        #expect(decode(#"{"jsonrpc":"2.0","method":"notifications/events/event","params":{"name":"x"}}"#) == .ignored)
        #expect(decode("not json") == .ignored)
        #expect(decode(#"{"jsonrpc":"2.0","id":3,"result":{}}"#) == .response(["jsonrpc": "2.0", "id": 3, "result": [:]]))
    }

    @Test("T3Cursor splits epoch and sequence")
    func cursor() {
        let cursor = T3Cursor("mwsp6cxs.26")
        #expect(cursor?.epoch == "mwsp6cxs")
        #expect(cursor?.sequence == 26)
        #expect(T3Cursor("nodot") == nil)
        #expect(T3Cursor(".5") == nil)
        #expect(T3Cursor("abc.x") == nil)
    }

    // MARK: Live stream over the stub

    @Test("stream sends events/stream with headers and params, and yields messages incrementally")
    func streamRequest() async throws {
        let chunks = stride(from: 0, to: recordedStream.utf8.count, by: 40).map { start -> String in
            let bytes = Array(recordedStream.utf8)
            return String(decoding: bytes[start..<min(start + 40, bytes.count)], as: UTF8.self)
        }
        let stub = T3StubbedTransport { _ in .sse(chunks, delay: 0.002) }
        let stream = await stub.transport.stream(
            name: "thread.needs_input", arguments: ["projectIds": ["p1"]], heartbeatMs: 15000)
        let messages = try await collect(stream)
        #expect(messages == recordedMessages)

        let request = try #require(stub.requests.first)
        #expect(request.headers["mcp-method"] == "events/stream")
        #expect(request.headers["mcp-name"] == "thread.needs_input")
        #expect(request.headers["mcp-protocol-version"] == "2026-07-28")
        #expect(request.headers["authorization"] == "Bearer secret-token")
        #expect(request.headers["accept"] == "application/json, text/event-stream")
        let body = try #require(request.json)
        #expect(body["method"] == "events/stream")
        let params = try #require(body["params"])
        #expect(params["name"] == "thread.needs_input")
        #expect(params["arguments"] == ["projectIds": ["p1"]])
        #expect(params["heartbeatMs"] == 15000)
        #expect(params["_meta"]?["io.modelcontextprotocol/protocolVersion"] == "2026-07-28")
        #expect(params["_meta"]?["io.modelcontextprotocol/clientInfo"] == ["name": "focus-queue", "version": "1.2.3"])
    }

    @Test("terminated ends the stream")
    func terminatedEnds() async throws {
        let stub = T3StubbedTransport { _ in
            .sse([
                "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/events/active\",\"params\":{\"cursor\":\"e.1\",\"truncated\":true}}\n\n",
                "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/events/terminated\",\"params\":{}}\n\n",
            ], keepOpen: true)
        }
        let messages = try await collect(await stub.transport.stream(name: "thread.run_settled", arguments: [:], heartbeatMs: 1000))
        #expect(messages == [.active(cursor: "e.1", truncated: true, heartbeatMs: nil), .terminated])
    }

    @Test("-32601 on events/stream throws serverTooOld")
    func streamTooOld() async {
        let stub = T3StubbedTransport { _ in .json(t3RPCError(code: -32601, message: "Method not found")) }
        let stream = await stub.transport.stream(name: "thread.run_settled", arguments: [:], heartbeatMs: 1000)
        let error = await t3CaughtError { _ = try await collect(stream) }
        #expect(error as? T3Error == .serverTooOld(nil))
    }

    @Test("A JSON-RPC error inside the event stream throws rejected")
    func streamRPCErrorInSSE() async {
        let stub = T3StubbedTransport { _ in
            .sse(["data: {\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Unknown event\"}}\n\n"])
        }
        let stream = await stub.transport.stream(name: "nope", arguments: [:], heartbeatMs: 1000)
        let error = await t3CaughtError { _ = try await collect(stream) }
        #expect(error as? T3Error == .rejected(code: "-32602", message: "Unknown event"))
    }

    @Test("Stream errors classify like requests", arguments: [
        (T3StubReply.fail(.cannotConnectToHost), T3Error.notRunning),
        (T3StubReply.body("down", status: 503), T3Error.outcomeUnknown("HTTP 503")),
        (T3StubReply.body("nope", status: 401), T3Error.unauthorized),
    ])
    func streamErrors(reply: T3StubReply, expected: T3Error) async {
        let stub = T3StubbedTransport { _ in reply }
        let stream = await stub.transport.stream(name: "thread.run_settled", arguments: [:], heartbeatMs: 1000)
        let error = await t3CaughtError { _ = try await collect(stream) }
        #expect(error as? T3Error == expected)
    }

    @Test("Cancelling the consumer ends the stream within 1 s and closes the connection")
    func consumerCancel() async throws {
        let active = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/events/active\",\"params\":{\"cursor\":\"e.0\",\"truncated\":false}}\n\n"
        let stub = T3StubbedTransport { _ in .sse([active], keepOpen: true) }
        let stream = await stub.transport.stream(name: "thread.run_settled", arguments: [:], heartbeatMs: 15000)
        let consumer = Task { () -> Int in
            var count = 0
            do { for try await _ in stream { count += 1 } } catch {}
            return count
        }
        #expect(await eventually { stub.requests.count == 1 })
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        consumer.cancel()
        let count = await consumer.value
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(count == 1)
        #expect(await eventually(timeout: 1) { stub.stopCount == 1 })
    }

    @Test("cancelAll ends open streams within 1 s")
    func cancelAllStream() async throws {
        let active = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/events/active\",\"params\":{\"cursor\":\"e.0\",\"truncated\":false}}\n\n"
        let stub = T3StubbedTransport { _ in .sse([active], keepOpen: true) }
        let stream = await stub.transport.stream(name: "thread.run_settled", arguments: [:], heartbeatMs: 15000)
        let consumer = Task { () -> [T3StreamMessage] in (try? await collect(stream)) ?? [] }
        #expect(await eventually { stub.requests.count == 1 })
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        await stub.transport.cancelAll()
        _ = await consumer.value
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(await eventually(timeout: 1) { stub.stopCount == 1 })
    }
}
