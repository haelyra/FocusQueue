import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Independent agent lifecycle")
struct AgentLifecycleTests {
    @Test("An agent workspace is immutable after its first assignment")
    func immutableWorkspaceAssignment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let ticket = DashboardTicket(id: "ECC-778", title: "Workspace ownership", status: "open", summary: "")
        _ = try await store.ensureContext(ticket: ticket)
        let subtask = TaskSubtask(title: "Implement safely", sessionID: UUID().uuidString, status: .working)
        _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: subtask)

        let assigned = AgentWorkspace(path: "/tmp/agent-a", repositoryPath: "/tmp/repo", branch: "agent-a")
        _ = try await store.setAgentWorkspace(ticketID: ticket.id, subtaskID: subtask.id, workspace: assigned)

        var refreshed = assigned
        refreshed.baseCommit = "abc123"
        refreshed.repositoryIdentity = "repo-id"
        let samePath = try await store.setAgentWorkspace(
            ticketID: ticket.id, subtaskID: subtask.id, workspace: refreshed)
        #expect(samePath.subtasks[0].workspace == refreshed)
        #expect(samePath.subtasks[0].workspaceHistory.isEmpty)

        let replacement = AgentWorkspace(path: "/tmp/agent-b", repositoryPath: "/tmp/repo", branch: "agent-b")
        await #expect(throws: TaskContextError.self) {
            try await store.setAgentWorkspace(ticketID: ticket.id, subtaskID: subtask.id, workspace: replacement)
        }
        let preserved = try #require(try await store.load(ticketID: ticket.id))
        #expect(preserved.subtasks[0].workspace == refreshed)
        #expect(preserved.subtasks[0].workspaceHistory.isEmpty)
    }

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
        #expect(late.subtasks[0].progressSummary == "Marked complete by the user.")
    }

    @Test("Resume uses the exact conversation and saved workspace without replaying initialization", arguments: AgentProvider.allCases)
    func resume(provider: AgentProvider) throws {
        let context = TaskContext(ticketID: "ECC-777", title: "Lifecycle", summary: "", successCriteria: "",
            planPath: "/tmp/support/tasks/ECC-777/plan.md", worktreePath: "/tmp/new-parent", updatedAt: Date())
        let id = provider == .kimi ? "session_\(UUID().uuidString.lowercased())" : UUID().uuidString
        var subtask = TaskSubtask(title: "Old assignment", provider: provider, sessionID: id)
        subtask.workspace = AgentWorkspace(path: "/tmp/original workspace", repositoryPath: "/tmp/repo", branch: "feature", managed: false)
        subtask.initialPrompt = "NEVER REPLAY THIS"
        let command = try TaskAgentLauncher.command(context: context, subtask: subtask, supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(command.contains(provider == .codex ? "resume" : provider == .kimi ? "--session" : "--resume"))
        #expect(command.contains(id))
        #expect(command.contains("/tmp/original workspace"))
        #expect(!command.contains("/tmp/new-parent"))
        #expect(!command.contains { $0.contains("NEVER REPLAY THIS") })
    }

    @Test("Compact initialization preserves custom prompts and prepares empty sessions without starting work")
    func customAndBlank() throws {
        let context = TaskContext(ticketID: "ECC-777", title: "Lifecycle", summary: "", successCriteria: "",
            planPath: "/tmp/support/tasks/ECC-777/plan.md", worktreePath: "/tmp/repo", updatedAt: Date())
        var subtask = TaskSubtask(title: "Blank", includeInitializationPrompt: false)
        subtask.tracksCompletion = false
        subtask.initialPrompt = "Review literal $(data)\nsecond line"
        let command = try TaskAgentLauncher.command(context: context, subtask: subtask, supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(command.last == context.agentBootstrap(subtask: subtask))
        #expect(command.last?.hasPrefix(subtask.initialPrompt! + "\n\n") == true)
        #expect(!command.contains { $0.contains("Work on ECC-777") })
        subtask.initialPrompt = ""
        let blank = try TaskAgentLauncher.command(context: context, subtask: subtask, supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(blank.last?.contains("wait for my instruction before implementing anything") == true)
        #expect(blank.last?.contains(context.planPath) == true)
        subtask.includeInitializationPrompt = true
        let detailedBlank = try TaskAgentLauncher.command(context: context, subtask: subtask,
            supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(detailedBlank.last?.hasPrefix("Prepare the task context, then wait for my instruction") == true)
        let suppressed = try TaskAgentLauncher.command(context: context, subtask: subtask,
            supportDirectory: URL(fileURLWithPath: "/tmp/support"), includePrompt: false)
        #expect(suppressed.last == context.contextDirectory.path)
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
        let support = root.appendingPathComponent("support")
        let store = TaskContextStore(root: support)
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

    @Test("A plain directory hosts the agent directly; Git isolation is suggested, not required")
    func plainDirectoryWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let store = TaskContextStore(root: root.appendingPathComponent("support"))
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-778", title: "Plain", status: "open", summary: ""))
        let manager = TaskWorktreeManager()
        #expect(try await manager.gitWorkspace(at: plain.path) == nil)
        #expect(try await manager.hasUncommittedChanges(at: plain.path) == false)
        let workspace = try await manager.provisionAgent(ticketID: "ECC-778", subtaskID: UUID().uuidString,
            path: plain.path, createWorktree: true, store: store)
        #expect(workspace.path == plain.path)
        #expect(workspace.repositoryPath == plain.path)
        #expect(!workspace.managed)
        #expect(workspace.branch == nil && workspace.baseCommit == nil)
    }

    @Test("Managed cleanup refuses a workspace replaced after validation")
    func workspaceReplacementSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = FoundationProcessRunner()
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Base", "--allow-empty"],
        ] {
            #expect(try await git.run(.init(
                executable: "/usr/bin/git", arguments: arguments,
                workingDirectory: repo.path)).succeeded)
        }
        let support = root.appendingPathComponent("support")
        let store = TaskContextStore(root: support)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-778", title: "Workspace identity", status: "open", summary: ""))
        let id = UUID().uuidString
        let managedPath = TaskWorktreeManager.agentDestination(repositoryPath: repo.path,
            ticketID: "ECC-778", subtaskID: id)
        let runner = WorkspaceReplacingRunner(target: managedPath)
        let manager = TaskWorktreeManager(runner: runner)
        let workspace = try await manager.provisionAgent(
            ticketID: "ECC-778", subtaskID: id, path: repo.path,
            createWorktree: true, store: store)
        var agent = TaskSubtask(id: id, title: "Completed", status: .completed)
        agent.workspace = workspace
        _ = try await store.upsertSubtask(ticketID: "ECC-778", subtask: agent)

        do {
            _ = try await manager.cleanupAgent(
                ticketID: "ECC-778", subtask: agent, store: store)
            Issue.record("Cleanup accepted a replaced workspace")
        } catch {
            #expect(error.localizedDescription.contains("identity changed"))
        }
        #expect(FileManager.default.fileExists(
            atPath: managedPath.appendingPathComponent("preserve.txt").path))
    }

    @Test("Cleanup never follows a last-moment worktree symlink")
    func workspaceSymlinkRaceSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = FoundationProcessRunner()
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Base", "--allow-empty"],
        ] {
            #expect(try await git.run(.init(
                executable: "/usr/bin/git", arguments: arguments,
                workingDirectory: repo.path)).succeeded)
        }
        let support = root.appendingPathComponent("support")
        let store = TaskContextStore(root: support)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-779", title: "Workspace race", status: "open", summary: ""))
        let id = UUID().uuidString
        let managed = TaskWorktreeManager.agentDestination(
            repositoryPath: repo.path, ticketID: "ECC-779", subtaskID: id)
        let retained = managed.appendingPathExtension("retained-worktree")
        let victim = root.appendingPathComponent("outside-victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let sentinel = victim.appendingPathComponent("keep.txt")
        try Data("must survive".utf8).write(to: sentinel)

        let manager = TaskWorktreeManager(beforeCleanupQuarantine: { target in
            try FileManager.default.moveItem(at: target, to: retained)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
        })
        let workspace = try await manager.provisionAgent(
            ticketID: "ECC-779", subtaskID: id, path: repo.path,
            createWorktree: true, store: store)
        var agent = TaskSubtask(id: id, title: "Completed", status: .completed)
        agent.workspace = workspace
        _ = try await store.upsertSubtask(ticketID: "ECC-779", subtask: agent)

        do {
            _ = try await manager.cleanupAgent(
                ticketID: "ECC-779", subtask: agent, store: store)
            Issue.record("Cleanup followed a replacement symlink")
        } catch {
            #expect(error.localizedDescription.contains("identity changed"))
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "must survive")
        #expect(FileManager.default.fileExists(atPath: retained.path))
        let listing = try await git.run(.init(
            executable: "/usr/bin/git", arguments: ["worktree", "list", "--porcelain"],
            workingDirectory: repo.path))
        #expect(listing.standardOutput.contains(repo.appendingPathComponent(
            ".worktrees/ecc-779/agents/\(id.lowercased())").path))
        #expect(!listing.standardOutput.contains(victim.path))
    }

    @Test("Cleanup restores a worktree that gains files at the quarantine boundary")
    func workspaceLateWriteSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = FoundationProcessRunner()
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Base", "--allow-empty"],
        ] {
            #expect(try await git.run(.init(
                executable: "/usr/bin/git", arguments: arguments,
                workingDirectory: repo.path)).succeeded)
        }
        let support = root.appendingPathComponent("support")
        let store = TaskContextStore(root: support)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-780", title: "Workspace late write", status: "open", summary: ""))
        let id = UUID().uuidString
        let managed = TaskWorktreeManager.agentDestination(
            repositoryPath: repo.path, ticketID: "ECC-780", subtaskID: id)
        let lateFile = managed.appendingPathComponent("late-work.txt")
        let manager = TaskWorktreeManager(beforeCleanupQuarantine: { target in
            try Data("preserve me".utf8).write(
                to: target.appendingPathComponent("late-work.txt"))
        })
        let workspace = try await manager.provisionAgent(
            ticketID: "ECC-780", subtaskID: id, path: repo.path,
            createWorktree: true, store: store)
        var agent = TaskSubtask(id: id, title: "Completed", status: .completed)
        agent.workspace = workspace
        _ = try await store.upsertSubtask(ticketID: "ECC-780", subtask: agent)

        do {
            _ = try await manager.cleanupAgent(
                ticketID: "ECC-780", subtask: agent, store: store)
            Issue.record("Cleanup deleted work written at the quarantine boundary")
        } catch {
            #expect(error.localizedDescription.contains("changed during cleanup"))
        }
        #expect(try String(contentsOf: lateFile, encoding: .utf8) == "preserve me")
        #expect(FileManager.default.fileExists(atPath: managed.path))
        let quarantines = try FileManager.default.contentsOfDirectory(
            atPath: managed.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".focus-queue-removing-") }
        #expect(quarantines.isEmpty)
    }

    @Test("Cleanup honors an explicit Git worktree lock")
    func workspaceLockSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = FoundationProcessRunner()
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Base", "--allow-empty"],
        ] {
            #expect(try await git.run(.init(
                executable: "/usr/bin/git", arguments: arguments,
                workingDirectory: repo.path)).succeeded)
        }
        let support = root.appendingPathComponent("support")
        let store = TaskContextStore(root: support)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-781", title: "Workspace lock", status: "open", summary: ""))
        let id = UUID().uuidString
        let manager = TaskWorktreeManager()
        let workspace = try await manager.provisionAgent(
            ticketID: "ECC-781", subtaskID: id, path: repo.path,
            createWorktree: true, store: store)
        #expect(try await git.run(.init(
            executable: "/usr/bin/git",
            arguments: ["worktree", "lock", "--reason", "preserve", workspace.path],
            workingDirectory: repo.path)).succeeded)
        var agent = TaskSubtask(id: id, title: "Completed", status: .completed)
        agent.workspace = workspace
        _ = try await store.upsertSubtask(ticketID: "ECC-781", subtask: agent)

        do {
            _ = try await manager.cleanupAgent(
                ticketID: "ECC-781", subtask: agent, store: store)
            Issue.record("Cleanup ignored the worktree lock")
        } catch {
            #expect(error.localizedDescription.contains("locked"))
        }
        #expect(FileManager.default.fileExists(atPath: workspace.path))
    }

    @Test("Cleanup unregisters but retains a worktree when a write lands after the final scan")
    func workspacePostScanWriteIsRetained() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = FoundationProcessRunner()
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Base", "--allow-empty"],
        ] {
            #expect(try await git.run(.init(
                executable: "/usr/bin/git", arguments: arguments,
                workingDirectory: repo.path)).succeeded)
        }
        try Data("tracked baseline".utf8).write(to: repo.appendingPathComponent("baseline.txt"))
        #expect(try await git.run(.init(
            executable: "/usr/bin/git", arguments: ["add", "baseline.txt"],
            workingDirectory: repo.path)).succeeded)
        #expect(try await git.run(.init(
            executable: "/usr/bin/git",
            arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Tracked baseline"],
            workingDirectory: repo.path)).succeeded)
        let support = root.appendingPathComponent("support")
        let store = TaskContextStore(root: support)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-782", title: "Post-scan write", status: "open", summary: ""))
        let id = UUID().uuidString
        let runner = PostScanWritingRunner()
        let manager = TaskWorktreeManager(runner: runner)
        let workspace = try await manager.provisionAgent(
            ticketID: "ECC-782", subtaskID: id, path: repo.path,
            createWorktree: true, store: store)
        var agent = TaskSubtask(id: id, title: "Completed", status: .completed)
        agent.workspace = workspace
        _ = try await store.upsertSubtask(ticketID: "ECC-782", subtask: agent)

        let result = try await manager.cleanupAgent(
            ticketID: "ECC-782", subtask: agent, store: store)
        #expect(result.removed)
        #expect(result.message.contains("retained"))
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        let parent = URL(fileURLWithPath: workspace.path).deletingLastPathComponent()
        let retained = try FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".focus-queue-retained-") }
        #expect(retained.count == 1)
        let retainedPath = try #require(retained.first)
        #expect(try String(contentsOf: retainedPath.appendingPathComponent("late.tmp"),
            encoding: .utf8) == "preserve late work")
        #expect(try String(contentsOf: retainedPath.appendingPathComponent("baseline.txt"),
            encoding: .utf8) == "tracked baseline")
        let listing = try await git.run(.init(
            executable: "/usr/bin/git", arguments: ["worktree", "list", "--porcelain"],
            workingDirectory: repo.path))
        #expect(!listing.standardOutput.contains(workspace.path))
        let activeAdmin = try #require(workspace.gitDirectory)
        #expect(!FileManager.default.fileExists(atPath: activeAdmin))
        let retainedAdmins = try FileManager.default.contentsOfDirectory(
            at: repo.appendingPathComponent(".git/focus-queue-retired-worktrees"),
            includingPropertiesForKeys: nil)
        #expect(retainedAdmins.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: try #require(retainedAdmins.first).appendingPathComponent("HEAD").path))
    }

    @Test("Cleanup restores a worktree locked after its final content scan")
    func workspacePostScanLockIsHonored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = FoundationProcessRunner()
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Base", "--allow-empty"],
        ] {
            #expect(try await git.run(.init(
                executable: "/usr/bin/git", arguments: arguments,
                workingDirectory: repo.path)).succeeded)
        }
        let support = root.appendingPathComponent("support")
        let store = TaskContextStore(root: support)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-783", title: "Post-scan lock", status: "open", summary: ""))
        let id = UUID().uuidString
        let target = TaskWorktreeManager.agentDestination(
            repositoryPath: repo.path, ticketID: "ECC-783", subtaskID: id)
        let runner = PostScanLockingRunner(repository: repo, target: target)
        let manager = TaskWorktreeManager(runner: runner)
        let workspace = try await manager.provisionAgent(
            ticketID: "ECC-783", subtaskID: id, path: repo.path,
            createWorktree: true, store: store)
        var agent = TaskSubtask(id: id, title: "Completed", status: .completed)
        agent.workspace = workspace
        _ = try await store.upsertSubtask(ticketID: "ECC-783", subtask: agent)

        do {
            _ = try await manager.cleanupAgent(
                ticketID: "ECC-783", subtask: agent, store: store)
            Issue.record("Cleanup ignored a lock added after the final scan")
        } catch {
            #expect(error.localizedDescription.contains("locked"))
        }
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        let listing = try await git.run(.init(
            executable: "/usr/bin/git", arguments: ["worktree", "list", "--porcelain"],
            workingDirectory: repo.path))
        #expect(listing.standardOutput.contains(workspace.path))
    }
}

private actor PostScanWritingRunner: ProcessRunning {
    private let delegate = FoundationProcessRunner()
    private var wrote = false

    func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
        let result = try await delegate.run(specification)
        if !wrote,
           result.succeeded,
           specification.arguments.contains("--work-tree"),
           specification.arguments.contains("ls-files"),
           let marker = specification.arguments.firstIndex(of: "--work-tree"),
           specification.arguments.indices.contains(marker + 1) {
            wrote = true
            let worktree = URL(fileURLWithPath: specification.arguments[marker + 1])
            try Data("preserve late work".utf8).write(
                to: worktree.appendingPathComponent("late.tmp"))
        }
        return result
    }
}

private actor PostScanLockingRunner: ProcessRunning {
    private let repository: URL
    private let target: URL
    private let delegate = FoundationProcessRunner()
    private var locked = false

    init(repository: URL, target: URL) {
        self.repository = repository
        self.target = target
    }

    func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
        let result = try await delegate.run(specification)
        if !locked,
           result.succeeded,
           specification.arguments.contains("--work-tree"),
           specification.arguments.contains("ls-files") {
            locked = true
            let lock = try await delegate.run(.init(
                executable: "/usr/bin/git",
                arguments: ["worktree", "lock", "--reason", "late lock", target.path],
                workingDirectory: repository.path))
            guard lock.succeeded else {
                throw TaskContextError.commandFailed(lock.standardError)
            }
        }
        return result
    }
}

private actor WorkspaceReplacingRunner: ProcessRunning {
    private let target: URL
    private let delegate = FoundationProcessRunner()
    private var replaced = false

    init(target: URL) {
        self.target = target
    }

    func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
        let result = try await delegate.run(specification)
        if !replaced,
           specification.workingDirectory == target.path,
           specification.arguments.starts(with: ["merge-base", "--is-ancestor"]),
           result.succeeded {
            replaced = true
            try FileManager.default.moveItem(
                at: target,
                to: target.appendingPathExtension("validated-worktree"))
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("preserve".utf8).write(to: target.appendingPathComponent("preserve.txt"))
        }
        return result
    }
}
