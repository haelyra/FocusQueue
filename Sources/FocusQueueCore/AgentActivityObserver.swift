import Foundation

/// Observes structured events for an already registered conversation. Never guesses identity
/// from a transcript, treats prose as approval, or marks the assignment complete from a reply.
public struct AgentActivityEvent: Sendable, Equatable {
    /// `prompt` is a person's message to the agent: working activity that also
    /// counts as the task's latest interaction.
    public enum Kind: Sendable, Equatable { case working, prompt, result, attention(AgentAttention) }
    /// Transcripts are read after the fact; provider hooks report each turn edge as it happens.
    public enum Source: Sendable, Equatable { case transcript, hook }
    public let id: String
    public let date: Date
    public let kind: Kind
    public let summary: String
    public let source: Source

    public init(id: String, date: Date, kind: Kind, summary: String, source: Source = .transcript) {
        self.id = id; self.date = date; self.kind = kind; self.summary = summary; self.source = source
    }

    private static let quotaMarkers = [
        "rate limit", "usage limit", "quota", "insufficient credits",
        "credit balance", "429", "plan limit", "you've hit your limit",
    ]

    public static func isQuotaError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return quotaMarkers.contains { lowered.contains($0) }
    }

    public static func latest(in data: Data, provider: AgentProvider, sessionID: String) -> Self? {
        events(in: data, provider: provider, sessionID: sessionID).last
    }

    public static func events(in data: Data, provider: AgentProvider, sessionID: String) -> [Self] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var events: [(offset: Int, event: Self)] = []
        // Kimi names a turn's reply only in its earlier assistant message records.
        var kimiReply = ""
        for (offset, line) in data.split(separator: 10).enumerated() {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let timestamp: String
            let date: Date
            if let value = record["timestamp"] as? String,
               let parsed = fractional.date(from: value) ?? plain.date(from: value) {
                timestamp = value; date = parsed
            } else if provider == .kimi, let milliseconds = record["time"] as? Double {
                timestamp = String(Int64(milliseconds)); date = Date(timeIntervalSince1970: milliseconds / 1_000)
            } else { continue }
            var kind: Kind?
            var summary = ""
            if provider == .kimi {
                (kind, summary) = Self.kimiKind(record, reply: &kimiReply)
            } else if provider == .codex, let payload = record["payload"] as? [String: Any] {
                if let thread = payload["thread_id"] as? String, thread.lowercased() != sessionID.lowercased() { continue }
                let type = payload["type"] as? String
                if record["type"] as? String == "event_msg" {
                    switch type {
                    case "task_started", "turn_started": kind = .working
                    case "user_message": kind = .prompt
                    case "task_complete", "task_completed", "turn_complete", "turn_completed":
                        kind = .result; summary = payload["last_agent_message"] as? String ?? "New agent response"
                    case "turn_aborted": kind = .attention(.interrupted); summary = "The agent turn was interrupted."
                    case "exec_approval_request", "apply_patch_approval_request":
                        kind = .attention(.approval); summary = "The agent is waiting for approval in its terminal."
                    case "request_user_input": kind = .attention(.question); summary = "The agent has a question to answer."
                    case "error":
                        let message = payload["message"] as? String ?? ""
                        kind = Self.isQuotaError(message) ? .attention(.quotaExhausted) : .attention(.failed)
                        summary = message.isEmpty ? "The agent reported a problem." : message
                    default: break
                    }
                } else if record["type"] as? String == "response_item" {
                    if type == "message", payload["role"] as? String == "user", Self.isCodexPrompt(payload) {
                        kind = .prompt
                    } else if type == "message", payload["role"] as? String == "assistant", payload["phase"] as? String == "final_answer" {
                        kind = .result
                        summary = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    } else if ["function_call", "custom_tool_call"].contains(type ?? ""),
                              (payload["name"] as? String)?.contains("request_user_input") == true {
                        kind = .attention(.question); summary = "The agent has a question to answer."
                    } else if Self.codexWorkingItems.contains(type ?? "")
                                || (type == "message" && payload["phase"] as? String == "commentary") {
                        kind = .working
                    }
                }
            } else if provider == .claude {
                guard (record["sessionId"] as? String)?.lowercased() == sessionID.lowercased(),
                      record["isSidechain"] as? Bool != true else { continue }
                let type = record["type"] as? String
                if type == "user" {
                    let message = record["message"] as? [String: Any]
                    let text = message?["content"] as? String
                        ?? (message?["content"] as? [[String: Any]])?.first?["text"] as? String
                    if ["[Request interrupted by user]", "[Request interrupted by user for tool use]"].contains(text ?? "") {
                        kind = .attention(.interrupted); summary = "The agent turn was interrupted."
                    } else if Self.isClaudePrompt(record) {
                        kind = .prompt
                    } else if Self.isClaudeToolResult(record) {
                        kind = .working
                    }
                    // Compaction summaries (including idle compaction), meta notices,
                    // and slash-command echoes are written without a running turn.
                }
                if type == "assistant", let message = record["message"] as? [String: Any] {
                    let content = message["content"] as? [[String: Any]] ?? []
                    if record["isApiErrorMessage"] as? Bool == true {
                        let errorText = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        kind = Self.isQuotaError(errorText) ? .attention(.quotaExhausted) : .attention(.failed)
                    } else if content.contains(where: { $0["name"] as? String == "AskUserQuestion" }) {
                        kind = .attention(.question)
                    } else if message["stop_reason"] as? String == "max_tokens" {
                        kind = .attention(.incomplete)
                    } else if ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? "") {
                        if content.contains(where: { $0["type"] as? String == "text" }) { kind = .result }
                    } else {
                        // Thinking, tool calls, and interim text all arrive mid-turn.
                        kind = .working
                    }
                    // Interim narration is not a status summary; only turn outcomes carry one.
                    summary = kind == .working ? "" : content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if summary.isEmpty, kind == .attention(.question) { summary = "The agent has a question to answer." }
                }
            }
            guard let kind else { continue }
            let eventID = (record["event"] as? [String: Any])?["uuid"] as? String
            let id = (record["uuid"] as? String ?? record["id"] as? String ?? eventID
                ?? "\(record["type"] as? String ?? ""):\(timestamp)") + ":\(kind)"
            let event = Self(id: id, date: date, kind: kind, summary: String(summary.prefix(2_000)))
            events.append((offset, event))
        }
        return events.sorted {
            $0.event.date == $1.event.date ? $0.offset < $1.offset : $0.event.date < $1.event.date
        }.map(\.event)
    }

    /// Codex records written while a turn is running: tool calls, their output, and reasoning.
    private static let codexWorkingItems: Set<String> = [
        "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output", "reasoning",
    ]

    /// Kimi's `agents/main/wire.jsonl`: `turn.prompt` and `turn.ended` bound each
    /// turn, and loop, model, and tool records arrive while it runs.
    private static func kimiKind(_ record: [String: Any], reply: inout String) -> (Kind?, String) {
        switch record["type"] as? String {
        case "turn.prompt":
            let origin = (record["origin"] as? [String: Any])?["kind"] as? String
            reply = ""
            return (origin == "user" ? .prompt : .working, "")
        case "agent.turn.started", "context.append_loop_event", "llm.request", "interaction.resolved":
            return (.working, "")
        case "agent.message.appended":
            let message = (record["message"] as? [String: Any])?["message"] as? [String: Any]
            guard message?["role"] as? String == "assistant" else { return (nil, "") }
            let text = (message?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { reply = text }
            return (.working, "")
        case "interaction.request":
            return record["kind"] as? String == "approval"
                ? (.attention(.approval), "The agent is waiting for approval in its terminal.")
                : (.attention(.question), "The agent has a question to answer.")
        case "turn.ended":
            switch record["reason"] as? String {
            case "completed": return (.result, reply.isEmpty ? "New agent response" : reply)
            case "cancelled": return (.attention(.interrupted), "The agent turn was interrupted.")
            default:
                let message = (record["error"] as? [String: Any])?["message"] as? String ?? ""
                return (Self.isQuotaError(message) ? .attention(.quotaExhausted) : .attention(.failed),
                    message.isEmpty ? "The agent reported a problem." : message)
            }
        default:
            return (nil, "")
        }
    }

    /// Current Codex transcripts tag typed input `user.text`; injected AGENTS.md
    /// and environment context arrive as user-role messages with other kinds.
    private static func isCodexPrompt(_ payload: [String: Any]) -> Bool {
        let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any]
        let kinds = metadata?["content_item_kinds"] as? [String] ?? []
        return kinds.contains { $0.hasPrefix("user.") }
    }

    /// A tool's output, written while the turn that called it is still running.
    private static func isClaudeToolResult(_ record: [String: Any]) -> Bool {
        guard record["isMeta"] as? Bool != true, record["isCompactSummary"] as? Bool != true else { return false }
        if record["toolUseResult"] != nil { return true }
        let content = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.contains { $0["type"] as? String == "tool_result" }
    }

    /// Tool results, compaction summaries, background-task notices, and local
    /// slash-command echoes are user-role records but not a person's prompt.
    private static func isClaudePrompt(_ record: [String: Any]) -> Bool {
        guard record["isMeta"] as? Bool != true, record["isCompactSummary"] as? Bool != true,
              record["toolUseResult"] == nil else { return false }
        if let origin = record["origin"] as? [String: Any] { return origin["kind"] as? String == "human" }
        let message = record["message"] as? [String: Any]
        let text: String?
        if let content = message?["content"] as? [[String: Any]] {
            guard !content.contains(where: { $0["type"] as? String == "tool_result" }) else { return false }
            text = content.first { $0["type"] as? String == "text" }?["text"] as? String
        } else {
            text = message?["content"] as? String
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        return !["<command-", "<local-command", "<task-notification"].contains { text.hasPrefix($0) }
    }
}

public actor AgentActivityObserver {
    private struct Cursor {
        var path: String
        var fileIdentity: String
        var offset: UInt64
        var pending = Data()
        var latest: AgentActivityEvent?
        var continuityProbe = Data()
        var bytesRead = 0
    }

    private let codexRoot: URL
    private let claudeRoot: URL
    private let kimiRoot: URL
    private var locations: [String: URL] = [:]
    private var searchedAt: [String: Date] = [:]
    private var scans: [String: (stamp: String, files: [URL])] = [:]
    private var cursors: [String: Cursor] = [:]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codexRoot = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        claudeRoot = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        kimiRoot = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".kimi-code")
    }

    public init(codexRoot: URL, claudeRoot: URL, kimiRoot: URL? = nil) {
        self.codexRoot = codexRoot
        self.claudeRoot = claudeRoot
        self.kimiRoot = kimiRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
    }

    /// The provider transcript that records this agent's saved conversation.
    public func transcriptURL(for agent: TaskSubtask) -> URL? {
        // Saved Kimi records may hold the bare UUID of a `session_<uuid>` directory.
        guard let sessionID = agent.sessionID,
              UUID(uuidString: sessionID) != nil || agent.provider.isValidSessionID(sessionID) else { return nil }
        let key = agent.provider.rawValue + ":" + sessionID.lowercased()
        let roots = switch agent.provider {
        case .codex: ["sessions", "archived_sessions"].map { codexRoot.appendingPathComponent($0) }
        case .claude: [claudeRoot.appendingPathComponent("projects")]
        case .kimi: [kimiRoot.appendingPathComponent("sessions")]
        }
        if let location = locations[key], !FileManager.default.fileExists(atPath: location.path) {
            locations[key] = nil
            searchedAt[key] = nil
            for root in roots { scans[root.path] = nil }
        }
        if locations[key] == nil, Date().timeIntervalSince(searchedAt[key] ?? .distantPast) >= 60 {
            searchedAt[key] = Date()
            let suffix = (sessionID + ".jsonl").lowercased()
            // A Kimi session is a `session_<id>` directory; its main agent writes `agents/main/wire.jsonl`.
            let kimiDirectories = Set([sessionID, "session_" + sessionID].map { $0.lowercased() })
            for root in roots where locations[key] == nil {
                locations[key] = sessionFiles(root: root).first {
                    agent.provider == .kimi
                        ? $0.path.hasSuffix("/agents/main/wire.jsonl")
                            && kimiDirectories.contains($0.deletingLastPathComponent().deletingLastPathComponent()
                                .deletingLastPathComponent().lastPathComponent.lowercased())
                        : $0.lastPathComponent.lowercased().hasSuffix(suffix)
                }
            }
        }
        return locations[key]
    }

    public func events(for agent: TaskSubtask) throws -> [AgentActivityEvent] {
        guard let sessionID = agent.sessionID, let url = transcriptURL(for: agent) else { return [] }
        let key = agent.provider.rawValue + ":" + sessionID.lowercased()
        let identity = try fileIdentity(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let priorBytesRead = cursors[key]?.bytesRead ?? 0
        let needsReset: Bool
        if let cursor = cursors[key] {
            needsReset = cursor.path != url.path || cursor.fileIdentity != identity
                || end < cursor.offset || !continuityMatches(cursor, in: handle)
        } else {
            needsReset = true
        }
        if needsReset {
            let start = end > 262_144 ? end - 262_144 : 0
            cursors[key] = Cursor(path: url.path, fileIdentity: identity,
                offset: start, bytesRead: priorBytesRead)
        }
        guard var cursor = cursors[key], end > cursor.offset else { return [] }
        var startedInsideFile = needsReset && cursor.offset > 0 && cursor.pending.isEmpty
        if end - cursor.offset > 262_144 {
            cursor.offset = end - 262_144
            cursor.pending.removeAll(keepingCapacity: false)
            startedInsideFile = true
        }
        try handle.seek(toOffset: cursor.offset)
        var appended = try handle.readToEnd() ?? Data()
        cursor.bytesRead += appended.count
        cursor.offset = end
        if startedInsideFile {
            if let newline = appended.firstIndex(of: 10) {
                appended.removeSubrange(appended.startIndex...newline)
            } else {
                appended.removeAll(keepingCapacity: false)
            }
        }
        var available = cursor.pending
        available.append(appended)
        if available.count > 262_144 {
            available = Data(available.suffix(262_144))
            if let newline = available.firstIndex(of: 10) {
                available.removeSubrange(available.startIndex...newline)
            } else {
                available.removeAll(keepingCapacity: false)
            }
        }
        let parsed = parsedPrefix(available, provider: agent.provider, sessionID: sessionID)
        cursor.pending = parsed.pending
        if let event = parsed.events.last,
           event.date >= (cursor.latest?.date ?? .distantPast) {
            cursor.latest = event
        }
        cursor.continuityProbe = try continuityProbe(endingAt: cursor.offset, in: handle)
        cursors[key] = cursor
        return parsed.events
    }

    public func latest(for agent: TaskSubtask) throws -> AgentActivityEvent? {
        _ = try events(for: agent)
        guard let sessionID = agent.sessionID else { return nil }
        return cursors[agent.provider.rawValue + ":" + sessionID.lowercased()]?.latest
    }

    /// Test-visible instrumentation for proving that unchanged transcript bytes
    /// are not reread on every refresh.
    func bytesRead(for agent: TaskSubtask) -> Int {
        guard let sessionID = agent.sessionID else { return 0 }
        return cursors[agent.provider.rawValue + ":" + sessionID.lowercased()]?.bytesRead ?? 0
    }

    private func fileIdentity(at url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
    }

    private func parsedPrefix(
        _ data: Data, provider: AgentProvider, sessionID: String
    ) -> (events: [AgentActivityEvent], pending: Data) {
        guard !data.isEmpty else { return ([], Data()) }
        let complete: Data
        var pending: Data
        if let newline = data.lastIndex(of: 10) {
            complete = data[data.startIndex...newline]
            pending = Data(data[data.index(after: newline)...])
        } else {
            complete = Data()
            pending = data
        }
        var events = AgentActivityEvent.events(
            in: complete, provider: provider, sessionID: sessionID)
        if !pending.isEmpty,
           (try? JSONSerialization.jsonObject(with: pending)) != nil {
            events.append(contentsOf: AgentActivityEvent.events(
                in: pending, provider: provider, sessionID: sessionID))
            pending.removeAll(keepingCapacity: false)
        } else if pending.count > 262_144 {
            pending = Data(pending.suffix(262_144))
        }
        events = events.enumerated().sorted {
            $0.element.date == $1.element.date
                ? $0.offset < $1.offset : $0.element.date < $1.element.date
        }.map(\.element)
        var latestResultIndex: Int?
        var latestStateIndex: Int?
        // Tool output usually follows a prompt within the same read, so the
        // prompt is kept separately or its interaction time would be lost.
        var latestPromptIndex: Int?
        for (index, event) in events.enumerated() {
            if case .result = event.kind { latestResultIndex = index }
            else { latestStateIndex = index }
            if case .prompt = event.kind { latestPromptIndex = index }
        }
        let relevant = Set([latestResultIndex, latestStateIndex, latestPromptIndex].compactMap { $0 })
            .sorted().map { events[$0] }
        return (relevant, pending)
    }

    private func continuityMatches(_ cursor: Cursor, in handle: FileHandle) -> Bool {
        guard !cursor.continuityProbe.isEmpty else { return true }
        return (try? continuityProbe(endingAt: cursor.offset, in: handle)) == cursor.continuityProbe
    }

    private func continuityProbe(endingAt offset: UInt64, in handle: FileHandle) throws -> Data {
        let length = min(UInt64(256), offset)
        guard length > 0 else { return Data() }
        try handle.seek(toOffset: offset - length)
        return try handle.read(upToCount: Int(length)) ?? Data()
    }

    /// A directory's modification time and entry count change when a session
    /// file appears or is removed, so an unchanged stamp reuses the file list
    /// instead of re-enumerating tens of thousands of transcripts.
    private func sessionFiles(root: URL) -> [URL] {
        let stamp = directoryStamp(root: root)
        if let cached = scans[root.path], cached.stamp == stamp {
            return cached.files
        }
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            var inspected = 0
            for case let url as URL in enumerator {
                inspected += 1
                if inspected > 50_000 { break }
                guard url.pathExtension == "jsonl" else { continue }
                files.append(url)
            }
        }
        scans[root.path] = (stamp, files)
        return files
    }

    private func directoryStamp(root: URL) -> String {
        var parts: [String] = []
        var pending = [root]
        while let directory = pending.popLast() {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            parts.append("\(directory.path)=\(modified)=\(children.count)")
            pending.append(contentsOf: children.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            })
        }
        return parts.sorted().joined(separator: ";")
    }
}
