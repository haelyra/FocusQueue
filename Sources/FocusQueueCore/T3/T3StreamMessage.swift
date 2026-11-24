import Foundation

/// One `events/stream` notification (SEP-3415).
public enum T3StreamMessage: Equatable, Sendable {
    /// `notifications/events/active`: the subscription is live from `cursor`.
    case active(cursor: String, truncated: Bool, heartbeatMs: Int?)
    case event(T3EventOccurrence)
    case heartbeat(cursor: String)
    case error(String)
    case terminated
}

public struct T3EventOccurrence: Equatable, Sendable {
    public var eventId: String
    public var name: String
    public var timestamp: String?
    public var cursor: String
    public var data: JSONValue
    public init(eventId: String, name: String, timestamp: String?, cursor: String, data: JSONValue) {
        self.eventId = eventId; self.name = name; self.timestamp = timestamp; self.cursor = cursor; self.data = data
    }
    public var threadId: String? { data["threadId"]?.stringValue }
}

/// Event cursors are one global `<epoch>.<n>` sequence. A new epoch means the server's buffer restarted.
public struct T3Cursor: Equatable, Sendable {
    public var epoch: String
    public var sequence: Int
    public init?(_ raw: String) {
        guard let dot = raw.lastIndex(of: "."), let sequence = Int(raw[raw.index(after: dot)...]) else { return nil }
        let epoch = String(raw[..<dot])
        guard !epoch.isEmpty else { return nil }
        self.epoch = epoch; self.sequence = sequence
    }
}

public enum T3EventName {
    public static let runSettled = "thread.run_settled"
    public static let needsInput = "thread.needs_input"
    public static let inputResolved = "thread.input_resolved"
    public static let watched = [runSettled, needsInput, inputResolved]
}

/// MCP 2026-07-28 requests and event streams. `T3McpTransport` conforms; tests use fakes.
public protocol T3MCPTransporting: Sendable {
    /// One JSON-RPC request. Returns the `result` value. `params` gets `_meta` added by the transport.
    func request(method: String, name: String?, params: [String: JSONValue]) async throws -> JSONValue
    /// An `events/stream` subscription. Cancelling the consuming task closes it.
    func stream(name: String, arguments: JSONValue, heartbeatMs: Int) async -> AsyncThrowingStream<T3StreamMessage, any Error>
    /// Aborts every in-flight request and stream.
    func cancelAll() async
}
