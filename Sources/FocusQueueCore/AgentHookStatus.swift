import Foundation

/// Provider lifecycle hooks report each turn edge the moment it happens, so they
/// are the authoritative status source; transcripts remain the fallback when a
/// hook is missing (Claude sends none for Esc) or hooks are not installed.
public enum AgentHookStatus {
    /// Run through the provider's shell, which expands `$HOME`. The helper reads
    /// the agent's inherited `FOCUS_QUEUE_*` environment to find its record.
    public static let claudeCommand = "\"$HOME/.local/bin/focus-queue-session\" status-event --provider claude"

    /// Adds saved project data to the conversation, so unlike the status hooks it must run
    /// synchronously: an async hook's output never reaches the turn.
    public static let claudeDataCommand = "\"$HOME/.local/bin/focus-queue-session\" data-event --provider claude"

    /// Events that change what the agent is doing. Notification fires for many
    /// reasons; only a permission or input dialog means the agent is waiting.
    static let claudeEvents: [(event: String, matcher: String?)] = [
        ("UserPromptSubmit", nil), ("PreToolUse", nil), ("PostToolUse", nil),
        ("PostToolUseFailure", nil), ("PermissionRequest", nil),
        ("Notification", "permission_prompt|elicitation_dialog"), ("Stop", nil), ("StopFailure", nil),
    ]

    /// Claude Code honors only the last `--settings` flag, so the launch's plugin
    /// overrides and the status hooks share one value. `disableAllHooks: false`
    /// re-enables hooks for this agent when the user's settings turn them off.
    public static func claudeSettings(pluginOverrides: [String: Bool], statusHooks: Bool,
                                      skipBypassWarning: Bool = false) -> String? {
        var settings: [String: Any] = [:]
        if !pluginOverrides.isEmpty { settings["enabledPlugins"] = pluginOverrides }
        if skipBypassWarning { settings["skipDangerousModePermissionPrompt"] = true }
        if statusHooks {
            settings["disableAllHooks"] = false
            let handler: [String: Any] = ["type": "command", "command": claudeCommand, "async": true, "timeout": 10]
            var hooks: [String: Any] = [:]
            for (event, matcher) in claudeEvents {
                var group: [String: Any] = ["hooks": [handler]]
                if let matcher { group["matcher"] = matcher }
                hooks[event] = [group]
            }
            let data: [String: Any] = ["type": "command", "command": claudeDataCommand, "timeout": 10]
            hooks["UserPromptSubmit"] = [["hooks": [handler, data]]]
            hooks["SessionStart"] = [["matcher": "clear|compact", "hooks": [data]]]
            settings["hooks"] = hooks
        }
        guard !settings.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Maps one hook payload to a status event dated when the hook ran.
    /// Claude, Codex, and Kimi Code share these event names.
    public static func event(payload: [String: Any], date: Date = Date()) -> AgentActivityEvent? {
        let name = payload["hook_event_name"] as? String ?? ""
        // A sub-agent's own tool calls also reach the parent session's hooks,
        // including background ones after the parent's turn has ended.
        let fromSubagent = (payload["agent_id"] as? String)?.isEmpty == false
        let kind: AgentActivityEvent.Kind
        var summary = ""
        switch name {
        case "UserPromptSubmit":
            kind = .prompt
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch", "TurnStarted":
            guard !fromSubagent else { return nil }
            kind = .working
        case "PermissionRequest":
            kind = .attention(.approval); summary = "The agent is waiting for approval in its terminal."
        case "Notification":
            switch payload["notification_type"] as? String {
            case "permission_prompt":
                kind = .attention(.approval); summary = "The agent is waiting for approval in its terminal."
            case "elicitation_dialog":
                kind = .attention(.question); summary = "The agent has a question to answer."
            default: return nil
            }
        case "Stop":
            guard !fromSubagent else { return nil }
            kind = .result
            let reply = (payload["last_assistant_message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            summary = reply.isEmpty ? "New agent response" : reply
        case "StopFailure":
            let error = payload["error"] as? String ?? ""
            let details = payload["error_details"] as? String ?? ""
            let quota = ["rate_limit", "billing_error"].contains(error) || AgentActivityEvent.isQuotaError(details)
            kind = quota ? .attention(.quotaExhausted) : .attention(.failed)
            summary = details.isEmpty ? "The agent reported a problem." : details
        case "Interrupt":
            kind = .attention(.interrupted); summary = "The agent turn was interrupted."
        default:
            return nil
        }
        return AgentActivityEvent(id: "hook:\(name):\(UUID().uuidString)", date: date, kind: kind,
            summary: String(summary.prefix(2_000)), source: .hook)
    }

    /// Kimi names session directories `session_<uuid>`; compare the bare identity.
    static func sameSession(_ left: String?, _ right: String) -> Bool {
        func bare(_ value: String) -> String {
            let lowered = value.lowercased()
            return lowered.hasPrefix("session_") ? String(lowered.dropFirst("session_".count)) : lowered
        }
        guard let left, !right.isEmpty else { return false }
        return bare(left) == bare(right)
    }

    /// Applies a hook payload to the agent that owns its provider session. The
    /// launch's task and agent IDs are a fast path, used only when the saved
    /// session matches, because a nested launch inherits its parent's variables.
    /// Returns the updated context, or nil when no tracked agent owns the session.
    @discardableResult
    public static func apply(payload: [String: Any], provider: AgentProvider, environment: [String: String],
                             store: TaskContextStore, date: Date = Date()) async throws -> TaskContext? {
        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty,
              let event = event(payload: payload, date: date) else { return nil }
        func owns(_ subtask: TaskSubtask) -> Bool {
            subtask.provider == provider && sameSession(subtask.sessionID, sessionID)
                && (subtask.agentRemovedAt == nil || subtask.completionTerminalRetained == true)
        }
        var target: (ticketID: String, subtaskID: String)?
        if let taskID = environment["FOCUS_QUEUE_TASK_ID"], let subtaskID = environment["FOCUS_QUEUE_SUBTASK_ID"],
           let context = try? await store.load(ticketID: taskID),
           let subtask = context.subtasks.first(where: { $0.id == subtaskID }), owns(subtask) {
            target = (context.ticketID, subtask.id)
        } else {
            let owners = try await store.loadAvailableForDiscovery().flatMap { context in
                context.subtasks.filter(owns).map { (ticketID: context.ticketID, subtaskID: $0.id) }
            }
            if owners.count == 1 { target = owners[0] }
        }
        guard let target else { return nil }
        return try await store.observeActivity(ticketID: target.ticketID, subtaskID: target.subtaskID, event: event)
    }
}
