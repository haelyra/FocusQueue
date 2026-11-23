import Foundation
import Testing
@testable import FocusQueueCore

// MARK: - Stub URLProtocol

/// What a stubbed request answers. Each test registers a handler under its own host, so suites run in parallel.
struct T3StubReply: Sendable {
    enum Kind: Sendable {
        case respond(status: Int, headers: [String: String], chunks: [Data], chunkDelay: TimeInterval, keepOpen: Bool)
        case fail(URLError.Code)
        case hang
    }
    var kind: Kind

    static func json(_ value: JSONValue, status: Int = 200) -> T3StubReply {
        T3StubReply(kind: .respond(
            status: status, headers: ["content-type": "application/json"],
            chunks: [(try? value.data()) ?? Data()], chunkDelay: 0, keepOpen: false))
    }

    static func body(_ text: String, status: Int, contentType: String = "text/plain") -> T3StubReply {
        T3StubReply(kind: .respond(status: status, headers: ["content-type": contentType], chunks: [Data(text.utf8)], chunkDelay: 0, keepOpen: false))
    }

    static func sse(_ chunks: [String], delay: TimeInterval = 0, keepOpen: Bool = false) -> T3StubReply {
        T3StubReply(kind: .respond(
            status: 200, headers: ["content-type": "text/event-stream"],
            chunks: chunks.map { Data($0.utf8) }, chunkDelay: delay, keepOpen: keepOpen))
    }

    static func fail(_ code: URLError.Code) -> T3StubReply { T3StubReply(kind: .fail(code)) }
    static let hang = T3StubReply(kind: .hang)
}

/// A captured request with its body read from the stream URLSession hands protocols.
struct T3CapturedRequest: Sendable {
    var url: URL?
    var method: String?
    var headers: [String: String]
    var body: Data

    var json: JSONValue? { try? JSONValue.parse(body) }
}

final class T3StubRegistry: @unchecked Sendable {
    static let shared = T3StubRegistry()
    private let lock = NSLock()
    private var handlers: [String: @Sendable (T3CapturedRequest) -> T3StubReply] = [:]
    private var captured: [String: [T3CapturedRequest]] = [:]
    private var stopped: [String: Int] = [:]

    func register(host: String, _ handler: @escaping @Sendable (T3CapturedRequest) -> T3StubReply) {
        lock.withLock { handlers[host] = handler }
    }

    func handle(host: String, request: T3CapturedRequest) -> T3StubReply {
        lock.withLock {
            captured[host, default: []].append(request)
            return handlers[host]?(request) ?? .fail(.cannotFindHost)
        }
    }

    func requests(host: String) -> [T3CapturedRequest] { lock.withLock { captured[host] ?? [] } }
    func noteStopped(host: String) { lock.withLock { stopped[host, default: 0] += 1 } }
    func stopCount(host: String) -> Int { lock.withLock { stopped[host] ?? 0 } }
}

final class T3StubURLProtocol: URLProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var isStopped = false
    private var stopped: Bool { stateLock.withLock { isStopped } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let captured = T3CapturedRequest(
            url: request.url, method: request.httpMethod,
            headers: (request.allHTTPHeaderFields ?? [:]).reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value },
            body: Self.readBody(request))
        let reply = T3StubRegistry.shared.handle(host: host, request: captured)
        switch reply.kind {
        case .hang:
            return
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .respond(let status, let headers, let chunks, let delay, let keepOpen):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if delay == 0 {
                for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
                if !keepOpen { client?.urlProtocolDidFinishLoading(self) }
            } else {
                deliver(chunks[...], delay: delay, keepOpen: keepOpen)
            }
        }
    }

    private func deliver(_ chunks: ArraySlice<Data>, delay: TimeInterval, keepOpen: Bool) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard !stopped else { return }
            guard let chunk = chunks.first else {
                if !keepOpen { client?.urlProtocolDidFinishLoading(self) }
                return
            }
            client?.urlProtocol(self, didLoad: chunk)
            deliver(chunks.dropFirst(), delay: delay, keepOpen: keepOpen)
        }
    }

    override func stopLoading() {
        stateLock.withLock { isStopped = true }
        T3StubRegistry.shared.noteStopped(host: request.url?.host ?? "")
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A transport wired to the stub under a fresh host.
struct T3StubbedTransport {
    let host = "t3-\(UUID().uuidString.lowercased()).test"
    let transport: T3McpTransport

    init(requestTimeout: TimeInterval = 30, _ handler: @escaping @Sendable (T3CapturedRequest) -> T3StubReply) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T3StubURLProtocol.self]
        let host = self.host
        T3StubRegistry.shared.register(host: host, handler)
        transport = T3McpTransport(
            baseURL: URL(string: "http://\(host):3773")!,
            token: { "secret-token" },
            session: URLSession(configuration: configuration),
            clientVersion: "1.2.3",
            requestTimeout: requestTimeout)
    }

    var requests: [T3CapturedRequest] { T3StubRegistry.shared.requests(host: host) }
    var stopCount: Int { T3StubRegistry.shared.stopCount(host: host) }
}

func t3Result(_ result: JSONValue, id: Int = 1) -> JSONValue {
    ["jsonrpc": "2.0", "id": .number(Double(id)), "result": result]
}

func t3RPCError(code: Int, message: String) -> JSONValue {
    ["jsonrpc": "2.0", "id": 1, "error": ["code": .number(Double(code)), "message": .string(message)]]
}

/// Awaits `operation`, returning the error it throws (nil on success).
func t3CaughtError(_ operation: () async throws -> Void) async -> (any Error)? {
    do { try await operation(); return nil } catch { return error }
}

// MARK: - Request tests

@Suite("T3 MCP transport")
struct T3McpTransportTests {
    @Test("tools/call sends the exact 2026-07-28 headers and _meta")
    func headersAndMeta() async throws {
        let stub = T3StubbedTransport { _ in .json(t3Result(["content": []])) }
        let result = try await stub.transport.request(
            method: "tools/call", name: "t3_thread_read",
            params: ["name": "t3_thread_read", "arguments": ["threadId": "t1", "limit": 5]])
        #expect(result == ["content": []])

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.url?.path == "/mcp")
        #expect(request.headers["authorization"] == "Bearer secret-token")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.headers["accept"] == "application/json, text/event-stream")
        #expect(request.headers["mcp-protocol-version"] == "2026-07-28")
        #expect(request.headers["mcp-method"] == "tools/call")
        #expect(request.headers["mcp-name"] == "t3_thread_read")

        let body = try #require(request.json)
        #expect(body["jsonrpc"] == "2.0")
        #expect(body["method"] == "tools/call")
        #expect(body["id"]?.intValue != nil)
        let params = try #require(body["params"])
        #expect(params["name"] == "t3_thread_read")
        #expect(params["arguments"] == ["threadId": "t1", "limit": 5])
        let meta: JSONValue = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": ["name": "focus-queue", "version": "1.2.3"],
            "io.modelcontextprotocol/clientCapabilities": [:],
        ]
        #expect(params["_meta"] == meta)
    }

    @Test("mcp-name is omitted when name is nil, and request ids increase")
    func noNameHeader() async throws {
        let stub = T3StubbedTransport { _ in .json(t3Result([:])) }
        _ = try await stub.transport.request(method: "server/discover", name: nil, params: [:])
        _ = try await stub.transport.request(method: "server/discover", name: nil, params: [:])
        let requests = stub.requests
        #expect(requests.count == 2)
        #expect(requests[0].headers["mcp-name"] == nil)
        #expect(requests[0].headers["mcp-method"] == "server/discover")
        let first = try #require(requests[0].json?["id"]?.intValue)
        let second = try #require(requests[1].json?["id"]?.intValue)
        #expect(second > first)
    }

    @Test("An SSE response yields the last data message that carries an id")
    func sseResponse() async throws {
        let body = """
            : keepalive\r
            event: message\r
            data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}\r
            \r
            event: message\r
            data: {"jsonrpc":"2.0","id":1,\r
            data:  "result":{"first":true}}\r
            \r
            data: {"jsonrpc":"2.0","id":1,"result":{"value":42}}\r
            \r
            data: {"jsonrpc":"2.0","method":"notifications/message","params":{}}\r
            \r

            """
        let stub = T3StubbedTransport { _ in .body(body, status: 200, contentType: "text/event-stream; charset=utf-8") }
        let result = try await stub.transport.request(method: "tools/call", name: "t3_thread_list", params: [:])
        #expect(result == ["value": 42])
    }

    @Test("Connection refused is notRunning", arguments: [
        URLError.Code.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed,
    ])
    func refused(code: URLError.Code) async {
        let stub = T3StubbedTransport { _ in .fail(code) }
        let error = await t3CaughtError { _ = try await stub.transport.request(method: "tools/call", name: "x", params: [:]) }
        #expect(error as? T3Error == .notRunning)
    }

    @Test("Timeout or connection loss after send is outcomeUnknown", arguments: [
        URLError.Code.timedOut, .networkConnectionLost, .badServerResponse,
    ])
    func lostAfterSend(code: URLError.Code) async {
        let stub = T3StubbedTransport { _ in .fail(code) }
        let error = await t3CaughtError { _ = try await stub.transport.request(method: "tools/call", name: "x", params: [:]) }
        #expect((error as? T3Error)?.isOutcomeUnknown == true)
    }

    @Test("A server that stops answering times out as outcomeUnknown")
    func realTimeout() async {
        let stub = T3StubbedTransport(requestTimeout: 0.5) { _ in .hang }
        let error = await t3CaughtError { _ = try await stub.transport.request(method: "tools/call", name: "x", params: [:]) }
        #expect((error as? T3Error)?.isOutcomeUnknown == true)
    }

    @Test("HTTP status classification", arguments: [
        (503, T3Error.outcomeUnknown("HTTP 503")),
        (500, T3Error.outcomeUnknown("HTTP 500")),
        (401, T3Error.unauthorized),
        (403, T3Error.unauthorized),
        (404, T3Error.rejected(code: "http_404", message: "no such route")),
    ])
    func httpStatus(status: Int, expected: T3Error) async {
        let stub = T3StubbedTransport { _ in .body("no such route", status: status) }
        let error = await t3CaughtError { _ = try await stub.transport.request(method: "tools/call", name: "x", params: [:]) }
        #expect(error as? T3Error == expected)
    }

    @Test("-32601 on events/* is serverTooOld")
    func eventsTooOld() async {
        let stub = T3StubbedTransport { _ in .json(t3RPCError(code: -32601, message: "Method not found")) }
        let error = await t3CaughtError { _ = try await stub.transport.request(method: "events/list", name: nil, params: [:]) }
        #expect(error as? T3Error == .serverTooOld(nil))
    }

    @Test("Other JSON-RPC errors are rejected with the code and message")
    func otherRPCError() async {
        let stub = T3StubbedTransport { _ in .json(t3RPCError(code: -32601, message: "Method not found")) }
        let error = await t3CaughtError { _ = try await stub.transport.request(method: "tools/call", name: "x", params: [:]) }
        #expect(error as? T3Error == .rejected(code: "-32601", message: "Method not found"))

        let other = T3StubbedTransport { _ in .json(t3RPCError(code: -32602, message: "Invalid params")) }
        let error2 = await t3CaughtError { _ = try await other.transport.request(method: "events/list", name: nil, params: [:]) }
        #expect(error2 as? T3Error == .rejected(code: "-32602", message: "Invalid params"))
    }

    @Test("A non-JSON body is invalidResponse")
    func garbage() async {
        let stub = T3StubbedTransport { _ in .body("<html>", status: 200, contentType: "text/html") }
        let error = await t3CaughtError { _ = try await stub.transport.request(method: "tools/call", name: "x", params: [:]) }
        guard case .invalidResponse = error as? T3Error else {
            Issue.record("expected invalidResponse, got \(String(describing: error))"); return
        }
    }

    @Test("Token provider errors propagate unchanged and send nothing")
    func tokenFailure() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T3StubURLProtocol.self]
        let host = "t3-\(UUID().uuidString.lowercased()).test"
        T3StubRegistry.shared.register(host: host) { _ in .json(t3Result([:])) }
        let transport = T3McpTransport(
            baseURL: URL(string: "http://\(host)")!, token: { throw T3Error.unauthorized },
            session: URLSession(configuration: configuration))
        let error = await t3CaughtError { _ = try await transport.request(method: "tools/call", name: "x", params: [:]) }
        #expect(error as? T3Error == .unauthorized)
        #expect(T3StubRegistry.shared.requests(host: host).isEmpty)
    }

    @Test("cancelAll makes a pending request throw CancellationError within 1 s")
    func cancelAllRequest() async throws {
        let stub = T3StubbedTransport { _ in .hang }
        let transport = stub.transport
        let pending = Task { try await transport.request(method: "tools/call", name: "t3_thread_wait", params: [:]) }
        #expect(await eventually { stub.requests.count == 1 })
        let start = Date()
        await transport.cancelAll()
        let error = await t3CaughtError { _ = try await pending.value }
        #expect(error is CancellationError)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test("Cancelling the calling task cancels the request")
    func callerCancellation() async throws {
        let stub = T3StubbedTransport { _ in .hang }
        let transport = stub.transport
        let pending = Task { try await transport.request(method: "tools/call", name: "x", params: [:]) }
        #expect(await eventually { stub.requests.count == 1 })
        pending.cancel()
        let error = await t3CaughtError { _ = try await pending.value }
        #expect(error is CancellationError)
        #expect(await eventually { stub.stopCount == 1 })
    }
}
