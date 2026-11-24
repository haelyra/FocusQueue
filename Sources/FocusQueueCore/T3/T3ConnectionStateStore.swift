import Foundation

/// Loads and saves `t3-connection.json` in the support directory. Never holds the token.
public struct T3ConnectionStateStore: Sendable {
    public static let fileName = "t3-connection.json"
    public let url: URL
    private let files: any FileAccessing

    public init(supportDirectory: URL, files: any FileAccessing = SystemFileAccessor()) {
        self.url = supportDirectory.appendingPathComponent(Self.fileName)
        self.files = files
    }

    public func load() throws -> T3ConnectionState? {
        try FocusQueueFileLock.withLocks(for: [url]) {
            guard files.fileExists(at: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T3ConnectionState.self, from: files.read(from: url))
        }
    }

    public func save(_ state: T3ConnectionState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try FocusQueueFileLock.withLocks(for: [url]) { try files.write(data, to: url) }
    }

    /// Reads, changes, and writes the state under one lock.
    @discardableResult
    public func update(serverURL: String, _ change: (inout T3ConnectionState) -> Void) throws -> T3ConnectionState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try FocusQueueFileLock.withLocks(for: [url]) {
            var state = files.fileExists(at: url)
                ? try decoder.decode(T3ConnectionState.self, from: files.read(from: url))
                : T3ConnectionState(serverURL: serverURL)
            change(&state)
            try files.write(encoder.encode(state), to: url)
            return state
        }
    }
}
