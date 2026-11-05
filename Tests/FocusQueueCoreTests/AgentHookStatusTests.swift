import Foundation
import Testing
@testable import FocusQueueCore

/// Provider hooks report turn edges as they happen; transcripts fill the gaps.
@Suite("Agent hook status")
struct AgentHookStatusTests {
    private let session = UUID().uuidString.lowercased()

    private func makeStore() async throws -> (TaskContextStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-910", title: "Task", status: "open", summary: ""))
        var agent = TaskSubtask(id: "a", title: "A", provider: .claude, sessionID: session, status: .idle)
        agent.lastHeartbeatAt = Date().addingTimeInterval(-3_600)
        _ = try await store.upsertSubtask(ticketID: "ECC-910", subtask: agent)
        return (store, root)
    }

    private func hook(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": session, "hook_event_name": name, "cwd": "/tmp"].merging(extra) { $1 }
    }

    @discardableResult
    private func apply(_ store: TaskContextStore, _ payload: [String: Any], at date: Date,
                       environment: [String: String] = [:]) async throws -> TaskSubtask? {
        let context = try await AgentHookStatus.apply(payload: payload, provider: .claude,
            environment: environment, store: store, date: date)
        return context?.subtasks.first { $0.id == "a" }
    }

    @Test("Hook events map to prompts, work, approvals, results, failures, and interrupts")
    func mapping() {
        func kind(_ payload: [String: Any]) -> AgentActivityEvent.Kind? { AgentHookStatus.event(payload: payload)?.kind }
        #expect(kind(hook("UserPromptSubmit")) == .prompt)
        #expect(kind(hook("PreToolUse")) == .working)
        #expect(kind(hook("PostToolUse")) == .working)
        #expect(kind(hook("PreToolUse", ["agent_id": "sub-1"])) == nil, "a sub-agent's tools are not the parent's turn")
        #expect(kind(hook("PermissionRequest", ["agent_id": "sub-1"])) == .attention(.approval))
        #expect(kind(hook("Notification", ["notification_type": "permission_prompt"])) == .attention(.approval))
        #expect(kind(hook("Notification", ["notification_type": "elicitation_dialog"])) == .attention(.question))
        #expect(kind(hook("Notification", ["notification_type": "idle_prompt"])) == nil)
        #expect(kind(hook("SessionStart", ["source": "compact"])) == nil)
        #expect(kind(hook("StopFailure", ["error": "rate_limit"])) == .attention(.quotaExhausted))
        #expect(kind(hook("StopFailure", ["error": "server_error"])) == .attention(.failed))
        #expect(kind(hook("Interrupt")) == .attention(.interrupted))
        let stop = AgentHookStatus.event(payload: hook("Stop", ["last_assistant_message": " Fixed it. "]))
        #expect(stop?.kind == .result)
        #expect(stop?.summary == "Fixed it.")
        #expect(stop?.source == .hook)
    }

    @Test("Claude launch settings carry plugin overrides and async status hooks in one value")
    func claudeSettings() throws {
        #expect(AgentProvider.claude.pluginArguments(overrides: [:]).isEmpty)
        #expect(AgentProvider.codex.pluginArguments(overrides: [:], statusHooks: true).isEmpty)
        let arguments = AgentProvider.claude.pluginArguments(overrides: ["ecc@ecc": false], statusHooks: true)
        #expect(arguments.count == 2 && arguments[0] == "--settings")
        let settings = try #require(JSONSerialization.jsonObject(with: Data(arguments[1].utf8)) as? [String: Any])
        #expect(settings["disableAllHooks"] as? Bool == false)
        #expect((settings["enabledPlugins"] as? [String: Bool]) == ["ecc@ecc": false])
        let hooks = try #require(settings["hooks"] as? [String: [[String: Any]]])
        #expect(Set(hooks.keys) == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "PermissionRequest", "Notification", "Stop", "StopFailure"])
        // The data hook must be synchronous, or its context never reaches the turn.
        let promptHooks = try #require(hooks["UserPromptSubmit"]?.first?["hooks"] as? [[String: Any]])
        #expect(promptHooks.map { $0["command"] as? String } == [AgentHookStatus.claudeCommand, AgentHookStatus.claudeDataCommand])
        #expect(promptHooks[1]["async"] == nil)
        #expect(hooks["SessionStart"]?.first?["matcher"] as? String == "clear|compact")
        let handler = try #require((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(handler["async"] as? Bool == true)
        #expect(handler["command"] as? String == AgentHookStatus.claudeCommand)
        #expect(hooks["Notification"]?.first?["matcher"] as? String == "permission_prompt|elicitation_dialog")
    }

    @Test("A hook finds its agent by session; an inherited task ID for another session is ignored")
    func targeting() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let direct = try await apply(store, hook("UserPromptSubmit"), at: now,
            environment: ["FOCUS_QUEUE_TASK_ID": "ECC-910", "FOCUS_QUEUE_SUBTASK_ID": "a"])
        #expect(direct?.status == .working)
        let nested = try await AgentHookStatus.apply(payload: ["session_id": UUID().uuidString,
            "hook_event_name": "Stop"], provider: .claude,
            environment: ["FOCUS_QUEUE_TASK_ID": "ECC-910", "FOCUS_QUEUE_SUBTASK_ID": "a"],
            store: store, date: now.addingTimeInterval(1))
        #expect(nested == nil, "a nested launch's own session never updates its parent's agent")
        let scanned = try await apply(store, hook("Stop"), at: now.addingTimeInterval(2))
        #expect(scanned?.status == .idle)
        #expect(scanned?.completionUnread == true)
        let wrongProvider = try await AgentHookStatus.apply(payload: hook("UserPromptSubmit"), provider: .codex,
            environment: [:], store: store, date: now.addingTimeInterval(3))
        #expect(wrongProvider == nil)
    }

    @Test("A hook-opened turn stays Working through a long silent tool while its pane lives")
    func longToolCall() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        try await apply(store, hook("UserPromptSubmit"), at: start)
        let running = try #require(try await apply(store, hook("PreToolUse"), at: start.addingTimeInterval(5)))
        #expect(running.statusFromHook)
        let later = start.addingTimeInterval(2 * 3_600)
        #expect(running.effectiveStatus(now: later, heartbeatLifetime: running.heartbeatLifetime(liveRuntime: true)) == .working)
        #expect(running.effectiveStatus(now: later, heartbeatLifetime: running.heartbeatLifetime(liveRuntime: false)) == .idle,
            "a pane that is gone still decays")
        var transcriptOnly = running
        transcriptOnly.lastHookEventAt = nil
        #expect(transcriptOnly.heartbeatLifetime(liveRuntime: true) == TaskSubtask.liveRuntimeHeartbeatLifetime)
        #expect(transcriptOnly.heartbeatLifetime(liveRuntime: true, runtimeShowsWork: true)
            == TaskSubtask.hookedRuntimeHeartbeatLifetime)
    }

    @Test("Hooks and the transcript of the same turn agree: one result, approval, then work again")
    func hookAndTranscriptInterleave() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        try await apply(store, hook("UserPromptSubmit"), at: start)
        let waiting = try await apply(store, hook("PermissionRequest"), at: start.addingTimeInterval(2))
        #expect(waiting?.attention == .approval)
        // The transcript's tool-call record predates the approval wait and must not clear it.
        let stale = try await store.observeActivity(ticketID: "ECC-910", subtaskID: "a",
            event: .init(id: "t1", date: start.addingTimeInterval(1), kind: .working, summary: ""))
        #expect(stale.subtasks.first?.attention == .approval)
        let resumed = try await apply(store, hook("PostToolUse"), at: start.addingTimeInterval(30))
        #expect(resumed?.status == .working)
        #expect(resumed?.attention == nil)
        let done = try #require(try await apply(store, hook("Stop", ["last_assistant_message": "Done."]),
            at: start.addingTimeInterval(40)))
        #expect(done.status == .idle && done.completionUnread && done.resultSummary == "Done.")
        _ = try await store.acknowledgeCompletion(ticketID: "ECC-910", subtaskID: "a")
        // The transcript's end-of-turn record is dated before the Stop hook ran.
        let echoed = try await store.observeActivity(ticketID: "ECC-910", subtaskID: "a",
            event: .init(id: "t2", date: start.addingTimeInterval(39), kind: .result, summary: "Done."))
        #expect(echoed.subtasks.first?.completionUnread == false, "the transcript echo is not a second result")
        // Esc sends no hook; the transcript's interrupt marker still lands.
        let interrupted = try await store.observeActivity(ticketID: "ECC-910", subtaskID: "a",
            event: .init(id: "t3", date: start.addingTimeInterval(300), kind: .attention(.interrupted), summary: ""))
        #expect(interrupted.subtasks.first?.attention == .interrupted)
        #expect(interrupted.subtasks.first?.statusFromHook == false)
    }

    @Test("A closed approval dialog means the step runs; a later denial marker still lands")
    func answeredApproval() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        let waiting = try #require(try await apply(store, hook("PermissionRequest"), at: start))
        let resolved = try #require(try await store.resolveApproval(ticketID: "ECC-910", subtaskID: "a").subtasks.first)
        #expect(resolved.status == .working && resolved.attention == nil)
        #expect(resolved.lastHeartbeatAt == waiting.lastHeartbeatAt, "the heartbeat stays at the approval request")
        let denied = try await store.observeActivity(ticketID: "ECC-910", subtaskID: "a",
            event: .init(id: "deny", date: start.addingTimeInterval(2), kind: .attention(.interrupted), summary: ""))
        #expect(denied.subtasks.first?.attention == .interrupted)
        let untouched = try await store.resolveApproval(ticketID: "ECC-910", subtaskID: "a")
        #expect(untouched.subtasks.first?.attention == .interrupted, "only an approval wait resolves")
    }

    @Test("Claude's named-target approval dialogs are recognized; prose is not")
    func approvalDialogs() {
        let bash = """
         Bash command
           touch /tmp/fq-hook-sanity-approval; sleep 5; echo approved-ok
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and always allow access to /tmp from this project
           4. No
         Esc to cancel · Tab to amend
        """
        #expect(TaskAgentLauncher.terminalAttention(bash) == .approval)
        #expect(TaskAgentLauncher.terminalAttention("Do you want to make this edit to AgentHookStatus.swift?\n❯ 1. Yes\n  3. No") == .approval)
        #expect(TaskAgentLauncher.terminalAttention("Do you want to make this edit to X.swift?") == nil)
        #expect(TaskAgentLauncher.terminalAttention("I asked: do you want to proceed?\n1. Yes\nNo") == nil)
    }

    @Test("Only a Codex pane whose title shows the braille spinner reads as running")
    func codexSpinner() throws {
        func pane(_ id: String) throws -> TmuxPaneSnapshot {
            try #require(try TmuxPaneSnapshot.decode(
                "fq-task-ecc-910|10|1|\(id)|20|/dev/ttys001|0|@1|0|100|40|0|0|100|40|x|||1|auto",
                executable: "/usr/bin/true").first)
        }
        let panes = try [pane("%1"), pane("%2"), pane("%3")]
        func agent(_ id: String, _ provider: AgentProvider, _ paneID: String) -> TaskSubtask {
            var agent = TaskSubtask(id: id, title: id, provider: provider, status: .working)
            agent.tmux = panes.first { $0.reference.paneID == paneID }?.reference
            return agent
        }
        var snapshot = TaskAgentLauncher.RuntimeSnapshot()
        snapshot.tmuxPanes["/usr/bin/true"] = panes
        snapshot.tmuxPaneTitles["/usr/bin/true"] = ["%1": "⠦ Link agent files", "%2": "Link agent files", "%3": "⠏ Fix it"]
        let ids = TaskAgentLauncher.spinningRuntimeSubtaskIDs(
            subtasks: [agent("busy", .codex, "%1"), agent("still", .codex, "%2"), agent("claude", .claude, "%3")],
            snapshot: snapshot)
        #expect(ids == ["busy"])
    }
}
