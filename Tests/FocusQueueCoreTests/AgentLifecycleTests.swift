import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Independent agent lifecycle")
struct AgentLifecycleTests {
    @Test("Removal preserves assignment and provider identity across reload; override resists late reports")
    func removeAndOverride() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let ticket = DashboardTicket(id: "ECC-777", title: "Lifecycle", status: "open", summary: "")
        _ = try await store.ensureContext(ticket: ticket)
        var subtask = TaskSubtask(title: "Undo accidental work", sessionID: UUID().uuidString, status: .blocked)
        subtask.workspace = AgentWorkspace(path: "/tmp/original", repositoryPath: "/tmp/repo", branch: "feature", managed: false)
        subtask.initialPrompt = "Undo only your changes"
        _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: subtask)
        let removed = try await store.removeAgent(ticketID: ticket.id, subtaskID: subtask.id)
        #expect(removed.subtasks[0].status == .blocked)
        #expect(!removed.subtasks[0].isAgentVisible)
        #expect(removed.subtasks[0].sessionID == subtask.sessionID)
        #expect(removed.subtasks[0].workspace == subtask.workspace)
        let reloaded = try await TaskContextStore(root: root).load(ticketID: ticket.id)
        #expect(reloaded == removed)
        _ = try await store.overrideCompletion(ticketID: ticket.id, subtaskID: subtask.id)
        let late = try await store.updateProgress(ticketID: ticket.id, subtaskID: subtask.id, status: .working, summary: "Late report")
        #expect(late.subtasks[0].status == .completed)
        #expect(late.subtasks[0].completionOverrideAt != nil)
        #expect(late.subtasks[0].progressSummary.contains("user override"))
    }

    @Test("Resume uses the exact conversation and saved workspace without replaying initialization", arguments: AgentProvider.allCases)
    func resume(provider: AgentProvider) throws {
        let context = TaskContext(ticketID: "ECC-777", title: "Lifecycle", summary: "", successCriteria: "",
            planPath: "/tmp/support/tasks/ECC-777/plan.md", worktreePath: "/tmp/new-parent", updatedAt: Date())
        let id = UUID().uuidString
        var subtask = TaskSubtask(title: "Old assignment", provider: provider, sessionID: id)
        subtask.workspace = AgentWorkspace(path: "/tmp/original workspace", repositoryPath: "/tmp/repo", branch: "feature", managed: false)
        subtask.initialPrompt = "NEVER REPLAY THIS"
        let command = try TaskAgentLauncher.command(context: context, subtask: subtask, supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(command.contains(provider == .codex ? "resume" : "--resume"))
        #expect(command.contains(id))
        #expect(command.contains("/tmp/original workspace"))
        #expect(!command.contains("/tmp/new-parent"))
        #expect(!command.contains { $0.contains("NEVER REPLAY THIS") })
    }

    @Test("Custom initial prompt is sent without task initialization; blank sessions submit nothing")
    func customAndBlank() throws {
        let context = TaskContext(ticketID: "ECC-777", title: "Lifecycle", summary: "", successCriteria: "",
            planPath: "/tmp/support/tasks/ECC-777/plan.md", worktreePath: "/tmp/repo", updatedAt: Date())
        var subtask = TaskSubtask(title: "Blank", includeInitializationPrompt: false)
        subtask.tracksCompletion = false
        subtask.initialPrompt = "Review literal $(data)\nsecond line"
        let command = try TaskAgentLauncher.command(context: context, subtask: subtask, supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(command.last == subtask.initialPrompt)
        #expect(!command.contains { $0.contains("Work on ECC-777") })
        subtask.initialPrompt = ""
        let blank = try TaskAgentLauncher.command(context: context, subtask: subtask, supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(blank.last == context.contextDirectory.path)
        #expect(try JSONDecoder().decode(TaskSubtask.self, from: JSONEncoder().encode(subtask)).tracksCompletion == false)
    }

    @Test("Notification surfaces the reason before legacy rejection boilerplate")
    func reasons() {
        #expect(CompletionExplanation.concise("Completion rejected for subtask `uuid`.\n\nThe requested change was reverted.\n\nSigning passed.") == "The requested change was reverted.")
        #expect(CompletionExplanation.concise("Verdict: leave open.\n\nMissing: installed-app evidence.") == "Missing: installed-app evidence.")
        #expect(CompletionExplanation.concise(String(repeating: "a", count: 400)).count == 218)
    }

    @Test("Each agent worktree starts at the selected commit; dirty sources and branch changes are detected")
    func workspaceSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let runner = FoundationProcessRunner()
        func git(_ args: [String]) async throws -> String {
            let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: args, workingDirectory: repo.path))
            #expect(result.succeeded, "\(result.standardError)")
            return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Base", "--allow-empty"])
        let store = TaskContextStore(root: root.appendingPathComponent("support"))
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-777", title: "Workspace", status: "open", summary: ""))
        let manager = TaskWorktreeManager()
        let firstID = UUID().uuidString
        let first = try await manager.provisionAgent(ticketID: "ECC-777", subtaskID: firstID, path: repo.path, createWorktree: true, store: store)
        let second = try await manager.provisionAgent(ticketID: "ECC-777", subtaskID: UUID().uuidString, path: repo.path, createWorktree: true, store: store)
        #expect(first.path != second.path && first.branch != second.branch)
        #expect(first.baseCommit == (try await git(["rev-parse", "HEAD"])))
        let dirty = repo.appendingPathComponent("uncommitted-feature.swift")
        try Data("new feature".utf8).write(to: dirty)
        await #expect(throws: TaskContextError.self) {
            try await manager.provisionAgent(ticketID: "ECC-777", subtaskID: UUID().uuidString, path: repo.path, createWorktree: true, store: store)
        }
        let shared = try await manager.provisionAgent(ticketID: "ECC-777", subtaskID: UUID().uuidString, path: repo.path, createWorktree: false, store: store)
        #expect(shared.path == repo.path && !shared.managed)
        _ = try await git(["checkout", "-qb", "changed"])
        await #expect(throws: TaskContextError.self) { try await manager.validate(shared) }
        var subtask = TaskSubtask(id: firstID, title: "Completed", status: .completed)
        subtask.workspace = first
        _ = try await store.upsertSubtask(ticketID: "ECC-777", subtask: subtask)
        let ignored = URL(fileURLWithPath: first.path).appendingPathComponent("scratch")
        try Data("keep".utf8).write(to: ignored)
        #expect(try await !manager.cleanupAgent(ticketID: "ECC-777", subtask: subtask, store: store).removed)
        try FileManager.default.removeItem(at: ignored)
        var assignment = TaskSubtask(id: "assignment", title: "Review workspace cleanup")
        assignment.isAssignmentOnly = true
        assignment.workspace = first
        subtask.parentSubtaskID = assignment.id
        _ = try await store.upsertSubtask(ticketID: "ECC-777", subtask: assignment)
        _ = try await store.upsertSubtask(ticketID: "ECC-777", subtask: subtask)
        #expect(!assignment.hasManagedWorkspaces)
        #expect(try await manager.cleanupAgent(ticketID: "ECC-777", subtask: subtask, store: store).removed)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}
