import Foundation

/// The task agent whose provider transcript records writing a document.
public struct DocumentAuthor: Equatable, Sendable {
    public let subtaskID: String
    public let provider: AgentProvider
    public let sessionID: String
    public let title: String
    /// When the transcript first wrote (or, lacking a write, first touched) the document.
    public let touchedAt: Date

    public init(subtaskID: String, provider: AgentProvider, sessionID: String, title: String, touchedAt: Date) {
        self.subtaskID = subtaskID
        self.provider = provider
        self.sessionID = sessionID
        self.title = title
        self.touchedAt = touchedAt
    }
}

/// Finds which agent created a document from the agents' own transcripts.
/// Focus Queue records no file ownership, so the transcript tool calls are
/// the only evidence. A write (an edit tool, a patch, or a shell redirect)
/// outranks any other tool call that names the path; among equals the
/// earliest wins. Another tool call, such as a generator script, counts only
/// when it ran just before the file appeared, so reading a file never makes
/// an agent its author.
public enum DocumentAuthorship {
    public struct Touch: Equatable, Sendable {
        public var firstWrite: Date?
        public var toolCalls: [Date] = []
    }

    /// How long before the file's creation a non-write tool call may run.
    static let creationWindow: ClosedRange<TimeInterval> = -120...5

    public static func author(of documentPath: String, agents: [(agent: TaskSubtask, transcript: URL)],
                              createdAt: Date? = nil) -> DocumentAuthor? {
        var best: (author: DocumentAuthor, wrote: Bool)?
        for (agent, transcript) in agents {
            guard let sessionID = agent.sessionID, !agent.isAssignmentOnly else { continue }
            var needles = [documentPath]
            if let workspace = agent.workspace?.path, !workspace.isEmpty,
               documentPath.hasPrefix(workspace.hasSuffix("/") ? workspace : workspace + "/") {
                // Codex patches name files relative to the workspace.
                needles.append(String(documentPath.dropFirst(workspace.count).drop { $0 == "/" }))
            }
            let touch = touches(in: transcript, needles: needles, provider: agent.provider)
            let creating = createdAt.flatMap { created in
                touch.toolCalls.filter { creationWindow.contains($0.timeIntervalSince(created)) }.min()
            }
            guard let date = touch.firstWrite ?? creating else { continue }
            let wrote = touch.firstWrite != nil
            if let current = best {
                if current.wrote && !wrote { continue }
                if current.wrote == wrote && current.author.touchedAt <= date { continue }
            }
            best = (DocumentAuthor(subtaskID: agent.id, provider: agent.provider, sessionID: sessionID,
                title: agent.title, touchedAt: date), wrote)
        }
        return best?.author
    }

    /// Scans a JSONL transcript for tool calls naming any of `needles`.
    public static func touches(in transcript: URL, needles: [String], provider: AgentProvider) -> Touch {
        var touch = Touch()
        let patterns = needles.filter { !$0.isEmpty }.map { Data($0.utf8) }
        guard !patterns.isEmpty,
              let data = try? Data(contentsOf: transcript, options: .alwaysMapped) else { return touch }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 10) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : end
            // Escaped paths may not contain the literal UTF-8 needle. Keep the
            // cheap rejection for unescaped lines, then inspect decoded tool inputs.
            guard line.contains(92) || patterns.contains(where: { line.range(of: $0) != nil }) else { continue }
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let kind = toolCallKind(record, provider: provider, needles: needles),
                  let date = timestamp(record, provider: provider) else { continue }
            if kind == .write, touch.firstWrite.map({ date < $0 }) ?? true { touch.firstWrite = date }
            touch.toolCalls.append(date)
        }
        return touch
    }

    enum ToolCallKind { case write, other }

    /// Shell text is decoded before matching, independent of JSON escaping.
    static let shellWritePrefixes = [">", "> ", ">>", ">> ", "> \"", ">> \"", "> '", ">> '",
                                     "tee ", "tee -a ", "-o ", "--output ", "--output="]

    static func toolCallKind(_ record: [String: Any], provider: AgentProvider, needles: [String]) -> ToolCallKind? {
        let calls: [[String: Any]]
        let inputKey: String
        let writeTools: Set<String>
        switch provider {
        case .claude:
            guard record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any],
                  let content = message["content"] as? [Any] else { return nil }
            calls = content.compactMap { $0 as? [String: Any] }.filter { $0["type"] as? String == "tool_use" }
            inputKey = "input"
            writeTools = ["Write", "Edit", "MultiEdit", "NotebookEdit"]
        case .codex:
            guard record["type"] as? String == "response_item",
                  let payload = record["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  ["function_call", "custom_tool_call"].contains(type) else { return nil }
            calls = [payload]
            inputKey = type == "function_call" ? "arguments" : "input"
            writeTools = []
        case .kimi:
            // Wire logs nest the call in a loop event; a bare `tool.call` record is the same call.
            let event = record["event"] as? [String: Any] ?? record
            guard event["type"] as? String == "tool.call" else { return nil }
            calls = [event]
            inputKey = "args"
            writeTools = ["Write", "Edit", "WriteFile", "StrReplaceFile"]
        case .copilot:
            guard record["type"] as? String == "tool.execution_start",
                  let data = record["data"] as? [String: Any],
                  let toolName = data["toolName"] as? String else { return nil }
            calls = [["name": toolName, "arguments": data["arguments"] as Any]]
            inputKey = "arguments"
            writeTools = ["create", "edit"]
        }
        var matched = false
        for call in calls {
            guard let name = call["name"] as? String, let rawInput = call[inputKey] else { continue }
            // Codex function arguments (and some provider tool arguments) are
            // JSON encoded inside a string; custom patch input is plain text.
            let input: Any
            if let text = rawInput as? String,
               let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                input = decoded
            } else {
                input = rawInput
            }
            if writeTools.contains(name) {
                // A file mentioned in written content is not the write target.
                guard let arguments = input as? [String: Any] else { continue }
                let paths = ["file_path", "path", "notebook_path"].compactMap { arguments[$0] as? String }
                if paths.contains(where: needles.contains) { return .write }
                continue
            }
            let texts = argumentStrings(input)
            guard texts.contains(where: { text in needles.contains(where: text.contains) }) else { continue }
            matched = true
            let prefixes = ["Add File: ", "Update File: ", "Move to: "] + shellWritePrefixes
            if texts.contains(where: { text in
                needles.contains { needle in prefixes.contains { text.contains($0 + needle) } }
            }) { return .write }
        }
        return matched ? .other : nil
    }

    private static func argumentStrings(_ value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let object = value as? [String: Any] { return object.values.flatMap(argumentStrings) }
        if let array = value as? [Any] { return array.flatMap(argumentStrings) }
        return []
    }

    static func timestamp(_ record: [String: Any], provider: AgentProvider) -> Date? {
        if provider == .kimi, let milliseconds = record["time"] as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        guard let value = record["timestamp"] as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }
}
