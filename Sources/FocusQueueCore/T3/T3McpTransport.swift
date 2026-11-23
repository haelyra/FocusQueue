import Foundation

/// MCP revision 2026-07-28 (stateless) over HTTP: one POST to `<base>/mcp` per request,
/// with JSON or SSE responses, plus SEP-3415 `events/stream` subscriptions.
public actor T3McpTransport: T3MCPTransporting {
    public nonisolated let baseURL: URL
    nonisolated let token: @Sendable () async throws -> String
    nonisolated let session: URLSession
    public nonisolated let clientVersion: String
    public nonisolated let requestTimeout: TimeInterval

    private var nextRequestId = 0
    private var nextTaskKey = 0
    private var inFlight: [Int: @Sendable () -> Void] = [:]

    public init(
        baseURL: URL,
        token: @escaping @Sendable () async throws -> String,
        session: URLSession = .shared,
        clientVersion: String = "dev",
        requestTimeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.clientVersion = clientVersion
        self.requestTimeout = requestTimeout
    }

    // MARK: - Requests

    public func request(method: String, name: String?, params: [String: JSONValue]) async throws -> JSONValue {
        let id = makeRequestId()
        let task = Task { try await self.perform(id: id, method: method, name: name, params: params) }
        let key = track { task.cancel() }
        defer { untrack(key) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Streams

    public func stream(name: String, arguments: JSONValue, heartbeatMs: Int) async -> AsyncThrowingStream<T3StreamMessage, any Error> {
        let id = makeRequestId()
        let (stream, continuation) = AsyncThrowingStream<T3StreamMessage, any Error>.makeStream()
        let task = Task {
            await self.runStream(id: id, name: name, arguments: arguments, heartbeatMs: heartbeatMs, into: continuation)
        }
        let key = track { task.cancel() }
        continuation.onTermination = { _ in
            task.cancel()
            Task { await self.untrack(key) }
        }
        return stream
    }

    public func cancelAll() async {
        let cancels = inFlight.values
        inFlight.removeAll()
        for cancel in cancels { cancel() }
    }

    // MARK: - Bookkeeping

    private func makeRequestId() -> Int {
        nextRequestId += 1
        return nextRequestId
    }

    private func track(_ cancel: @escaping @Sendable () -> Void) -> Int {
        nextTaskKey += 1
        inFlight[nextTaskKey] = cancel
        return nextTaskKey
    }

    private func untrack(_ key: Int) {
        inFlight[key] = nil
    }

    // MARK: - Work (off the actor)

    nonisolated func makeURLRequest(
        id: Int, method: String, name: String?, params: [String: JSONValue], timeout: TimeInterval
    ) async throws -> URLRequest {
        let bearer = try await token()
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent("mcp"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "accept")
        request.setValue(T3Defaults.protocolVersion, forHTTPHeaderField: "mcp-protocol-version")
        request.setValue(method, forHTTPHeaderField: "mcp-method")
        if let name { request.setValue(name, forHTTPHeaderField: "mcp-name") }
        request.httpBody = try Self.body(id: id, method: method, params: params, clientVersion: clientVersion).data()
        return request
    }

    static func body(id: Int, method: String, params: [String: JSONValue], clientVersion: String) -> JSONValue {
        var meta = params["_meta"]?.objectValue ?? [:]
        meta["io.modelcontextprotocol/protocolVersion"] = .string(T3Defaults.protocolVersion)
        meta["io.modelcontextprotocol/clientInfo"] = ["name": "focus-queue", "version": .string(clientVersion)]
        meta["io.modelcontextprotocol/clientCapabilities"] = .object([:])
        var fullParams = params
        fullParams["_meta"] = .object(meta)
        return [
            "jsonrpc": "2.0",
            "id": .number(Double(id)),
            "method": .string(method),
            "params": .object(fullParams),
        ]
    }

    nonisolated func perform(id: Int, method: String, name: String?, params: [String: JSONValue]) async throws -> JSONValue {
        do {
            let request = try await makeURLRequest(id: id, method: method, name: name, params: params, timeout: requestTimeout)
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            let http = try Self.httpResponse(response)
            try Self.checkStatus(http, body: data)
            let message = try Self.responseMessage(data: data, contentType: http.value(forHTTPHeaderField: "content-type"))
            return try Self.result(of: message, method: method)
        } catch {
            throw Self.classify(error)
        }
    }

    nonisolated func runStream(
        id: Int, name: String, arguments: JSONValue, heartbeatMs: Int,
        into continuation: AsyncThrowingStream<T3StreamMessage, any Error>.Continuation
    ) async {
        let method = "events/stream"
        let params: [String: JSONValue] = ["name": .string(name), "arguments": arguments, "heartbeatMs": .number(Double(heartbeatMs))]
        // URLRequest's timeout is an idle timeout; heartbeats keep a healthy stream busy.
        let idle = max(requestTimeout, Double(heartbeatMs) / 1000 * 3)
        do {
            let request = try await makeURLRequest(id: id, method: method, name: name, params: params, timeout: idle)
            let (bytes, response) = try await session.bytes(for: request)
            let http = try Self.httpResponse(response)
            let contentType = http.value(forHTTPHeaderField: "content-type")
            guard (200..<300).contains(http.statusCode), Self.isEventStream(contentType) else {
                let body = try await Self.collect(bytes, limit: 1 << 20)
                try Self.checkStatus(http, body: body)
                // A plain JSON answer is a JSON-RPC response, typically an error.
                _ = try Self.result(of: Self.responseMessage(data: body, contentType: contentType), method: method)
                continuation.finish()
                return
            }
            var parser = T3SSEParser()
            for try await byte in bytes {
                guard let sse = parser.feed(byte: byte) else { continue }
                if try Self.deliver(sse, method: method, to: continuation) { return }
            }
            try Task.checkCancellation()
            if let sse = parser.finish(), try Self.deliver(sse, method: method, to: continuation) { return }
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.classify(error))
        }
    }

    /// Yields one SSE message. Returns true when the stream is over.
    static func deliver(
        _ sse: T3SSEMessage, method: String,
        to continuation: AsyncThrowingStream<T3StreamMessage, any Error>.Continuation
    ) throws -> Bool {
        switch T3StreamDecoder.decode(sse) {
        case .ignored:
            return false
        case .message(let message):
            continuation.yield(message)
            guard message == .terminated else { return false }
            continuation.finish()
            return true
        case .response(let response):
            _ = try result(of: response, method: method)
            continuation.finish()
            return true
        }
    }

    // MARK: - Response handling

    static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw T3Error.invalidResponse("not an HTTP response") }
        return http
    }

    static func checkStatus(_ http: HTTPURLResponse, body: Data) throws {
        let status = http.statusCode
        switch status {
        case 200..<300: return
        case 401, 403: throw T3Error.unauthorized
        case 500..<600: throw T3Error.outcomeUnknown("HTTP \(status)")
        default: throw T3Error.rejected(code: "http_\(status)", message: snippet(body))
        }
    }

    static func snippet(_ body: Data) -> String {
        String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isEventStream(_ contentType: String?) -> Bool {
        contentType?.lowercased().contains("text/event-stream") ?? false
    }

    /// The JSON-RPC response object: the JSON body, or the last SSE `data:` message carrying an `id`.
    static func responseMessage(data: Data, contentType: String?) throws -> JSONValue {
        if isEventStream(contentType) {
            let responses = T3SSEParser.parse(data).compactMap { sse -> JSONValue? in
                guard let json = try? JSONValue.parse(Data(sse.data.utf8)), let id = json["id"], !id.isNull else { return nil }
                return json
            }
            guard let last = responses.last else { throw T3Error.invalidResponse("SSE body has no JSON-RPC response") }
            return last
        }
        do { return try JSONValue.parse(data) } catch {
            throw T3Error.invalidResponse("body is not JSON: \(snippet(data))")
        }
    }

    static func result(of message: JSONValue, method: String) throws -> JSONValue {
        if let error = message["error"], !error.isNull {
            let code = error["code"]?.intValue ?? 0
            let text = error["message"]?.stringValue ?? "JSON-RPC error \(code)"
            if code == -32601, method.hasPrefix("events/") { throw T3Error.serverTooOld(nil) }
            throw T3Error.rejected(code: String(code), message: text)
        }
        guard let result = message["result"] else { throw T3Error.invalidResponse("JSON-RPC response has no result") }
        return result
    }

    static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    /// Maps transport failures onto `T3Error`. Cancellation stays `CancellationError`.
    static func classify(_ error: any Error) -> any Error {
        if error is CancellationError || error is T3Error { return error }
        if Task.isCancelled { return CancellationError() }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed:
            return T3Error.notRunning
        case .timedOut:
            return T3Error.outcomeUnknown("timed out")
        case .networkConnectionLost:
            return T3Error.outcomeUnknown("connection lost")
        case .badServerResponse:
            return T3Error.outcomeUnknown("bad server response")
        default:
            // The request may have been written; never assume it had no effect.
            return T3Error.outcomeUnknown(urlError.localizedDescription)
        }
    }
}

// MARK: - SSE

/// One dispatched server-sent event.
struct T3SSEMessage: Equatable, Sendable {
    var event: String?
    var data: String
    var id: String?
}

/// Incremental `text/event-stream` parser (WHATWG rules): CR, LF and CRLF line ends, multi-line
/// `data:`, `:` comments, and input split anywhere, including inside a CRLF pair.
struct T3SSEParser: Sendable {
    private var line: [UInt8] = []
    private var afterCR = false
    private var atStart = true
    private var event: String?
    private var dataLines: [String] = []
    private var hasData = false
    private var id: String?

    init() {}

    /// Feeds one byte. Returns a message when a blank line completes one.
    mutating func feed(byte: UInt8) -> T3SSEMessage? {
        switch byte {
        case 0x0A:
            if afterCR { afterCR = false; return nil }
            return endLine()
        case 0x0D:
            afterCR = true
            return endLine()
        default:
            afterCR = false
            line.append(byte)
            return nil
        }
    }

    mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [T3SSEMessage] where Bytes.Element == UInt8 {
        var messages: [T3SSEMessage] = []
        for byte in bytes { if let message = feed(byte: byte) { messages.append(message) } }
        return messages
    }

    mutating func feed(_ text: String) -> [T3SSEMessage] { feed(Array(text.utf8)) }

    /// Ends input, dispatching a final message that lacked its trailing blank line.
    mutating func finish() -> T3SSEMessage? {
        if !line.isEmpty { _ = endLine() }
        return dispatch()
    }

    static func parse(_ data: Data) -> [T3SSEMessage] {
        var parser = T3SSEParser()
        var messages = parser.feed(data)
        if let last = parser.finish() { messages.append(last) }
        return messages
    }

    private mutating func endLine() -> T3SSEMessage? {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if atStart {
            atStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        guard !bytes.isEmpty else { return dispatch() }
        let text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "data": dataLines.append(String(value)); hasData = true
        case "event": event = String(value)
        case "id": if !value.contains("\0") { id = String(value) }
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> T3SSEMessage? {
        defer { event = nil; dataLines.removeAll(); hasData = false; id = nil }
        guard hasData else { return nil }
        return T3SSEMessage(event: event, data: dataLines.joined(separator: "\n"), id: id)
    }
}

/// Turns SSE `data:` JSON into `T3StreamMessage`s.
enum T3StreamDecoder {
    enum Decoded: Equatable, Sendable {
        case message(T3StreamMessage)
        /// A JSON-RPC response (has an `id`): the stream request itself finished or failed.
        case response(JSONValue)
        case ignored
    }

    static func decode(_ sse: T3SSEMessage) -> Decoded {
        guard let json = try? JSONValue.parse(Data(sse.data.utf8)), json.objectValue != nil else { return .ignored }
        if let id = json["id"], !id.isNull, json["method"] == nil { return .response(json) }
        guard let method = json["method"]?.stringValue else { return .ignored }
        guard let message = message(method: method, params: json["params"] ?? .object([:])) else { return .ignored }
        return .message(message)
    }

    static func message(method: String, params: JSONValue) -> T3StreamMessage? {
        switch method {
        case "notifications/events/active":
            guard let cursor = params["cursor"]?.stringValue else { return nil }
            return .active(cursor: cursor, truncated: params["truncated"]?.boolValue ?? false, heartbeatMs: params["heartbeatMs"]?.intValue)
        case "notifications/events/event":
            return event(params).map(T3StreamMessage.event)
        case "notifications/events/heartbeat":
            guard let cursor = params["cursor"]?.stringValue else { return nil }
            return .heartbeat(cursor: cursor)
        case "notifications/events/error":
            return .error(errorText(params))
        case "notifications/events/terminated":
            return .terminated
        default:
            return nil
        }
    }

    private static func event(_ params: JSONValue) -> T3EventOccurrence? {
        guard let eventId = scalarString(params["eventId"]),
              let name = params["name"]?.stringValue,
              let cursor = params["cursor"]?.stringValue else { return nil }
        return T3EventOccurrence(
            eventId: eventId, name: name, timestamp: params["timestamp"]?.stringValue,
            cursor: cursor, data: params["data"] ?? .null)
    }

    private static func scalarString(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text): text
        case .number(let number): number.rounded() == number ? String(Int64(number)) : String(number)
        default: nil
        }
    }

    private static func errorText(_ params: JSONValue) -> String {
        if let text = params["message"]?.stringValue { return text }
        if let text = params["error"]?["message"]?.stringValue { return text }
        if let text = params["error"]?.stringValue { return text }
        if let data = try? params.data() { return String(decoding: data, as: UTF8.self) }
        return "event stream error"
    }
}
