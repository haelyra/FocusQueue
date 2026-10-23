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
    let codexChild = [
        "CODEX_THREAD_ID": "child-thread",
        "CODEX_SESSION_ID": "inherited-root",
        "FOCUS_QUEUE_PROVIDER": "codex",
    ]
    #expect(TaskSessionBinding.providerSession(environment: codexChild)?.1 == "child-thread")
    // Claude Code exports only CLAUDE_CODE_SESSION_ID; an explicit CLAUDE_SESSION_ID still wins.
    let claudeCode = ["CLAUDE_CODE_SESSION_ID": "058b670e-47d1-45ff-8c02-788059d047cf"]
    #expect(TaskSessionBinding.providerSession(environment: claudeCode)?.0 == .claude)
    #expect(TaskSessionBinding.providerSession(environment: claudeCode)?.1 == "058b670e-47d1-45ff-8c02-788059d047cf")
    #expect(TaskSessionBinding.providerSession(
        environment: claudeCode.merging(["CLAUDE_SESSION_ID": "explicit-id"]) { $1 })?.1 == "explicit-id")
    #expect(TaskSessionBinding.providerSession(
        environment: claudeCode.merging(["CODEX_THREAD_ID": "codex-id"]) { $1 }) == nil)
    #expect(TaskSessionBinding.providerSession(
        environment: claudeCode.merging(["CODEX_THREAD_ID": "codex-id", "FOCUS_QUEUE_PROVIDER": "codex"]) { $1 })?.1 == "codex-id")
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
    #expect(prompt.contains("Agent archive (codex)"))
    #expect(prompt.contains("- [ ] Verify archival"))
    #expect(!prompt.contains("FOCUS_QUEUE_SUPPORT_DIR="))
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
    context = try await store.renameSubtask(
        ticketID: "ECC-901", subtaskID: "archive", title: "  Durable archival  ",
        assignmentDescription: "  Retain the full completion evidence.  ")
    #expect(context.subtasks[0].title == "Durable archival")
    #expect(context.subtasks[0].assignmentDescription == "Retain the full completion evidence.")
    #expect(context.subtasks[0].sessionID == "session-123")
    #expect(context.subtasks[0].status == .completed)
}

@Test("Generated agent names read like short titles instead of clipped prompt sentences")
func generatedAgentNamesAreReadableTitles() {
    #expect(TaskSubtask.agentName(
        prompt: "Please investigate the subtask title delay and prevent it from happening again.",
        provider: .codex) == "Investigate the subtask title delay")
    #expect(TaskSubtask.agentName(
        prompt: "## Restore agent icons.\nThen verify both providers remain easy to identify.",
        provider: .claude) == "Restore agent icons")
    #expect(TaskSubtask.agentName(
        prompt: "Audit ECC035 iOS and tmux integration across provider sessions before release",
        provider: .codex) == "Audit ECC035 iOS and tmux integration")
    #expect(TaskSubtask.agentName(prompt: "iOS crash recovery", provider: .codex) == "iOS crash recovery")
    #expect(TaskSubtask.agentName(prompt: "tmux session recovery", provider: .codex) == "tmux session recovery")
    #expect(TaskSubtask.agentName(prompt: "  \n  ", provider: .claude) == "Blank Claude agent")
    #expect(TaskSubtask.agentName(prompt: "!!!", provider: .claude) == "Untitled Claude task")
}

@Test("Generated agent names use word boundaries when available")
func generatedAgentNamesRespectWordBoundaries() {
    let prompt = "Implement extraordinarilylongcomponentname with careful migration checks and verification"
    let title = TaskSubtask.agentName(prompt: prompt, provider: .codex)
    #expect(title.count <= 56)
    #expect(prompt.hasPrefix(title))
    #expect(!title.hasSuffix("extraordinarilylongcom"))
    #expect(!title.hasSuffix("caref"))
    let unbroken = TaskSubtask.agentName(prompt: String(repeating: "x", count: 90), provider: .codex)
    #expect(!unbroken.isEmpty)
    #expect(unbroken != "Blank Codex agent")
    #expect(unbroken.count == 56)
}

@Test("Generated agent descriptions keep one brief sentence")
func generatedAgentDescriptionsAreBrief() {
    #expect(TaskSubtask.agentDescription(
        prompt: "Please repair promptless startup. Then verify the existing session still opens."
    ) == "Please repair promptless startup.")
    let long = TaskSubtask.agentDescription(prompt: String(repeating: "word ", count: 100))
    #expect(long.count <= 240)
    #expect(long.hasSuffix("…"))
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
        ticketID: initial.ticketID, subtaskID: "implement-recall", tmux: runtime, status: .working)
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

@Test("A tracked launch can safely initialize an existing task directory with missing context")
func taskContextTrackedLaunchInitialization() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let directory = root.appendingPathComponent("tasks/ECC-404")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let initialized = try #require(try await store.ensureTrackedLaunchContext(
        ticketID: "ECC-404", title: "Recovered tracked launch"))

    #expect(initialized.ticketID == "ECC-404")
    #expect(initialized.title == "Recovered tracked launch")
    #expect(FileManager.default.fileExists(atPath: initialized.planPath))
    #expect(FileManager.default.fileExists(atPath: initialized.agentLogURL.path))
    #expect(try await store.ensureTrackedLaunchContext(
        ticketID: "ECC-405", title: "Must not create an unknown task") == nil)
}

@Test("Archiving a provisional launch preserves it and records its launch identity tombstone")
func provisionalLaunchArchiveTombstone() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let initial = try await store.ensureContext(ticket: contextTicket())
    let launchID = UUID().uuidString.lowercased()
    _ = try await store.upsertSubtask(ticketID: initial.ticketID,
        subtask: .init(id: launchID, title: "Provisional", status: .working))

    let archived = try await store.archiveAgent(ticketID: initial.ticketID,
        subtaskID: launchID)

    #expect(archived.subtasks.first?.agentRemovedAt != nil)
    #expect(archived.hasDismissedLaunch(launchID))
    #expect(archived.taskItems.isEmpty)
    let registered = try await store.registerExternalSession(
        ticketID: initial.ticketID, provider: .codex,
        sessionID: UUID().uuidString.lowercased(), title: "Late discovery",
        cwd: root.path, preferredSubtaskID: launchID,
        allowFreshAssociation: true, tmux: nil, paneID: nil,
        socketPath: nil, eventName: "ProcessDiscovery")
    #expect(registered.subtasks.count == 1)
    #expect(registered.subtasks[0].agentRemovedAt != nil)
    #expect(registered.subtasks[0].sessionID == nil)

    let restored = try await store.restoreAgent(
        ticketID: initial.ticketID, subtaskID: launchID)
    #expect(restored.subtasks[0].agentRemovedAt == nil)
    #expect(restored.subtasks[0].id == launchID)
    #expect(restored.taskItems.map(\.id) == [launchID])
}

@Test("Deleting an assignment removes only exclusive agents and reparents shared agents")
func taskContextAssignmentRemoval() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let initial = try await store.ensureContext(ticket: contextTicket())
    var first = TaskSubtask(id: "first", title: "First assignment", runtimeMode: nil)
    first.isAssignmentOnly = true
    var second = TaskSubtask(id: "second", title: "Second assignment", runtimeMode: nil)
    second.isAssignmentOnly = true
    var exclusive = TaskSubtask(id: "exclusive", title: "Exclusive agent")
    exclusive.parentSubtaskID = first.id
    var shared = TaskSubtask(id: "shared", title: "Shared agent")
    shared.parentSubtaskID = first.id
    shared.associatedSubtaskIDs = [second.id]
    for subtask in [first, second, exclusive, shared] {
        _ = try await store.upsertSubtask(ticketID: initial.ticketID, subtask: subtask)
    }

    let updated = try await store.removeSubtask(
        ticketID: initial.ticketID, subtaskID: first.id)

    #expect(updated.subtasks.map(\.id) == [second.id, shared.id])
    let retained = try #require(updated.subtasks.first { $0.id == shared.id })
    #expect(retained.parentSubtaskID == second.id)
    #expect(retained.associatedSubtaskIDs.isEmpty)
}

@Test("Legacy assignment and agent pairs present as one titled described work item")
func taskContextUnifiedWorkItems() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let initial = try await store.ensureContext(ticket: contextTicket())
    var assignment = TaskSubtask(
        id: "assignment", title: "Compact task layout",
        assignmentDescription: "Keep every task in one four-pane tmux window.", runtimeMode: nil)
    assignment.isAssignmentOnly = true
    var agent = TaskSubtask(
        id: "agent", title: "Codex · abc123", sessionID: UUID().uuidString, status: .working)
    agent.parentSubtaskID = assignment.id
    agent.tracksCompletion = false
    _ = try await store.upsertSubtask(ticketID: initial.ticketID, subtask: assignment)
    let context = try await store.upsertSubtask(ticketID: initial.ticketID, subtask: agent)

    #expect(context.taskItems.count == 1)
    let item = try #require(context.taskItems.first)
    #expect(item.id == agent.id)
    #expect(item.title == assignment.title)
    #expect(item.workDescription == assignment.assignmentDescription)
}

@Test("A combined root and its linked child both remain accessible in the unified list")
func taskContextUnifiedCombinedRoot() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let initial = try await store.ensureContext(ticket: contextTicket())
    var combined = TaskSubtask(
        id: "combined", title: "Primary agent",
        assignmentDescription: "Implement the primary task layout.",
        sessionID: UUID().uuidString, status: .working)
    combined.workspace = AgentWorkspace(
        path: "/tmp/primary", repositoryPath: "/tmp/repository", branch: "primary")
    var child = TaskSubtask(
        id: "linked", title: "Verification agent",
        assignmentDescription: "Verify pane recall without changing ownership.",
        provider: .claude, sessionID: UUID().uuidString, status: .working)
    child.parentSubtaskID = combined.id
    child.workspace = AgentWorkspace(
        path: "/tmp/verification", repositoryPath: "/tmp/repository", branch: "verification")
    _ = try await store.upsertSubtask(ticketID: initial.ticketID, subtask: combined)
    let context = try await store.upsertSubtask(ticketID: initial.ticketID, subtask: child)

    #expect(context.taskItems.map(\.id) == [combined.id, child.id])
    #expect(context.taskItems.map { $0.workspace?.path } == ["/tmp/primary", "/tmp/verification"])
    #expect(context.agents(for: combined.id).map(\.id) == [combined.id, child.id])
    #expect(context.subtasks.first { $0.id == child.id }?.parentSubtaskID == combined.id)
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
        paneID: 42, socketPath: "/tmp/wezterm-focus.sock", status: .working)
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
    let repository = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    _ = try await runFixtureGit(["init", "-b", "main"], in: repository)
    _ = try await runFixtureGit(["config", "user.email", "test@example.com"], in: repository)
    _ = try await runFixtureGit(["config", "user.name", "Focus Queue Test"], in: repository)
    _ = try await runFixtureGit(["commit", "--allow-empty", "-m", "Initial"], in: repository)
    let store = TaskContextStore(root: root.appendingPathComponent("support"))
    let manager = TaskWorktreeManager()
    let context = try await manager.provision(
        ticket: contextTicket(worktree: repository.path),
        repositoryPath: repository.path, store: store)
    let path = try #require(context.worktreePath)
    _ = try await runFixtureGit(["worktree", "remove", path], in: repository)
    let result = try await manager.cleanup(ticketID: "ECC-901", store: store)
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

// MARK: - Stale agent cleanup predicate

private func staleFixture(
    status: TaskSubtaskStatus = .idle,
    attention: AgentAttention? = nil,
    heartbeat: Date? = nil
) -> TaskSubtask {
    var agent = TaskSubtask(
        id: "stale-\(UUID().uuidString)", title: "Fixture agent",
        sessionID: UUID().uuidString, status: status, lastHeartbeatAt: heartbeat)
    agent.attention = attention
    return agent
}

@Test("Interrupted agent with no recent activity is a stale cleanup candidate")
func staleAgentInterruptedMatches() {
    let now = Date()
    let agent = staleFixture(status: .idle, attention: .interrupted,
        heartbeat: now.addingTimeInterval(-6 * 24 * 60 * 60))
    #expect(agent.isStaleAgentCandidate(now: now))
}

@Test("Idle agent with seen output and no recent activity is a stale cleanup candidate")
func staleAgentIdleSeenMatches() {
    let now = Date()
    let agent = staleFixture(status: .idle,
        heartbeat: now.addingTimeInterval(-6 * 24 * 60 * 60))
    #expect(agent.isStaleAgentCandidate(now: now))
}

@Test("Idle agent with an unread result is retained")
func staleAgentIdleUnreadDoesNotMatch() {
    let now = Date()
    var agent = staleFixture(status: .idle,
        heartbeat: now.addingTimeInterval(-6 * 24 * 60 * 60))
    agent.completionUnread = true
    #expect(!agent.isStaleAgentCandidate(now: now))
}

@Test("Working and queued agents are never stale")
func staleAgentWorkingDoesNotMatch() {
    let now = Date()
    let working = staleFixture(status: .working, heartbeat: now.addingTimeInterval(-60))
    #expect(working.effectiveStatus(now: now) == .working)
    #expect(!working.isStaleAgentCandidate(now: now))
    let queued = staleFixture(status: .queued,
        heartbeat: now.addingTimeInterval(-30 * 24 * 60 * 60))
    #expect(!queued.isStaleAgentCandidate(now: now))
}

@Test("Agents active within the five-day window are retained")
func staleAgentFreshDoesNotMatch() {
    let now = Date()
    let agent = staleFixture(status: .idle,
        heartbeat: now.addingTimeInterval(-4 * 24 * 60 * 60))
    #expect(!agent.isStaleAgentCandidate(now: now))
}

@Test("Already archived agents are never stale candidates")
func staleAgentArchivedDoesNotMatch() {
    let now = Date()
    var agent = staleFixture(status: .idle, attention: .interrupted,
        heartbeat: now.addingTimeInterval(-6 * 24 * 60 * 60))
    agent.agentRemovedAt = now.addingTimeInterval(-24 * 60 * 60)
    #expect(!agent.isStaleAgentCandidate(now: now))
}

@Test("Agents the user opened after completion are retained")
func staleAgentRetainedDoesNotMatch() {
    let now = Date()
    var agent = staleFixture(status: .idle, attention: .interrupted,
        heartbeat: now.addingTimeInterval(-6 * 24 * 60 * 60))
    agent.completedRuntimeOpenedAt = now.addingTimeInterval(-6 * 24 * 60 * 60)
    #expect(!agent.isStaleAgentCandidate(now: now))
}

@Test("A newer result keeps an old heartbeat from looking stale")
func staleAgentUsesLatestActivity() {
    let now = Date()
    var agent = staleFixture(status: .idle,
        heartbeat: now.addingTimeInterval(-6 * 24 * 60 * 60))
    agent.resultAt = now.addingTimeInterval(-1 * 24 * 60 * 60)
    #expect(!agent.isStaleAgentCandidate(now: now))
}

@Test("Records without any activity timestamp are skipped")
func staleAgentWithoutTimestampsDoesNotMatch() {
    let now = Date()
    let agent = staleFixture(status: .idle, attention: .interrupted)
    #expect(agent.lastHeartbeatAt == nil)
    #expect(!agent.isStaleAgentCandidate(now: now))
}

@Test("Legacy subtasks decode without an output timestamp")
func taskSubtaskLegacyOutputTimestampDecoding() throws {
    let data = Data(#"{"id":"legacy","title":"Legacy agent"}"#.utf8)
    let decoded = try JSONDecoder().decode(TaskSubtask.self, from: data)
    #expect(decoded.lastOutputAt == nil)

    var current = decoded
    current.lastOutputAt = Date(timeIntervalSinceReferenceDate: 123)
    let roundTrip = try JSONDecoder().decode(TaskSubtask.self, from: JSONEncoder().encode(current))
    #expect(roundTrip.lastOutputAt == current.lastOutputAt)
}

@Test("Task pins persist through locked mutation and clear when the dashboard closes the task")
func taskPinLifecycle() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let ticket = contextTicket()
    _ = try await store.ensureContext(ticket: ticket)
    let pinnedAt = Date(timeIntervalSinceReferenceDate: 123)

    let pinned = try await store.setPinned(ticketID: ticket.id, at: pinnedAt)
    #expect(pinned.pinnedAt == pinnedAt)
    #expect(try await store.load(ticketID: ticket.id)?.pinnedAt == pinnedAt)

    let resolved = DashboardTicket(
        id: ticket.id, title: ticket.title, status: "resolved", summary: ticket.summary)
    let cleared = try await store.ensureContext(ticket: resolved)
    #expect(cleared.pinnedAt == nil)
    let reopened = try await store.ensureContext(ticket: ticket)
    #expect(reopened.pinnedAt == nil)
}

@Test("Progress and prompt heartbeats do not count as agent output")
func taskSubtaskOutputTimestampLifecycle() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let initial = try await store.ensureContext(ticket: contextTicket())
    let sessionID = UUID().uuidString
    var agent = TaskSubtask(id: "worker", title: "Worker", provider: .codex,
        sessionID: sessionID, status: .working)
    agent.workspace = AgentWorkspace(path: root.path, repositoryPath: root.path)
    _ = try await store.upsertSubtask(ticketID: initial.ticketID, subtask: agent)

    let progressAt = Date(timeIntervalSinceReferenceDate: 200)
    let progress = try await store.updateProgress(ticketID: initial.ticketID,
        subtaskID: agent.id, status: .working, summary: "Still working", now: progressAt)
    #expect(progress.subtasks[0].lastHeartbeatAt == progressAt)
    #expect(progress.subtasks[0].lastOutputAt == nil)
    #expect(progress.lastPromptAt == nil)

    let prompt = try await store.registerExternalSession(ticketID: initial.ticketID,
        provider: .codex, sessionID: sessionID, title: "Later prompt", cwd: root.path,
        preferredSubtaskID: agent.id, allowFreshAssociation: true,
        tmux: nil, paneID: nil, socketPath: nil, eventName: "UserPromptSubmit")
    #expect(prompt.subtasks[0].lastOutputAt == nil)
    let promptAt = try #require(prompt.lastPromptAt)

    let stopped = try await store.registerExternalSession(ticketID: initial.ticketID,
        provider: .codex, sessionID: sessionID, title: "Worker", cwd: root.path,
        preferredSubtaskID: agent.id, allowFreshAssociation: true,
        tmux: nil, paneID: nil, socketPath: nil, eventName: "Stop")
    #expect(stopped.subtasks[0].lastOutputAt != nil)
    #expect(stopped.lastPromptAt == promptAt)

    let ignoredOlderPrompt = try await store.recordPrompt(
        ticketID: initial.ticketID, at: promptAt.addingTimeInterval(-60))
    #expect(ignoredOlderPrompt.lastPromptAt == promptAt)
    let laterPromptAt = promptAt.addingTimeInterval(60)
    let laterPrompt = try await store.recordPrompt(
        ticketID: initial.ticketID, at: laterPromptAt)
    #expect(laterPrompt.lastPromptAt == laterPromptAt)

    let completionAt = try #require(stopped.subtasks[0].lastOutputAt).addingTimeInterval(1)
    let completed = try await store.updateProgress(ticketID: initial.ticketID,
        subtaskID: agent.id, status: .completed, summary: "Done", now: completionAt)
    #expect(completed.subtasks[0].lastOutputAt == completionAt)
    let archive = completed.contextDirectory.appendingPathComponent("archive")
    let snapshots = try FileManager.default.contentsOfDirectory(at: archive,
        includingPropertiesForKeys: nil).compactMap { directory -> TaskContext? in
            let data = try? Data(contentsOf: directory.appendingPathComponent("context.json"))
            return data.flatMap { try? JSONDecoder().decode(TaskContext.self, from: $0) }
        }
    #expect(snapshots.contains { $0.subtasks.first?.lastOutputAt == completionAt })
}

@Test("Explicit results and assignment completion propagate monotonic output time")
func taskSubtaskOutputTimestampPropagation() async throws {
    let root = try contextFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let initial = try await store.ensureContext(ticket: contextTicket())
    var assignment = TaskSubtask(id: "assignment", title: "Assignment", runtimeMode: nil)
    assignment.isAssignmentOnly = true
    var agent = TaskSubtask(id: "agent", title: "Agent", sessionID: UUID().uuidString)
    agent.parentSubtaskID = assignment.id
    _ = try await store.upsertSubtask(ticketID: initial.ticketID, subtask: assignment)
    _ = try await store.upsertSubtask(ticketID: initial.ticketID, subtask: agent)

    let result = try await store.reportAttention(ticketID: initial.ticketID,
        subtaskID: agent.id, attention: nil, summary: "Review this", result: true)
    let resultAt = try #require(result.subtasks.first { $0.id == agent.id }?.resultAt)
    #expect(result.subtasks.first { $0.id == agent.id }?.lastOutputAt == resultAt)

    let completionAt = resultAt.addingTimeInterval(10)
    let completed = try await store.updateProgress(ticketID: initial.ticketID,
        subtaskID: assignment.id, status: .completed, summary: "Approved", now: completionAt)
    #expect(completed.subtasks.first { $0.id == assignment.id }?.lastOutputAt == completionAt)
    #expect(completed.subtasks.first { $0.id == agent.id }?.lastOutputAt == completionAt)

    let older = try await store.updateProgress(ticketID: initial.ticketID,
        subtaskID: agent.id, status: .completed, summary: "Late duplicate",
        now: resultAt.addingTimeInterval(-10))
    #expect(older.subtasks.first { $0.id == agent.id }?.lastOutputAt == completionAt)
}
