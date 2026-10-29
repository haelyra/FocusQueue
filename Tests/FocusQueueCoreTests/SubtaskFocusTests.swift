import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Subtask focus and agent activity")
struct SubtaskFocusTests {
    private func context() -> TaskContext {
        TaskContext(ticketID: "ECC-700", title: "Task", summary: "", successCriteria: "",
            planPath: "/tmp/tasks/ECC-700/plan.md", updatedAt: Date())
    }

    @Test("Unassigned subtasks remain visible; active assignments sort first")
    func priorityAndEmptyAssignments() {
        var context = context()
        let queued = TaskSubtask(id: "queued", title: "Unassigned")
        var working = TaskSubtask(id: "working", title: "In progress")
        working.isAssignmentOnly = true
        var agent = TaskSubtask(id: "agent", title: "Worker", status: .working, lastHeartbeatAt: Date())
        agent.parentSubtaskID = working.id
        context.subtasks = [queued, working, agent]
        context.refreshAssignmentStatuses()
        #expect(context.focusSubtasks.map(\.id) == ["working", "queued"])
        #expect(context.agents(for: "queued").isEmpty)
        #expect(context.agents(for: "working").map(\.id) == ["agent"])
        context.subtasks[2].agentRemovedAt = Date()
        context.refreshAssignmentStatuses()
        #expect(context.focusSubtasks.count == 2)
        #expect(context.agents(for: "working").isEmpty)
    }

    @Test("Multiple agents keep their workspaces; shared conversations merge only at review and retain aliases")
    func mergeAtReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-700", title: "Task", status: "open", summary: ""))
        var a = TaskSubtask(id: "a", title: "First")
        var b = TaskSubtask(id: "b", title: "Second")
        a.isAssignmentOnly = true; b.isAssignmentOnly = true
        var agent = TaskSubtask(id: "agent", title: "Worker", sessionID: UUID().uuidString, status: .working, lastHeartbeatAt: Date())
        agent.parentSubtaskID = "a"; agent.tracksCompletion = false
        agent.workspace = AgentWorkspace(path: "/tmp/first", repositoryPath: "/tmp/repo", branch: "first")
        var second = TaskSubtask(id: "second", title: "Other worker", provider: .claude, sessionID: UUID().uuidString, status: .working, lastHeartbeatAt: Date())
        second.parentSubtaskID = "a"; second.tracksCompletion = false
        second.workspace = AgentWorkspace(path: "/tmp/second", repositoryPath: "/tmp/repo", branch: "second")
        for entry in [a, b, agent, second] { _ = try await store.upsertSubtask(ticketID: "ECC-700", subtask: entry) }
        let associated = try await store.associateAgent(ticketID: "ECC-700", agentID: "agent", subtaskID: "b")
        #expect(associated.focusSubtasks.count == 2)
        #expect(associated.agents(for: "a").count == 2)
        let merged = try await store.reconcileSubtasks(ticketID: "ECC-700")
        #expect(merged.focusSubtasks.map(\.title) == ["First + Second"])
        #expect(merged.canonicalSubtaskID("b") == "a")
        #expect(merged.subtasks.count == 4)
        #expect(merged.agents(for: "b").count == 2)
        #expect(merged.subtasks.first { $0.id == "agent" }?.workspace == agent.workspace)
        let repeated = try await store.reconcileSubtasks(ticketID: "ECC-700")
        #expect(repeated == merged)
        _ = try await store.updateProgress(ticketID: "ECC-700", subtaskID: "agent", status: .completed, summary: "One done")
        #expect(try await store.load(ticketID: "ECC-700")?.focusSubtasks.first?.status != .completed)
        let complete = try await store.updateProgress(ticketID: "ECC-700", subtaskID: "second", status: .completed, summary: "Both done")
        #expect(complete.focusSubtasks.first?.status == .completed)
        #expect(try await TaskContextStore(root: root).load(ticketID: "ECC-700") == complete)
    }

    @Test("Legacy duplicate sessions merge by provider and preserve old command IDs")
    func legacyMerge() {
        var context = context()
        let id = UUID().uuidString
        context.subtasks = [TaskSubtask(id: "a", title: "A", sessionID: id),
            TaskSubtask(id: "b", title: "B", sessionID: id.uppercased()),
            TaskSubtask(id: "c", title: "C", provider: .claude, sessionID: id)]
        context.mergeSharedAgentSubtasks()
        #expect(context.focusSubtasks.count == 2)
        #expect(context.agents(for: "a").count == 1)
        #expect(context.canonicalSubtaskID("b") == "a")
        #expect(context.canonicalSubtaskID("c") == "c")
    }

    @Test("Legacy combined subtask agents separate without changing the runtime identity")
    func legacyCombinedRecordSeparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let ticket = DashboardTicket(id: "ECC-700", title: "Task", status: "open", summary: "")
        _ = try await store.ensureContext(ticket: ticket)
        var legacy = TaskSubtask(
            id: "legacy-agent", title: "Repair the queue", provider: .codex,
            sessionID: "saved-session", status: .blocked, lastHeartbeatAt: Date())
        legacy.progressSummary = "Waiting for a dependency"
        legacy.initialPrompt = "Repair the queue without losing the existing session."
        var persisted = try #require(try await store.load(ticketID: ticket.id))
        persisted.schemaVersion = 1
        persisted.subtasks = [legacy]
        let contextURL = try await store.directory(ticketID: ticket.id)
            .appendingPathComponent("context.json")
        try JSONEncoder().encode(persisted).write(to: contextURL, options: .atomic)

        let migrated = try await store.ensureContext(ticket: ticket)
        let assignment = try #require(migrated.focusSubtasks.first)
        let agent = try #require(migrated.agents(for: assignment.id).first)

        #expect(migrated.focusSubtasks.count == 1)
        #expect(assignment.isAssignmentOnly)
        #expect(assignment.status == .blocked)
        #expect(agent.id == legacy.id)
        #expect(agent.parentSubtaskID == assignment.id)
        #expect(agent.sessionID == legacy.sessionID)
        #expect(!agent.tracksCompletion)
        #expect(migrated.schemaVersion == TaskContext.currentSchemaVersion)

        let repeated = try await store.ensureContext(ticket: ticket)
        #expect(repeated.subtasks == migrated.subtasks)
    }

    @Test("Results survive automatic retirement and working reports; acknowledgement cannot clear a newer result")
    func unreadLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-700", title: "Task", status: "open", summary: ""))
        let agent = TaskSubtask(id: "worker", title: "Worker", sessionID: UUID().uuidString)
        _ = try await store.upsertSubtask(ticketID: "ECC-700", subtask: agent)
        let first = try await store.reportAttention(ticketID: "ECC-700", subtaskID: "worker", attention: nil, summary: "Response", result: true)
        let firstID = try #require(first.subtasks[0].resultID)
        let working = try await store.updateProgress(ticketID: "ECC-700", subtaskID: "worker", status: .working, summary: "Continuing")
        #expect(working.subtasks[0].completionUnread)
        #expect(working.subtasks[0].resultSummary == "Response")
        #expect(working.subtasks[0].status != .completed)
        _ = try await store.updateProgress(ticketID: "ECC-700", subtaskID: "worker", status: .completed, summary: "Verified")
        let retired = try await store.removeAgent(ticketID: "ECC-700", subtaskID: "worker", automatically: true)
        #expect(retired.agents(for: "worker").count == 1)
        #expect(!retired.subtasks[0].isAgentVisible)
        let stale = try await store.acknowledgeCompletion(ticketID: "ECC-700", subtaskID: "worker", expectedResultID: firstID)
        #expect(stale.subtasks[0].completionUnread)
        let seen = try await store.acknowledgeCompletion(ticketID: "ECC-700", subtaskID: "worker", expectedResultID: stale.subtasks[0].resultID)
        #expect(seen.agents(for: "worker").isEmpty)
        #expect(seen.focusSubtasks.count == 1)
    }

    @Test("Structured activity distinguishes results, questions, interruptions, and foreign conversations")
    func activityParser() throws {
        let codex = Data(#"{"timestamp":"2026-09-15T18:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"text":"Ready to review"}]}}"#.utf8)
        #expect(AgentActivityEvent.latest(in: codex, provider: .codex, sessionID: "one")?.kind == .result)
        let interruption = Data(#"{"timestamp":"2026-09-15T18:00:00Z","type":"event_msg","payload":{"type":"turn_aborted","thread_id":"one"}}"#.utf8)
        #expect(AgentActivityEvent.latest(in: interruption, provider: .codex, sessionID: "one")?.kind == .attention(.interrupted))
        #expect(AgentActivityEvent.latest(in: interruption, provider: .codex, sessionID: "two") == nil)
        let claude = Data(#"{"timestamp":"2026-09-15T18:00:00Z","sessionId":"one","type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion"}]}}"#.utf8)
        #expect(AgentActivityEvent.latest(in: claude, provider: .claude, sessionID: "one")?.kind == .attention(.question))
        #expect(AgentActivityEvent.latest(in: claude, provider: .claude, sessionID: "two") == nil)
        #expect(TaskAgentLauncher.terminalAttention("Do you want to proceed?\n› 1. Yes\n  2. No (Esc)") == .approval)
        #expect(TaskAgentLauncher.terminalAttention("The agent asked: Do you want to proceed?") == nil)
    }

    @Test("Quota and credit errors classify distinctly from generic failures")
    func quotaErrorClassification() throws {
        let codexQuota = Data(#"{"timestamp":"2026-09-15T18:00:00Z","type":"event_msg","payload":{"type":"error","thread_id":"one","message":"Rate limit reached for this plan"}}"#.utf8)
        let quotaEvent = try #require(AgentActivityEvent.latest(in: codexQuota, provider: .codex, sessionID: "one"))
        #expect(quotaEvent.kind == .attention(.quotaExhausted))
        #expect(quotaEvent.summary.contains("Rate limit"))
        let codexFailure = Data(#"{"timestamp":"2026-09-15T18:00:00Z","type":"event_msg","payload":{"type":"error","thread_id":"one","message":"The apply_patch call failed"}}"#.utf8)
        #expect(AgentActivityEvent.latest(in: codexFailure, provider: .codex, sessionID: "one")?.kind == .attention(.failed))
        let claudeQuota = Data(#"{"timestamp":"2026-09-15T18:00:00Z","sessionId":"one","type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"You've hit your limit · resets 3pm"}]}}"#.utf8)
        #expect(AgentActivityEvent.latest(in: claudeQuota, provider: .claude, sessionID: "one")?.kind == .attention(.quotaExhausted))
        let claudeFailure = Data(#"{"timestamp":"2026-09-15T18:00:00Z","sessionId":"one","type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Overloaded"}]}}"#.utf8)
        #expect(AgentActivityEvent.latest(in: claudeFailure, provider: .claude, sessionID: "one")?.kind == .attention(.failed))
        #expect(AgentActivityEvent.isQuotaError("INSUFFICIENT CREDITS"))
        #expect(AgentActivityEvent.isQuotaError("HTTP 429 returned"))
        #expect(!AgentActivityEvent.isQuotaError("compiler error"))
        #expect(!AgentActivityEvent.isQuotaError(""))
        #expect(AgentAttention.quotaExhausted.isProblem)
        #expect(AgentAttention.quotaExhausted.label == "Quota exhausted")
    }

    @Test("Session file scans reuse an unchanged directory stamp and notice new transcripts")
    func activityScanCaching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("codex/sessions/2026/09/27")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let observer = AgentActivityObserver(codexRoot: root.appendingPathComponent("codex"),
            claudeRoot: root.appendingPathComponent("claude"))
        #expect(try await observer.latest(for: TaskSubtask(id: "missing", title: "Missing",
            provider: .codex, sessionID: UUID().uuidString)) == nil)
        let sessionID = UUID().uuidString
        let line = #"{"timestamp":"2026-09-15T18:00:00Z","type":"event_msg","payload":{"type":"task_complete","thread_id":"\#(sessionID)"}}"#
        try Data((line + "\n").utf8).write(to: sessions
            .appendingPathComponent("rollout-2026-09-27T18-00-00-\(sessionID).jsonl"))
        // The new transcript changes the directory stamp, so the first search
        // for its session re-enumerates instead of reusing the stale file list.
        let event = try await observer.latest(for: TaskSubtask(id: "found", title: "Found",
            provider: .codex, sessionID: sessionID))
        #expect(event?.kind == .result)
    }

    @Test("Archived Codex conversations remain discoverable for reconnect")
    func archivedCodexTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archived-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("codex/archived_sessions/2026/10/29")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let transcript = archive.appendingPathComponent("rollout-archived-\(sessionID).jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let observer = AgentActivityObserver(codexRoot: root.appendingPathComponent("codex"),
            claudeRoot: root.appendingPathComponent("claude"))
        let agent = TaskSubtask(id: "archived", title: "Archived creator",
            provider: .codex, sessionID: sessionID)

        let found = await observer.transcriptURL(for: agent)
        #expect(found?.lastPathComponent == transcript.lastPathComponent)
        #expect(found.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test("Transcript polling reads only appended bytes and safely resets after truncation")
    func activityIncrementalReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-incremental-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("codex/sessions/2026/09/27")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let transcript = sessions.appendingPathComponent("rollout-first-\(sessionID).jsonl")
        let first = #"{"timestamp":"2026-09-15T18:00:00Z","type":"event_msg","payload":{"type":"task_complete","thread_id":"\#(sessionID)"}}"# + "\n"
        try Data(first.utf8).write(to: transcript)
        let agent = TaskSubtask(id: "worker", title: "Worker", provider: .codex, sessionID: sessionID)
        let observer = AgentActivityObserver(codexRoot: root.appendingPathComponent("codex"),
            claudeRoot: root.appendingPathComponent("claude"))

        #expect(try await observer.latest(for: agent)?.kind == .result)
        let initialBytes = await observer.bytesRead(for: agent)
        let appended = #"{"timestamp":"2026-09-15T18:01:00Z","type":"event_msg","payload":{"type":"turn_started","thread_id":"\#(sessionID)"}}"# + "\n"
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        #expect(try await observer.latest(for: agent)?.kind == .working)
        #expect(await observer.bytesRead(for: agent) - initialBytes == appended.utf8.count)
        _ = try await observer.latest(for: agent)
        #expect(await observer.bytesRead(for: agent) - initialBytes == appended.utf8.count)

        let partial = #"{"timestamp":"2026-09-15T18:01:30Z","type":"event_msg","payload":{"type":"turn_complete","thread_id":"\#(sessionID)","last_agent_message":"Partial result"}}"# + "\n"
        let split = partial.utf8.count / 2
        let partialData = Data(partial.utf8)
        let partialHandle = try FileHandle(forWritingTo: transcript)
        try partialHandle.seekToEnd()
        try partialHandle.write(contentsOf: partialData.prefix(split))
        try partialHandle.close()
        #expect(try await observer.latest(for: agent)?.kind == .working)
        let remainderHandle = try FileHandle(forWritingTo: transcript)
        try remainderHandle.seekToEnd()
        try remainderHandle.write(contentsOf: partialData.dropFirst(split))
        try remainderHandle.close()
        let completedPartial = try await observer.latest(for: agent)
        #expect(completedPartial?.kind == .result)
        #expect(completedPartial?.summary == "Partial result")

        let replacement = #"{"timestamp":"2026-09-15T18:02:00Z","type":"event_msg","payload":{"type":"turn_complete","thread_id":"\#(sessionID)"}}"# + "\n"
        try Data(replacement.utf8).write(to: transcript, options: .atomic)
        #expect(try await observer.latest(for: agent)?.kind == .result)

        try FileManager.default.removeItem(at: transcript)
        let relocated = sessions.appendingPathComponent("rollout-second-\(sessionID).jsonl")
        let relocatedLine = #"{"timestamp":"2026-09-15T18:03:00Z","type":"event_msg","payload":{"type":"turn_started","thread_id":"\#(sessionID)"}}"# + "\n"
        try Data(relocatedLine.utf8).write(to: relocated)
        #expect(try await observer.latest(for: agent)?.kind == .working)
    }

    @Test("Transcript polling detects truncate and regrow on the same inode")
    func activityIncrementalReadDetectsSameInodeRegrow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-regrow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("codex/sessions/2026/09/27")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let transcript = sessions.appendingPathComponent("rollout-regrow-\(sessionID).jsonl")
        let first = #"{"timestamp":"2026-09-15T18:00:00Z","type":"event_msg","payload":{"type":"turn_started","thread_id":"\#(sessionID)"}}"# + "\n"
        try Data(first.utf8).write(to: transcript)
        let agent = TaskSubtask(id: "worker", title: "Worker", provider: .codex, sessionID: sessionID)
        let observer = AgentActivityObserver(codexRoot: root.appendingPathComponent("codex"),
            claudeRoot: root.appendingPathComponent("claude"))
        #expect(try await observer.latest(for: agent)?.kind == .working)

        let inodeBefore = try FileManager.default.attributesOfItem(atPath: transcript.path)[.systemFileNumber]
        let replacement = #"{"timestamp":"2026-09-15T18:01:00Z","type":"event_msg","payload":{"type":"turn_complete","thread_id":"\#(sessionID)","last_agent_message":"Regrown result"}}"# + "\n"
            + String(repeating: #"{"timestamp":"2026-09-15T18:01:01Z","type":"ignored"}"# + "\n", count: 8)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.close()
        let inodeAfter = try FileManager.default.attributesOfItem(atPath: transcript.path)[.systemFileNumber]
        #expect(String(describing: inodeAfter) == String(describing: inodeBefore))
        #expect(replacement.utf8.count > first.utf8.count)

        let event = try await observer.latest(for: agent)
        #expect(event?.kind == .result)
        #expect(event?.summary == "Regrown result")
    }

    @Test("Transcript prompts are told apart from tool output and injected context")
    func transcriptPromptClassification() throws {
        let session = UUID().uuidString
        let claude = [
            #"{"timestamp":"2026-10-19T17:00:00Z","type":"user","sessionId":"\#(session)","uuid":"a","origin":{"kind":"human"},"message":{"role":"user","content":"Fix the panel"}}"#,
            #"{"timestamp":"2026-10-19T17:00:01Z","type":"user","sessionId":"\#(session)","uuid":"b","toolUseResult":{},"message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"timestamp":"2026-10-19T17:00:02Z","type":"user","sessionId":"\#(session)","uuid":"c","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>done</task-notification>"}}"#,
            #"{"timestamp":"2026-10-19T17:00:03Z","type":"user","sessionId":"\#(session)","uuid":"d","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued"}}"#,
            #"{"timestamp":"2026-10-19T17:00:04Z","type":"user","sessionId":"\#(session)","uuid":"e","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#,
            #"{"timestamp":"2026-10-19T17:00:05Z","type":"user","sessionId":"\#(session)","uuid":"f","isMeta":true,"message":{"role":"user","content":"Caveat"}}"#,
            #"{"timestamp":"2026-10-19T17:00:06Z","type":"user","sessionId":"\#(session)","uuid":"g","message":{"role":"user","content":[{"type":"image"},{"type":"text","text":"Legacy prompt"}]}}"#,
        ].joined(separator: "\n")
        let claudeKinds = AgentActivityEvent.events(in: Data(claude.utf8), provider: .claude, sessionID: session).map(\.kind)
        // Only tool output is in-turn work; notices, summaries, and command echoes are not.
        #expect(claudeKinds == [.prompt, .working, .prompt])

        let codex = [
            #"{"timestamp":"2026-10-19T17:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"AGENTS.md instructions"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["agents_md.instructions","environments.environment_context"]}}}"#,
            #"{"timestamp":"2026-10-19T17:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Ship it"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["user.text"]}}}"#,
            #"{"timestamp":"2026-10-19T17:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"Older format prompt"}}"#,
            #"{"timestamp":"2026-10-19T17:00:03Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        ].joined(separator: "\n")
        let codexKinds = AgentActivityEvent.events(in: Data(codex.utf8), provider: .codex, sessionID: session).map(\.kind)
        #expect(codexKinds == [.prompt, .prompt, .working])
    }

    @Test("Transcript polling keeps a prompt that later tool output follows in the same read")
    func activityPollingKeepsPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("claude/projects/-tmp-work")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let session = UUID().uuidString
        let lines = [
            #"{"timestamp":"2026-10-19T17:00:00Z","type":"user","sessionId":"\#(session)","uuid":"p","origin":{"kind":"human"},"message":{"role":"user","content":"Reorder tasks"}}"#,
            #"{"timestamp":"2026-10-19T17:00:05Z","type":"user","sessionId":"\#(session)","uuid":"t","toolUseResult":{},"message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: project.appendingPathComponent("\(session).jsonl"))
        let observer = AgentActivityObserver(codexRoot: root.appendingPathComponent("codex"),
            claudeRoot: root.appendingPathComponent("claude"))
        let events = try await observer.events(for: TaskSubtask(id: "worker", title: "Worker",
            provider: .claude, sessionID: session))
        let prompt = try #require(events.first { $0.kind == .prompt })
        #expect(prompt.date == ISO8601DateFormatter().date(from: "2026-10-19T17:00:00Z"))
        #expect(events.last?.kind == .working)
    }

    @Test("An observed prompt dates the task's last interaction without regressing it")
    func observedPromptRecordsInteraction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-700", title: "Task", status: "open", summary: ""))
        let agent = TaskSubtask(id: "worker", title: "Worker", sessionID: UUID().uuidString, status: .idle)
        _ = try await store.upsertSubtask(ticketID: "ECC-700", subtask: agent)
        let promptAt = Date(timeIntervalSinceReferenceDate: 1_000)

        let prompted = try await store.observeActivity(ticketID: "ECC-700", subtaskID: agent.id,
            event: .init(id: "prompt", date: promptAt, kind: .prompt, summary: ""))
        #expect(prompted.lastPromptAt == promptAt)
        #expect(prompted.subtasks.first?.lastPromptAt == promptAt)
        #expect(prompted.subtasks.first?.status == .working)

        let older = try await store.observeActivity(ticketID: "ECC-700", subtaskID: agent.id,
            event: .init(id: "older", date: promptAt.addingTimeInterval(-60), kind: .prompt, summary: ""))
        #expect(older.lastPromptAt == promptAt)
        #expect(older.subtasks.first?.lastPromptAt == promptAt)
        let toolOutput = try await store.observeActivity(ticketID: "ECC-700", subtaskID: agent.id,
            event: .init(id: "tool", date: promptAt.addingTimeInterval(30), kind: .working, summary: ""))
        #expect(toolOutput.lastPromptAt == promptAt)
        #expect(toolOutput.subtasks.first?.lastPromptAt == promptAt)

        let launchedAt = promptAt.addingTimeInterval(120)
        let launched = try await store.recordPrompt(ticketID: "ECC-700", subtaskID: agent.id, at: launchedAt)
        #expect(launched.subtasks.first?.lastPromptAt == launchedAt)
        let reloaded = try await TaskContextStore(root: root).load(ticketID: "ECC-700")
        #expect(reloaded?.subtasks.first?.lastPromptAt == launchedAt)
    }

    @Test("An older transcript result survives a newer registration heartbeat")
    func olderResultDoesNotRegressCurrentStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-700", title: "Task", status: "open", summary: ""))
        let heartbeat = Date(timeIntervalSinceReferenceDate: 500)
        let newerOutput = heartbeat.addingTimeInterval(10)
        var agent = TaskSubtask(id: "worker", title: "Worker", sessionID: UUID().uuidString,
            status: .working, lastHeartbeatAt: heartbeat, lastOutputAt: newerOutput)
        agent.progressSummary = "New prompt is running"
        _ = try await store.upsertSubtask(ticketID: "ECC-700", subtask: agent)

        let resultAt = heartbeat.addingTimeInterval(-10)
        let saved = try await store.observeActivity(ticketID: "ECC-700", subtaskID: agent.id,
            event: .init(id: "older-result", date: resultAt, kind: .result, summary: "Earlier answer"))
        let updated = try #require(saved.subtasks.first)
        #expect(updated.status == .working)
        #expect(updated.lastHeartbeatAt == heartbeat)
        #expect(updated.progressSummary == "New prompt is running")
        #expect(updated.lastOutputAt == newerOutput)
        #expect(updated.resultAt == resultAt)
        #expect(updated.resultSummary == "Earlier answer")
        #expect(updated.completionUnread)

        let olderWorking = AgentActivityEvent(id: "older-working",
            date: resultAt.addingTimeInterval(-1), kind: .working,
            summary: "Stale work summary")
        let preserved = try await store.observeActivity(
            ticketID: "ECC-700", subtaskID: agent.id, event: olderWorking)
        let unchanged = try #require(preserved.subtasks.first)
        #expect(unchanged.status == .working)
        #expect(unchanged.lastHeartbeatAt == heartbeat)
        #expect(unchanged.progressSummary == "New prompt is running")
        #expect(unchanged.lastOutputAt == newerOutput)
        #expect(unchanged.resultSummary == "Earlier answer")
    }

    @Test("Replaying an acknowledged result after newer activity stays acknowledged")
    func acknowledgedResultReplayStaysAcknowledged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-700", title: "Task", status: "open", summary: ""))
        let agent = TaskSubtask(
            id: "worker", title: "Worker", sessionID: UUID().uuidString)
        _ = try await store.upsertSubtask(ticketID: "ECC-700", subtask: agent)

        let result = AgentActivityEvent(
            id: "result-1", date: Date(timeIntervalSinceReferenceDate: 500),
            kind: .result, summary: "Ready")
        _ = try await store.observeActivity(
            ticketID: "ECC-700", subtaskID: agent.id, event: result)
        let working = AgentActivityEvent(
            id: "working-1", date: result.date.addingTimeInterval(1),
            kind: .working, summary: "Continuing")
        _ = try await store.observeActivity(
            ticketID: "ECC-700", subtaskID: agent.id, event: working)
        let acknowledged = try await store.acknowledgeCompletion(
            ticketID: "ECC-700", subtaskID: agent.id, expectedResultID: result.id)
        #expect(!acknowledged.subtasks[0].completionUnread)
        #expect(acknowledged.subtasks[0].observedEventID == working.id)

        let replayed = try await store.observeActivity(
            ticketID: "ECC-700", subtaskID: agent.id, event: result)
        #expect(!replayed.subtasks[0].completionUnread)
        #expect(replayed.subtasks[0].resultID == result.id)
        #expect(replayed.subtasks[0].observedEventID == working.id)
    }

    @Test("Legacy assignment separation preserves output time in both records")
    func legacySeparationPreservesOutputTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let ticket = DashboardTicket(id: "ECC-700", title: "Task", status: "open", summary: "")
        var context = try await store.ensureContext(ticket: ticket)
        let outputAt = Date(timeIntervalSinceReferenceDate: 456)
        var legacy = TaskSubtask(id: "legacy", title: "Legacy", sessionID: UUID().uuidString)
        legacy.lastOutputAt = outputAt
        context.schemaVersion = 1
        context.subtasks = [legacy]
        let contextURL = try await store.directory(ticketID: ticket.id).appendingPathComponent("context.json")
        try JSONEncoder().encode(context).write(to: contextURL, options: .atomic)

        let migrated = try await store.ensureContext(ticket: ticket)
        #expect(migrated.subtasks.count == 2)
        #expect(migrated.subtasks.allSatisfy { $0.lastOutputAt == outputAt })
    }

    @Test("Both prompt modes preserve the initial instruction and compact mode includes task pointers")
    func promptPreview() throws {
        let context = context()
        var agent = TaskSubtask(title: "Fix issue", includeInitializationPrompt: false)
        agent.initialPrompt = "My exact first instruction\nWith a second line"
        agent.workspace = AgentWorkspace(path: "/tmp/repo", repositoryPath: "/tmp/repo")
        #expect(context.agentPrompt(subtask: agent).hasPrefix(agent.initialPrompt! + "\n\n"))
        let command = try TaskAgentLauncher.command(context: context, subtask: agent, supportDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(command.last == context.agentBootstrap(subtask: agent))
        #expect(command.last?.hasPrefix(agent.initialPrompt! + "\n\n") == true)
        #expect(command.last?.contains(context.planPath) == true)
        #expect(command.last?.contains(context.agentLogURL.path) == true)
        #expect(!command.contains(context.agentPrompt(subtask: agent)))
    }

    @Test("Review completion closes child work; reopening a completed runtime does not restart the assignment")
    func reviewedCompletionAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-700", title: "Task", status: "open", summary: ""))
        var parent = TaskSubtask(id: "parent", title: "Assignment")
        parent.isAssignmentOnly = true
        var child = TaskSubtask(id: "child", title: "Agent", status: .working, lastHeartbeatAt: Date())
        child.parentSubtaskID = parent.id; child.tracksCompletion = false
        _ = try await store.upsertSubtask(ticketID: "ECC-700", subtask: parent)
        _ = try await store.upsertSubtask(ticketID: "ECC-700", subtask: child)
        let complete = try await store.updateProgress(ticketID: "ECC-700", subtaskID: parent.id, status: .completed, summary: "Reviewed")
        #expect(complete.subtasks.allSatisfy { $0.status == .completed })
        #expect(!complete.subtasks[0].completionUnread)
        #expect(complete.canAutomaticallyRetire(complete.subtasks[1]))
        _ = try await store.removeAgent(ticketID: "ECC-700", subtaskID: child.id, automatically: true)
        let reopened = try await store.restoreAgent(ticketID: "ECC-700", subtaskID: child.id)
        #expect(!reopened.canAutomaticallyRetire(reopened.subtasks[1]))
        let afterEvent = try await store.observeActivity(ticketID: "ECC-700", subtaskID: child.id,
            event: .init(id: "reopened-turn", date: Date().addingTimeInterval(1), kind: .working, summary: "Resumed"))
        #expect(afterEvent.subtasks.allSatisfy { $0.status == .completed })
    }

    @Test("Durable library correlates a native session with its assignment, independently of the runtime record")
    func durableAssociations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-700", title: "Task", status: "open", summary: ""))
        var parent = TaskSubtask(id: "parent", title: "Assignment")
        parent.isAssignmentOnly = true
        var child = TaskSubtask(id: "child", title: "Agent", sessionID: UUID().uuidString)
        child.parentSubtaskID = parent.id; child.tracksCompletion = false
        // Child-first input also works; the library resolves IDs after creating all entries.
        _ = try await store.upsertSubtask(ticketID: "ECC-700", subtask: child)
        let context = try await store.upsertSubtask(ticketID: "ECC-700", subtask: parent)
        let library = DurableLibraryStore(root: root)
        _ = try await library.reconcile(contexts: [context])
        let snapshot = try await library.snapshot()
        let task = try #require(snapshot.tasks.first)
        let assignmentID = try #require(task.subtasks.first { $0.legacyID == parent.id }?.id)
        #expect(task.subtasks.filter(\.isCurrent).map(\.id) == [assignmentID])
        #expect(snapshot.assignments.contains { $0.subtaskID == assignmentID && $0.source == "task-context" && $0.isCurrent })
        #expect(snapshot.sessions.first?.nativeSessionID == child.sessionID)
    }

    @Test("A cleaned managed workspace resumes at the exact saved path and retained branch")
    func restoreWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = FoundationProcessRunner()
        for args in [["init", "-q", "-b", "main"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"]] {
            #expect(try await git.run(.init(executable: "/usr/bin/git", arguments: args, workingDirectory: repo.path)).succeeded)
        }
        let store = TaskContextStore(root: root.appendingPathComponent("support"))
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-700", title: "Task", status: "open", summary: ""))
        let manager = TaskWorktreeManager()
        let id = UUID().uuidString
        let saved = try await manager.provisionAgent(ticketID: "ECC-700", subtaskID: id, path: repo.path, createWorktree: true, store: store)
        var agent = TaskSubtask(id: id, title: "Completed", status: .completed)
        agent.workspace = saved
        #expect(try await manager.cleanupAgent(ticketID: "ECC-700", subtask: agent, store: store).removed)
        try await manager.restoreIfNeeded(saved, ticketID: "ECC-700", subtaskID: id, store: store)
        let restored = try await manager.workspace(at: saved.path)
        #expect(restored.path == saved.path)
        #expect(restored.branch == saved.branch)
        #expect(restored.baseCommit == saved.baseCommit)
        try await manager.validate(saved)
    }
}
