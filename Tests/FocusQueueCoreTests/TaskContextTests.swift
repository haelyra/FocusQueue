import Foundation
import Testing
@testable import FocusQueueCore

private func contextFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("focus-context-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func contextTicket(id: String = "ECC-901", worktree: String? = nil) -> DashboardTicket {
    DashboardTicket(id: id, title: "Preserve task context", status: "in-progress", summary: "Keep one canonical plan across agents.",
                    doneWhen: "The context survives worktree cleanup.", worktree: worktree,
                    links: [.init(label: "Supporting canvas", url: "https://example.com/plan")],
                    steps: [.init(id: "verify", label: "Verify archival", status: "pending")])
}

@Test("Switching a terminal task cannot bind the previous task's subtask")
func taskContextSessionBinding() {
    let environment = ["FOCUS_QUEUE_TASK_ID": "ECC-901", "FOCUS_QUEUE_SUBTASK_ID": "archive"]
    #expect(TaskSessionBinding.subtaskID(ticketID: "ecc-901", environment: environment) == "archive")
    #expect(TaskSessionBinding.subtaskID(ticketID: "ECC-902", environment: environment) == nil)
    #expect(TaskSessionBinding.subtaskID(ticketID: "ECC-901", environment: [:]) == nil)
    let nested = ["CODEX_THREAD_ID": "codex-id", "CLAUDE_SESSION_ID": "claude-id", "FOCUS_QUEUE_PROVIDER": "claude"]
    #expect(TaskSessionBinding.providerSession(environment: nested)?.0 == .claude)
    #expect(TaskSessionBinding.providerSession(environment: nested)?.1 == "claude-id")
    #expect(TaskSessionBinding.providerSession(environment: ["CODEX_THREAD_ID": "codex-id", "CLAUDE_SESSION_ID": "claude-id"]) == nil)
}

@Test("Task context preserves edited plans, detects save conflicts, and snapshots previous content")
func taskContextPlanPreservation() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let first = try await store.ensureContext(ticket: contextTicket())
    let original = try await store.readPlan(ticketID: first.ticketID)
    #expect(original.contains("Verify archival"))
    #expect(original.contains("Supporting canvas"))
    let prompt = first.agentPrompt(subtask: .init(id: "archive", title: "Archive verification"))
    #expect(prompt.contains("FOCUS_QUEUE_SUBTASK_ID=archive"))
    #expect(prompt.contains("FOCUS_QUEUE_SUPPORT_DIR="))
    try await store.savePlan(ticketID: first.ticketID, markdown: "# Updated by agent\n", expectedMarkdown: original)
    _ = try await store.ensureContext(ticket: contextTicket())
    #expect(try await store.readPlan(ticketID: first.ticketID) == "# Updated by agent\n")
    do {
        try await store.savePlan(ticketID: first.ticketID, markdown: "stale user draft", expectedMarkdown: original)
        Issue.record("A stale edit must report a conflict")
    } catch TaskContextError.planConflict {}
    let archives = try FileManager.default.contentsOfDirectory(at: first.contextDirectory.appendingPathComponent("archive"), includingPropertiesForKeys: nil)
    #expect(archives.count == 2)
    let savedPlans = try archives.map { try String(contentsOf: $0.appendingPathComponent("plan.md"), encoding: .utf8) }
    #expect(savedPlans.contains(original))
    #expect(savedPlans.contains("# Updated by agent\n"))
}

@Test("Task context rejects path traversal and supports case-insensitive task IDs")
func taskContextIdentifierValidation() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    _ = try await store.ensureContext(ticket: contextTicket())
    #expect(try await store.load(ticketID: "ecc-901")?.ticketID == "ECC-901")
    for invalid in ["../elsewhere", "", "ECC/901", ".", "ECC 901"] {
        do { _ = try await store.directory(ticketID: invalid); Issue.record("Unsafe ID accepted: \(invalid)") }
        catch TaskContextError.invalidIdentifier {}
    }
}

@Test("Working activity expires, while completion remains visible until acknowledged")
func taskContextProgressAndHeartbeat() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    _ = try await store.ensureContext(ticket: contextTicket())
    _ = try await store.upsertSubtask(ticketID: "ECC-901", subtask: .init(id: "archive", title: "Archive verification"))
    let now = Date(timeIntervalSince1970: 1_000)
    var context = try await store.updateProgress(ticketID: "ECC-901", subtaskID: "archive", status: .working,
                                                 summary: "Running the archival check", sessionID: "session-123", now: now)
    #expect(context.subtasks[0].sessionID == "session-123")
    #expect(context.subtasks[0].effectiveStatus(now: now.addingTimeInterval(299)) == .working)
    #expect(context.subtasks[0].effectiveStatus(now: now.addingTimeInterval(301)) == .idle)
    context = try await store.updateProgress(ticketID: "ECC-901", subtaskID: "archive", status: .completed, summary: "Check passed")
    #expect(context.subtasks[0].completionUnread)
    #expect(context.subtasks[0].effectiveStatus(now: now.addingTimeInterval(10_000)) == .completed)
    context = try await store.acknowledgeCompletion(ticketID: "ECC-901", subtaskID: "archive")
    #expect(!context.subtasks[0].completionUnread)
    context = try await store.renameSubtask(ticketID: "ECC-901", subtaskID: "archive", title: "  Durable archival  ")
    #expect(context.subtasks[0].title == "Durable archival")
    #expect(context.subtasks[0].sessionID == "session-123")
    #expect(context.subtasks[0].status == .completed)
}

@Test("Managed runtime is durable and clearing the queue archives before removal")
func taskContextManagedRuntimeAndClear() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let initial = try await store.ensureContext(ticket: contextTicket())
    _ = try await store.upsertSubtask(
        ticketID: initial.ticketID,
        subtask: .init(id: "implement-recall", title: "Implement durable session recall"))
    let runtime = try #require(TmuxController.decode(
        "fq-implement-recall\t123\t1000\t%0\t124\t/dev/ttys099\t0\n",
        executable: "/opt/homebrew/bin/tmux").first)

    let managed = try await store.setManagedRuntime(
        ticketID: initial.ticketID, subtaskID: "implement-recall", tmux: runtime)
    #expect(managed.subtasks[0].tmux == runtime)
    #expect(managed.subtasks[0].status == .working)
    #expect(try await store.load(ticketID: initial.ticketID)?.subtasks[0].tmux == runtime)

    let cleared = try await store.clearSubtasks(ticketID: initial.ticketID)
    #expect(cleared.subtasks.isEmpty)
    #expect(try await store.load(ticketID: initial.ticketID)?.subtasks.isEmpty == true)
    let archive = initial.contextDirectory.appendingPathComponent("archive")
    let snapshots = try FileManager.default.contentsOfDirectory(
        at: archive, includingPropertiesForKeys: nil)
    #expect(try snapshots.contains { snapshot in
        let saved = try JSONDecoder().decode(
            TaskContext.self,
            from: Data(contentsOf: snapshot.appendingPathComponent("context.json")))
        return saved.subtasks.contains { $0.tmux == runtime }
    })
}

@Test("Removing one subtask preserves its siblings and archives the removed assignment")
func taskContextSingleSubtaskRemoval() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let initial = try await store.ensureContext(ticket: contextTicket())
    _ = try await store.upsertSubtask(
        ticketID: initial.ticketID,
        subtask: .init(id: "remove-me", title: "Old agent", status: .idle))
    _ = try await store.upsertSubtask(
        ticketID: initial.ticketID,
        subtask: .init(id: "keep-me", title: "Current agent", status: .working))

    let updated = try await store.removeSubtask(
        ticketID: initial.ticketID, subtaskID: "remove-me")

    #expect(updated.subtasks.map(\.id) == ["keep-me"])
    let snapshots = try FileManager.default.contentsOfDirectory(
        at: initial.contextDirectory.appendingPathComponent("archive"),
        includingPropertiesForKeys: nil)
    #expect(try snapshots.contains { snapshot in
        let saved = try JSONDecoder().decode(
            TaskContext.self,
            from: Data(contentsOf: snapshot.appendingPathComponent("context.json")))
        return saved.subtasks.contains { $0.id == "remove-me" }
            && saved.subtasks.contains { $0.id == "keep-me" }
    })
}

@Test("Direct runtime persists only its exact terminal identity")
func taskContextDirectRuntime() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let initial = try await store.ensureContext(ticket: contextTicket())
    _ = try await store.upsertSubtask(
        ticketID: initial.ticketID,
        subtask: .init(id: "direct", title: "Run in the terminal", runtimeMode: .terminal))

    let direct = try await store.setDirectRuntime(
        ticketID: initial.ticketID, subtaskID: "direct",
        paneID: 42, socketPath: "/tmp/wezterm-focus.sock")
    let subtask = try #require(direct.subtasks.first)
    #expect(subtask.runtimeMode == .terminal)
    #expect(subtask.terminalPaneID == 42)
    #expect(subtask.terminalSocketPath == "/tmp/wezterm-focus.sock")
    #expect(subtask.tmux == nil)
    #expect(subtask.status == .working)

    let saved = try #require(
        try await store.load(ticketID: initial.ticketID)?.subtasks.first)
    #expect(saved == subtask)
}

@Test("Independent stores preserve concurrent named-subtask updates")
func taskContextConcurrentUpdates() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let first = TaskContextStore(root: root), second = TaskContextStore(root: root)
    _ = try await first.ensureContext(ticket: contextTicket())
    async let one = first.upsertSubtask(ticketID: "ECC-901", subtask: .init(id: "one", title: "First agent"))
    async let two = second.upsertSubtask(ticketID: "ECC-901", subtask: .init(id: "two", title: "Second agent"))
    _ = try await (one, two)
    #expect(try await first.load(ticketID: "ECC-901")?.subtasks.count == 2)
}

@Test("Shared repositories receive separate task context pointers")
func taskContextReferences() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let store = TaskContextStore(root: root)
    for id in ["ECC-901", "ECC-902"] {
        let context = try await store.ensureContext(ticket: contextTicket(id: id, worktree: workspace.path))
        try await store.installWorktreeReference(ticketID: id)
        let reference = workspace.appendingPathComponent(".focus-queue/\(id)/plan.md")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: reference.path) == context.planPath)
    }
}

private func runFixtureGit(_ arguments: [String], in directory: URL) async throws -> String {
    let result = try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git", arguments: arguments,
                                                              workingDirectory: directory.path))
    guard result.succeeded else { throw TaskContextError.commandFailed(result.standardError) }
    return result.standardOutput
}

@Test("Managed worktrees refuse dirty and unmerged cleanup, then archive before clean merged removal")
func taskContextWorktreeLifecycle() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    _ = try await runFixtureGit(["init", "-b", "main"], in: repository)
    _ = try await runFixtureGit(["config", "user.email", "test@example.com"], in: repository)
    _ = try await runFixtureGit(["config", "user.name", "Focus Queue Test"], in: repository)
    _ = try await runFixtureGit(["commit", "--allow-empty", "-m", "Initial"], in: repository)
    let store = TaskContextStore(root: root.appendingPathComponent("support"))
    let manager = TaskWorktreeManager()
    let context = try await manager.provision(ticket: contextTicket(worktree: repository.path), repositoryPath: repository.path, store: store)
    let workspace = URL(fileURLWithPath: try #require(context.worktreePath))
    #expect(workspace != repository)
    #expect(context.managedWorktree)
    #expect(try await runFixtureGit(["status", "--porcelain"], in: workspace).isEmpty)
    _ = try await store.upsertSubtask(ticketID: context.ticketID, subtask: .init(id: "verify", title: "Verify cleanup"))
    let pending = try await manager.cleanup(ticketID: context.ticketID, store: store)
    #expect(!pending.removed)
    #expect(pending.message.contains("still open"))
    _ = try await store.updateProgress(ticketID: context.ticketID, subtaskID: "verify", status: .completed, summary: "Ready")
    let ignoredFile = workspace.appendingPathComponent(".focus-queue/private-notes.txt")
    try Data("Preserve user notes".utf8).write(to: ignoredFile)
    let ignored = try await manager.cleanup(ticketID: context.ticketID, store: store)
    #expect(!ignored.removed)
    #expect(ignored.message.contains("ignored files"))
    try FileManager.default.removeItem(at: ignoredFile)
    let changedFile = workspace.appendingPathComponent("implementation.txt")
    try Data("task implementation".utf8).write(to: changedFile)
    let dirty = try await manager.cleanup(ticketID: context.ticketID, store: store)
    #expect(!dirty.removed)
    #expect(dirty.message.contains("uncommitted"))
    _ = try await runFixtureGit(["add", "implementation.txt"], in: workspace)
    _ = try await runFixtureGit(["commit", "-m", "Task implementation"], in: workspace)
    let unmerged = try await manager.cleanup(ticketID: context.ticketID, store: store)
    #expect(!unmerged.removed)
    #expect(unmerged.message.contains("commits absent"))
    _ = try await runFixtureGit(["merge", "--ff-only", try #require(context.branch)], in: repository)
    try Data("# Final agent handoff\n".utf8).write(to: URL(fileURLWithPath: context.planPath), options: .atomic)
    let removed = try await manager.cleanup(ticketID: context.ticketID, store: store)
    #expect(removed.removed)
    #expect(!FileManager.default.fileExists(atPath: workspace.path))
    #expect(try await store.readPlan(ticketID: context.ticketID) == "# Final agent handoff\n")
    let archives = try FileManager.default.contentsOfDirectory(at: context.contextDirectory.appendingPathComponent("archive"), includingPropertiesForKeys: nil)
    #expect(archives.count >= 2)
    #expect(try archives.contains { try String(contentsOf: $0.appendingPathComponent("plan.md"), encoding: .utf8) == "# Final agent handoff\n" })
    #expect(try await store.load(ticketID: context.ticketID)?.worktreePath == nil)
    let refreshed = try await store.ensureContext(ticket: contextTicket(worktree: repository.path))
    #expect(refreshed.worktreePath == nil)
    let reopened = try await manager.provision(ticket: contextTicket(worktree: repository.path), repositoryPath: repository.path, store: store)
    #expect(reopened.worktreePath == workspace.path)
    #expect(reopened.managedWorktree)
    #expect(try await store.readPlan(ticketID: context.ticketID) == "# Final agent handoff\n")
}

@Test("Existing user workspaces are archived and retained")
func taskContextPreservesUnmanagedWorktree() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    _ = try await store.ensureContext(ticket: contextTicket(worktree: root.path))
    let result = try await TaskWorktreeManager().cleanup(ticketID: "ECC-901", store: store)
    #expect(!result.removed)
    #expect(FileManager.default.fileExists(atPath: root.path))
}

@Test("Cleanup of an already missing managed worktree preserves context and resets ownership")
func taskContextMissingWorktreeCleanup() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    _ = try await store.ensureContext(ticket: contextTicket())
    let path = root.resolvingSymlinksInPath().appendingPathComponent("worktrees/ECC-901").path
    _ = try await store.setWorktree(ticketID: "ECC-901", path: path, branch: "focus-queue/ecc-901", baseBranch: "main", managed: true, repositoryPath: root.path)
    let result = try await TaskWorktreeManager().cleanup(ticketID: "ECC-901", store: store)
    #expect(result.removed)
    #expect(result.message.contains("already removed"))
    #expect(try await store.load(ticketID: "ECC-901")?.managedWorktree == false)
    #expect(try await store.load(ticketID: "ECC-901")?.worktreePath == nil)
}

@Test("Initial context and direct agent edits have independent backups without heartbeat churn")
func taskContextDirectEditsAreArchivedOnProgress() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let context = try await store.ensureContext(ticket: contextTicket())
    let archive = context.contextDirectory.appendingPathComponent("archive")
    #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).count == 1)
    _ = try await store.upsertSubtask(ticketID: context.ticketID, subtask: .init(id: "verify", title: "Verify backup"))
    try Data("# Direct agent edit\nDurable handoff.".utf8).write(to: URL(fileURLWithPath: context.planPath), options: .atomic)
    _ = try await store.updateProgress(ticketID: context.ticketID, subtaskID: "verify", status: .working, summary: "Recorded handoff", now: Date(timeIntervalSince1970: 100))
    let beforeHeartbeat = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
    #expect(beforeHeartbeat.count == 2)
    #expect(try beforeHeartbeat.contains { try String(contentsOf: $0.appendingPathComponent("plan.md"), encoding: .utf8) == "# Direct agent edit\nDurable handoff." })
    _ = try await store.updateProgress(ticketID: context.ticketID, subtaskID: "verify", status: .working, summary: "Recorded handoff", now: Date(timeIntervalSince1970: 200))
    #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).count == 2)
    let completed = try await store.updateProgress(ticketID: context.ticketID, subtaskID: "verify", status: .completed, summary: "Backup verified")
    let prompt = completed.agentPrompt(subtask: completed.subtasks[0])
    #expect(prompt.contains("await new user instructions"))
    #expect(!prompt.contains(" working \"short progress summary\""))
    _ = try await store.acknowledgeCompletion(ticketID: context.ticketID, subtaskID: "verify")
    let reattached = try await store.attachSubtask(ticketID: context.ticketID, subtaskID: "verify", provider: .codex, sessionID: "resumed-session")
    #expect(reattached.subtasks[0].status == .completed)
    #expect(reattached.subtasks[0].progressSummary == "Backup verified")
    #expect(!reattached.subtasks[0].completionUnread)
}

@Test("Task plan archive retains at most 100 distinct snapshots")
func taskContextArchiveRetention() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let context = try await store.ensureContext(ticket: contextTicket())
    _ = try await store.upsertSubtask(ticketID: context.ticketID, subtask: .init(id: "verify", title: "Verify retention"))
    for revision in 0..<103 {
        _ = try await store.updateProgress(ticketID: context.ticketID, subtaskID: "verify", status: .working, summary: "Revision \(revision)")
    }
    let archive = context.contextDirectory.appendingPathComponent("archive")
    #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).count == 100)
}
