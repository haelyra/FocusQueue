import Foundation

/// Conversation side of decision nodes. Claude Code resumes a session only at
/// its end in interactive mode, so a node keeps a copy of the transcript up to
/// the decision; a rewind writes that copy back as a fresh session and resumes
/// it. Managed Codex and Kimi panes cannot resume mid-conversation yet, so their
/// rewind restores the code and tells the same session to drop the turns after
/// the decision.
public enum DecisionConversations {
    public static func claudeRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Claude Code names a project folder after the working directory with every
    /// non-alphanumeric character replaced by a dash.
    public static func claudeProjectDirectoryName(forWorkingDirectory cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The transcript of a Claude session, preferring the workspace's project folder.
    public static func claudeTranscript(sessionID: String, workspace: String?, root: URL) -> URL? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let fileName = sessionID.lowercased() + ".jsonl"
        if let workspace {
            let candidate = projects.appendingPathComponent(claudeProjectDirectoryName(forWorkingDirectory: workspace))
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.map { $0.appendingPathComponent(fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Saves the conversation for a node. Never throws: a conversation that
    /// cannot be saved leaves a note, and the code checkpoint still stands.
    public static func capture(provider: AgentProvider, sessionID: String?, workspace: String?,
                               destination: URL, claudeRoot: URL) -> DecisionConversation {
        var conversation = DecisionConversation(provider: provider.rawValue, sessionID: sessionID)
        guard let sessionID, !sessionID.isEmpty else {
            conversation.note = "The agent has no recorded provider session, so only the code can be rewound."
            return conversation
        }
        switch provider {
        case .claude:
            guard let transcript = claudeTranscript(sessionID: sessionID, workspace: workspace, root: claudeRoot) else {
                conversation.note = "Claude transcript \(sessionID) was not found under \(claudeRoot.path)/projects."
                return conversation
            }
            conversation.transcriptPath = transcript.path
            do {
                let kept = try snapshotClaude(transcript: transcript, destination: destination)
                conversation.snapshotPath = destination.path
                conversation.entries = kept
            } catch {
                conversation.note = "The conversation could not be saved: \(error.localizedDescription)"
            }
        case .codex, .kimi, .copilot:
            conversation.note = "\(provider.displayName) panes cannot resume mid-conversation yet: a rewind restores the code and tells the same session to drop the turns after this decision."
        }
        return conversation
    }

    /// Copies the transcript through its last complete message and returns the
    /// lines kept. When the conversation ends in a tool call still running (the
    /// agent's own `decision add`), that call is left out: the copy ends at the
    /// last user entry, so a resume never meets a tool use without its result.
    @discardableResult
    public static func snapshotClaude(transcript: URL, destination: URL) throws -> Int {
        let data = try SafeFileRead.data(at: transcript, limit: 256 * 1024 * 1024)
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let entries = lines.map { line in (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] }
        func type(_ index: Int) -> String? { entries[index]?["type"] as? String }
        let lastUser = entries.indices.last { type($0) == "user" }
        let lastMessage = entries.indices.last { type($0) == "user" || type($0) == "assistant" }
        guard let lastUser, let lastMessage else {
            throw DecisionTreeError.notAllowed("The transcript has no user turn to resume from yet.")
        }
        let last = type(lastMessage) == "assistant" && callsTool(entries[lastMessage]) ? lastUser : lastMessage
        var output = Data()
        for line in lines[...last] { output.append(contentsOf: line); output.append(0x0A) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: destination, options: .atomic)
        return last + 1
    }

    /// Writes a snapshot back as a new Claude session for `workspace` and returns
    /// its ID. The copy's session ID is rewritten so it never collides with the
    /// original conversation, which stays as it was.
    public static func materializeClaude(snapshot: URL, originalSessionID: String?, workspace: String,
                                         root: URL, newSessionID: String = UUID().uuidString.lowercased()) throws -> String {
        let data = try SafeFileRead.data(at: snapshot, limit: 256 * 1024 * 1024)
        var text = String(decoding: data, as: UTF8.self)
        let previous = originalSessionID?.lowercased() ?? sessionID(inClaudeTranscript: text)
        if let previous, !previous.isEmpty {
            for key in ["sessionId", "session_id"] {
                text = text.replacingOccurrences(of: "\"\(key)\":\"\(previous)\"", with: "\"\(key)\":\"\(newSessionID)\"")
            }
        }
        let folder = root.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(claudeProjectDirectoryName(forWorkingDirectory: workspace), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(newSessionID + ".jsonl")
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw DecisionTreeError.notAllowed("Session \(newSessionID) already exists.")
        }
        try Data(text.utf8).write(to: target, options: .atomic)
        return newSessionID
    }

    /// Whether a Claude entry's message holds a `tool_use` block.
    static func callsTool(_ entry: [String: Any]?) -> Bool {
        let content = (entry?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.contains { $0["type"] as? String == "tool_use" }
    }

    static func sessionID(inClaudeTranscript text: String) -> String? {
        for line in text.split(separator: "\n").prefix(200) {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let id = object["sessionId"] as? String { return id.lowercased() }
        }
        return nil
    }

    /// What the resumed or forked conversation hears first after a rewind.
    public static func rewindPrompt(taskID: String, agentID: String, node: DecisionNode, option: DecisionOption,
                                    reason: String?, restore: DecisionCheckpointing.RestoreResult?,
                                    conversationForked: Bool, provider: AgentProvider) -> String {
        var lines = ["[Focus Queue] Rewound to decision \(node.id) (\(node.title))."]
        if let restore {
            lines.append("The worktree now matches checkpoint \(String(node.checkpoint?.commit.prefix(10) ?? "?")); the abandoned work is saved at \(restore.saved.ref) (\(restore.saved.shortCommit)).")
            if let note = restore.branchNote { lines.append(note) }
        }
        if !conversationForked {
            lines.append("Everything you did after this decision was abandoned: disregard those turns and re-read files before editing.")
        }
        if let reason, !reason.isEmpty { lines.append("Why the previous path was abandoned: \(reason)") }
        lines.append("Take option \(option.id): \(option.label)" + (option.detail.map { " — \($0)" } ?? ""))
        if conversationForked {
            lines.append("This conversation is a fork saved at the decision. Run `focus-queue-session attach \(taskID)` first so it is the agent's record.")
        }
        lines.append("If this option also fails, rewind again with `focus-queue-session decision rewind \(taskID) \(agentID) \(node.id) --reason \"<why>\"`.")
        return lines.joined(separator: "\n")
    }
}
