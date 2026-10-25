import Foundation

/// Provider-reported token counts split by how the provider processed them.
public struct TokenBreakdown: Sendable, Equatable {
    public var uncachedInput = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var output = 0

    public init(uncachedInput: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0) {
        self.uncachedInput = uncachedInput; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.output = output
    }

    public var input: Int { uncachedInput + cacheRead + cacheWrite }
    public var total: Int { input + output }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(uncachedInput: lhs.uncachedInput + rhs.uncachedInput, cacheRead: lhs.cacheRead + rhs.cacheRead,
             cacheWrite: lhs.cacheWrite + rhs.cacheWrite, output: lhs.output + rhs.output)
    }
}

/// One agent's actual usage, read from the provider's local transcript.
public struct AgentSessionUsage: Sendable, Identifiable {
    public let id: String
    public let ticketID: String
    public let provider: String
    public let label: String
    public let turns: Int
    /// Context the provider processed on the first model turn: system prompt,
    /// tools, instruction files, and the launch prompt.
    public let firstContext: Int
    public let peakContext: Int
    public let contextWindow: Int
    public let totals: TokenBreakdown
    /// Keyed by local calendar day (`yyyy-MM-dd`). Includes subagent transcripts.
    public let daily: [String: TokenBreakdown]

    public init(id: String, ticketID: String, provider: String, label: String, turns: Int,
                firstContext: Int, peakContext: Int, contextWindow: Int, totals: TokenBreakdown,
                daily: [String: TokenBreakdown]) {
        self.id = id; self.ticketID = ticketID; self.provider = provider; self.label = label
        self.turns = turns; self.firstContext = firstContext; self.peakContext = peakContext
        self.contextWindow = contextWindow; self.totals = totals; self.daily = daily
    }
}

/// Reads token usage that Claude Code and Codex already write to their local
/// session transcripts. It never calls a model.
public enum AgentTranscriptUsage {
    public struct Session: Sendable {
        public let ticketID, provider, sessionID, label: String
        public init(ticketID: String, provider: String, sessionID: String, label: String) {
            self.ticketID = ticketID; self.provider = provider; self.sessionID = sessionID; self.label = label
        }
    }

    struct FileUsage: Sendable {
        var turns = 0, firstContext = 0, peakContext = 0, contextWindow = 0
        var totals = TokenBreakdown()
        var daily: [String: TokenBreakdown] = [:]
    }

    private struct CacheKey: Hashable { let path: String; let size: Int; let modified: Date }
    nonisolated(unsafe) private static var cache: [String: (CacheKey, FileUsage)] = [:]
    private static let cacheLock = NSLock()

    public static func scan(_ sessions: [Session], home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [AgentSessionUsage] {
        let codexFiles = codexTranscripts(home: home)
        var seen = Set<String>()
        return sessions.compactMap { session in
            let sessionID = session.sessionID.lowercased()
            guard seen.insert(sessionID).inserted else { return nil }
            let files: [URL]
            switch session.provider {
            case "claude": files = claudeTranscripts(sessionID: sessionID, home: home)
            case "codex": files = codexFiles[sessionID].map { [$0] } ?? []
            default: files = []
            }
            guard let main = files.first, let primary = usage(of: main, provider: session.provider) else {
                return nil
            }
            var totals = primary.totals
            var daily = primary.daily
            for extra in files.dropFirst() {
                guard let usage = usage(of: extra, provider: session.provider) else { continue }
                totals = totals + usage.totals
                daily.merge(usage.daily, uniquingKeysWith: +)
            }
            let window = primary.contextWindow > 0 ? primary.contextWindow
                : (primary.peakContext > 200_000 ? 1_000_000 : 200_000)
            return AgentSessionUsage(id: sessionID, ticketID: session.ticketID, provider: session.provider,
                                     label: session.label, turns: primary.turns,
                                     firstContext: primary.firstContext, peakContext: primary.peakContext,
                                     contextWindow: window, totals: totals, daily: daily)
        }
    }

    /// Claude stores `<project>/<session>.jsonl` plus `<project>/<session>/subagents/*.jsonl`.
    static func claudeTranscripts(sessionID: String, home: URL) -> [URL] {
        let root = home.appendingPathComponent(".claude/projects")
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }
        for project in projects {
            let folder = root.appendingPathComponent(project)
            let main = folder.appendingPathComponent("\(sessionID).jsonl")
            guard manager.fileExists(atPath: main.path) else { continue }
            let subagents = folder.appendingPathComponent("\(sessionID)/subagents")
            let extras = ((try? manager.contentsOfDirectory(atPath: subagents.path)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }.sorted()
                .map { subagents.appendingPathComponent($0) }
            return [main] + extras
        }
        return []
    }

    /// Codex names rollouts `rollout-<timestamp>-<session uuid>.jsonl`.
    static func codexTranscripts(home: URL) -> [String: URL] {
        var files: [String: URL] = [:]
        for folder in [".codex/sessions", ".codex/archived_sessions"] {
            let root = home.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let name = url.deletingPathExtension().lastPathComponent
                guard name.count >= 36 else { continue }
                files[String(name.suffix(36)).lowercased()] = url
            }
        }
        return files
    }

    static func usage(of url: URL, provider: String) -> FileUsage? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let key = CacheKey(path: url.path, size: size, modified: modified)
        cacheLock.lock()
        let cached = cache[url.path]
        cacheLock.unlock()
        if let cached, cached.0 == key { return cached.1 }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let parsed = provider == "claude" ? parseClaude(data) : parseCodex(data)
        cacheLock.lock()
        cache[url.path] = (key, parsed)
        cacheLock.unlock()
        return parsed
    }

    /// Claude writes one line per content block, each repeating the message's
    /// usage, so a message counts once by its ID. Lines can carry large tool
    /// output, so only the `usage` object, message ID, and timestamp are decoded.
    static func parseClaude(_ data: Data) -> FileUsage {
        var result = FileUsage()
        var messages = Set<String>()
        forEachLine(in: data, containing: Array(#""usage":{"#.utf8)) { line in
            guard let usage = jsonObject(after: #""usage":"#, in: line),
                  let output = usage["output_tokens"] as? Int else { return }
            if let id = stringValue(after: #""id":"msg_"#, in: line), !messages.insert(id).inserted { return }
            let tokens = TokenBreakdown(uncachedInput: usage["input_tokens"] as? Int ?? 0,
                                        cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                                        cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                                        output: output)
            record(tokens, context: tokens.input,
                   timestamp: stringValue(after: #""timestamp":""#, in: line), into: &result)
        }
        return result
    }

    /// Codex repeats `token_count` events; only a change in the running total is a new turn.
    static func parseCodex(_ data: Data) -> FileUsage {
        var result = FileUsage()
        var previousTotal: [String: Any]?
        forEachLine(in: data, containing: Array(#""token_count""#.utf8)) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { return }
            if let previousTotal, NSDictionary(dictionary: previousTotal).isEqual(to: total) { return }
            previousTotal = total
            let input = last["input_tokens"] as? Int ?? 0
            let cached = last["cached_input_tokens"] as? Int ?? 0
            let tokens = TokenBreakdown(uncachedInput: max(0, input - cached), cacheRead: cached,
                                        cacheWrite: last["cache_write_input_tokens"] as? Int ?? 0,
                                        output: last["output_tokens"] as? Int ?? 0)
            if let window = info["model_context_window"] as? Int { result.contextWindow = window }
            record(tokens, context: input, timestamp: object["timestamp"] as? String, into: &result)
        }
        return result
    }

    private static func record(_ tokens: TokenBreakdown, context: Int, timestamp: String?,
                               into result: inout FileUsage) {
        result.turns += 1
        if result.firstContext == 0 { result.firstContext = context }
        result.peakContext = max(result.peakContext, context)
        result.totals = result.totals + tokens
        let day = timestamp.flatMap(parseTimestamp).map(TokenUsageDay.key) ?? "unknown"
        result.daily[day, default: TokenBreakdown()] = result.daily[day, default: TokenBreakdown()] + tokens
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Calls `body` with each line holding `needle`, which keeps large transcripts cheap to scan.
    private static func forEachLine(in data: Data, containing needle: [UInt8], _ body: (Data) -> Void) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = buffer.count
            var start = 0
            while start < count {
                let newline = memchr(base + start, 0x0A, count - start)
                let end = newline.map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) - base } ?? count
                let length = end - start
                if length > needle.count, memmem(base + start, length, needle, needle.count) != nil {
                    body(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: length,
                              deallocator: .none))
                }
                start = end + 1
            }
        }
    }

    /// Decodes the flat JSON object that follows the first `key` in `line`.
    static func jsonObject(after key: String, in line: Data) -> [String: Any]? {
        guard let range = line.range(of: Data(key.utf8)) else { return nil }
        var depth = 0
        var inString = false, escaped = false
        var index = range.upperBound
        guard index < line.endIndex, line[index] == UInt8(ascii: "{") else { return nil }
        let start = index
        while index < line.endIndex {
            let byte = line[index]
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    return try? JSONSerialization.jsonObject(with: line[start...index]) as? [String: Any]
                }
            }
            index += 1
        }
        return nil
    }

    /// The string value that starts right after `prefix`, ending at the next quote.
    static func stringValue(after prefix: String, in line: Data) -> String? {
        guard let range = line.range(of: Data(prefix.utf8)),
              let end = line[range.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: line[range.upperBound..<end], as: UTF8.self)
    }
}

/// Local calendar days, so "today" matches the user's clock rather than UTC.
public enum TokenUsageDay {
    public static func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The last `count` day keys, oldest first, ending today.
    public static func recent(_ count: Int, now: Date = Date()) -> [String] {
        (0..<count).reversed().compactMap { offset in
            Calendar.current.date(byAdding: .day, value: -offset, to: now).map(key)
        }
    }
}
