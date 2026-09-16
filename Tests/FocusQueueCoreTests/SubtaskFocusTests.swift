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
        _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: legacy)

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

    @Test("Initialization starts with the initial prompt; disabling it sends only that prompt")
    func promptPreview() throws {
        let context = context()
        var agent = TaskSubtask(title: "Fix issue", includeInitializationPrompt: false)
        agent.initialPrompt = "My exact first instruction\nWith a second line"
        agent.workspace = AgentWorkspace(path: "/tmp/repo", repositoryPath: "/tmp/repo")
        #expect(context.agentPrompt(subtask: agent).hasPrefix(agent.initialPrompt! + "\n\n"))
        let command = try TaskAgentLauncher.command(context: context, subtask: agent, supportDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(command.last == agent.initialPrompt)
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
        try await manager.restoreIfNeeded(saved, subtaskID: id, store: store)
        let restored = try await manager.workspace(at: saved.path)
        #expect(restored.path == saved.path)
        #expect(restored.branch == saved.branch)
        #expect(restored.baseCommit == saved.baseCommit)
        try await manager.validate(saved)
    }
}
