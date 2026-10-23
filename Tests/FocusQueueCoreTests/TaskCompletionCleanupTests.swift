import Foundation
import Testing
@testable import FocusQueueCore

private struct CleanupFixture {
    let root: URL
    let repository: URL
    let remote: URL
    let store: TaskContextStore
    let supportRoot: URL
    let manager = TaskWorktreeManager()

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-cleanup-test-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        repository = root.appendingPathComponent("repo", isDirectory: true)
        remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        supportRoot = root.appendingPathComponent("support", isDirectory: true)
        store = TaskContextStore(root: supportRoot)
        _ = try await git(["init", "-b", "main"])
        _ = try await git(["config", "user.email", "test@example.com"])
        _ = try await git(["config", "user.name", "Focus Queue Test"])
        try Data(".build/\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
        try Data("base\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        _ = try await git(["add", "."])
        _ = try await git(["commit", "-m", "Initial"])
        _ = try await git(["init", "--bare", "-b", "main", remote.path], in: root)
        _ = try await git(["remote", "add", "origin", remote.path])
        _ = try await git(["push", "--quiet", "origin", "main"])
    }

    func cleanup(now: Date = Date()) -> TaskCompletionCleanup {
        TaskCompletionCleanup(root: supportRoot, projectRepositories: [repository.path],
            tmuxServer: "fq-cleanup-test-\(UUID().uuidString.prefix(8))")
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let result = try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git",
            arguments: arguments, workingDirectory: (directory ?? repository).path))
        guard result.succeeded else { throw TaskContextError.commandFailed(result.standardError) }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func agent(_ ticketID: String, _ title: String) async throws -> (TaskSubtask, URL) {
        let id = UUID().uuidString
        let workspace = try await manager.provisionAgent(ticketID: ticketID, subtaskID: id,
            path: repository.path, createWorktree: true, store: store)
        var subtask = TaskSubtask(id: id, title: title, status: .completed)
        subtask.workspace = workspace
        _ = try await store.upsertSubtask(ticketID: ticketID, subtask: subtask)
        return (subtask, URL(fileURLWithPath: workspace.path))
    }

    func commit(_ file: String, in workspace: URL) async throws -> String {
        try Data("\(file)\n".utf8).write(to: workspace.appendingPathComponent(file))
        try await git(["add", file], in: workspace)
        try await git(["commit", "-m", "Add \(file)"], in: workspace)
        return try await git(["rev-parse", "HEAD"], in: workspace)
    }

    func trashEntries() -> [String] {
        let trash = TaskWorktreeManager.managedRoot(repositoryPath: repository.path)
            .appendingPathComponent(TaskWorktreeManager.trashDirectoryName)
        return ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted()
    }
}

private func ticket(_ id: String) -> DashboardTicket {
    DashboardTicket(id: id, title: "Clean up \(id)", status: "resolved", summary: "Retire the runtime.")
}

@Test("Completion stages every worktree, archives unmerged work, and deletes branches locally and remotely")
func completionCleanupRetiresWorkspaces() async throws {
    let fixture = try await CleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.store.ensureContext(ticket: ticket("FOC-901"))
    let (merged, mergedPath) = try await fixture.agent("FOC-901", "Merged")
    let (rebased, rebasedPath) = try await fixture.agent("FOC-901", "Rebased")
    let (unmerged, unmergedPath) = try await fixture.agent("FOC-901", "Unmerged")
    let (dirty, dirtyPath) = try await fixture.agent("FOC-901", "Dirty")
    let mergedBranch = try #require(merged.workspace?.branch)
    let rebasedBranch = try #require(rebased.workspace?.branch)
    let unmergedBranch = try #require(unmerged.workspace?.branch)
    let dirtyBranch = try #require(dirty.workspace?.branch)

    _ = try await fixture.commit("merged.txt", in: mergedPath)
    try await fixture.git(["merge", "--ff-only", mergedBranch])
    let rebasedCommit = try await fixture.commit("rebased.txt", in: rebasedPath)
    try await fixture.git(["cherry-pick", rebasedCommit])
    let unmergedHead = try await fixture.commit("unmerged.txt", in: unmergedPath)
    try Data("draft\n".utf8).write(to: dirtyPath.appendingPathComponent("draft.txt"))
    try FileManager.default.createDirectory(at: dirtyPath.appendingPathComponent(".build/debug"), withIntermediateDirectories: true)
    try await fixture.git(["push", "--quiet", "origin", "main", mergedBranch, unmergedBranch])

    let report = await fixture.cleanup().run(ticketID: "foc-901")

    #expect(report.problems.isEmpty, "\(report.problems)")
    #expect(report.worktrees.count == 4)
    #expect(!FileManager.default.fileExists(atPath: mergedPath.path))
    #expect(!FileManager.default.fileExists(atPath: dirtyPath.path))
    #expect(try await fixture.git(["worktree", "list", "--porcelain"]).components(separatedBy: "worktree ").count == 2)
    #expect(try await fixture.git(["for-each-ref", "--format=%(refname:short)", "refs/heads/"]) == "main")
    // Unmerged commits and uncommitted files survive under archive refs.
    #expect(try await fixture.git(["rev-parse", TaskWorktreeManager.archiveRef(forBranch: unmergedBranch)]) == unmergedHead)
    let snapshot = TaskWorktreeManager.archiveRef(forBranch: dirtyBranch) + "-uncommitted"
    #expect(try await fixture.git(["show", snapshot + ":draft.txt"]) == "draft")
    #expect(try await fixture.git(["show-ref"]).contains(TaskWorktreeManager.archiveRef(forBranch: mergedBranch)) == false)
    #expect(try await fixture.git(["show-ref"]).contains(TaskWorktreeManager.archiveRef(forBranch: rebasedBranch)) == false)
    let dirtyRecord = try #require(report.worktrees.first { $0.branch == dirtyBranch })
    #expect(dirtyRecord.removedBuildOutput == [".build"])
    let staged = try #require(dirtyRecord.stagedPath)
    #expect(FileManager.default.fileExists(atPath: staged + "/draft.txt"))
    #expect(!FileManager.default.fileExists(atPath: staged + "/.build"))
    #expect(fixture.trashEntries().filter { $0.hasSuffix(".json") }.count == 4)
    // The merged remote branch goes; the unmerged one is the user's backup.
    let remoteHeads = try await fixture.git(["ls-remote", "--heads", "origin"])
    #expect(!remoteHeads.contains(mergedBranch))
    #expect(remoteHeads.contains(unmergedBranch))
    // The ticket's folder is gone, and the task record keeps its agents.
    #expect(!FileManager.default.fileExists(atPath: TaskWorktreeManager.managedRoot(
        repositoryPath: fixture.repository.path).appendingPathComponent("foc-901").path))
    let context = try #require(try await fixture.store.load(ticketID: "FOC-901"))
    #expect(context.subtasks.count == 4)
    #expect(!FileManager.default.fileExists(atPath: context.contextDirectory.appendingPathComponent("archive").path))
    #expect(TaskCompletionCleanup.savedReport(ticketID: "FOC-901", root: fixture.supportRoot)?.isClean == true)

    // A reopened agent gets its archived work back.
    try await fixture.manager.restoreIfNeeded(try #require(unmerged.workspace), ticketID: "FOC-901",
        subtaskID: unmerged.id, store: fixture.store)
    #expect(try await fixture.git(["rev-parse", "HEAD"], in: unmergedPath) == unmergedHead)

    let again = await fixture.cleanup().run(ticketID: "FOC-901", dryRun: true)
    #expect(again.worktrees.count == 1)
    #expect(again.summary.hasPrefix("Would clean"))
}

@Test("A dry run reports the plan and changes nothing")
func completionCleanupDryRun() async throws {
    let fixture = try await CleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.store.ensureContext(ticket: ticket("FOC-902"))
    let (agent, path) = try await fixture.agent("FOC-902", "Unmerged")
    _ = try await fixture.commit("work.txt", in: path)

    let report = await fixture.cleanup().run(ticketID: "FOC-902", dryRun: true)

    #expect(report.worktrees.first?.archiveRef == TaskWorktreeManager.archiveRef(forBranch: try #require(agent.workspace?.branch)))
    #expect(report.branches.count == 1)
    #expect(FileManager.default.fileExists(atPath: path.path))
    #expect(fixture.trashEntries().isEmpty)
    #expect(try await fixture.git(["for-each-ref", "refs/focus-queue/"]).isEmpty)
    #expect(TaskCompletionCleanup.savedReport(ticketID: "FOC-902", root: fixture.supportRoot) == nil)
}

@Test("Staged items are purged only after the retention window")
func completionCleanupPurgesExpiredStaging() async throws {
    let fixture = try await CleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.store.ensureContext(ticket: ticket("FOC-903"))
    _ = try await fixture.store.ensureContext(ticket: ticket("FOC-904"))
    _ = try await fixture.agent("FOC-903", "Old")
    _ = try await fixture.agent("FOC-904", "Recent")
    let cleanup = fixture.cleanup()
    _ = await cleanup.run(ticketID: "FOC-903", now: Date().addingTimeInterval(-8 * 24 * 60 * 60))
    _ = await cleanup.run(ticketID: "FOC-904")
    #expect(fixture.trashEntries().count == 4)

    let purged = await cleanup.purgeExpiredStaging()

    #expect(purged.count == 2)
    #expect(fixture.trashEntries().allSatisfy { $0.hasPrefix("foc-904") })
    let supportTrash = try FileManager.default.contentsOfDirectory(
        atPath: fixture.supportRoot.appendingPathComponent("trash").path)
    #expect(supportTrash.allSatisfy { $0.hasPrefix("foc-904") })
}

@Test("The orphan sweep retires workspaces of unknown tasks and keeps open tasks")
func completionCleanupSweepsOrphans() async throws {
    let fixture = try await CleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.store.ensureContext(ticket: ticket("FOC-905"))
    _ = try await fixture.store.ensureContext(ticket: ticket("ECC-906"))
    let (_, openPath) = try await fixture.agent("FOC-905", "Open")
    let (_, orphanPath) = try await fixture.agent("ECC-906", "Forgotten")

    let report = await fixture.cleanup().sweepOrphans(openTicketIDs: ["FOC-905"], dryRun: false)

    #expect(report.problems.isEmpty, "\(report.problems)")
    #expect(FileManager.default.fileExists(atPath: openPath.path))
    #expect(!FileManager.default.fileExists(atPath: orphanPath.path))
    let branches = try await fixture.git(["for-each-ref", "--format=%(refname:short)", "refs/heads/"])
    #expect(branches.contains("focus-queue/foc-905-"))
    #expect(!branches.contains("ecc-906"))
}

@Test("Task-owned branch names never match a longer ticket number")
func completionCleanupBranchOwnership() {
    #expect(TaskWorktreeManager.ownsBranch("focus-queue/foc-043", ticketID: "FOC-043"))
    #expect(TaskWorktreeManager.ownsBranch("focus-queue/foc-043-47756022", ticketID: "FOC-043"))
    #expect(!TaskWorktreeManager.ownsBranch("focus-queue/foc-0431", ticketID: "FOC-043"))
    #expect(!TaskWorktreeManager.ownsBranch("main", ticketID: "FOC-043"))
    #expect(TaskCompletionCleanup.ticketComponent(ofBranch: "focus-queue/foc-043-47756022-20e3") == "foc-043")
    #expect(TaskCompletionCleanup.ticketComponent(ofBranch: "focus-queue/ui") == nil)
    let names = TaskCompletionCleanup.sessionNames(ticketID: "FOC-043", context: nil)
    #expect(names == ["fq-task-foc-043"])
}

@Test("Rebased work counts as integrated even after the base edits the same lines")
func completionCleanupRecognizesRebasedWork() async throws {
    let fixture = try await CleanupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.store.ensureContext(ticket: ticket("FOC-907"))
    let (_, path) = try await fixture.agent("FOC-907", "Rebased")
    try Data("agent line\n".utf8).write(to: path.appendingPathComponent("README.md"))
    try await fixture.git(["commit", "-am", "Agent edit"], in: path)
    let head = try await fixture.git(["rev-parse", "HEAD"], in: path)
    try await fixture.git(["cherry-pick", head])
    try Data("later base line\n".utf8).write(to: fixture.repository.appendingPathComponent("README.md"))
    try await fixture.git(["commit", "-am", "Later base edit"])
    #expect(try await fixture.manager.isIntegrated(head, into: ["refs/heads/main"], repositoryPath: fixture.repository.path))
    try Data("unshipped\n".utf8).write(to: path.appendingPathComponent("extra.txt"))
    try await fixture.git(["add", "extra.txt"], in: path)
    try await fixture.git(["commit", "-m", "Unshipped"], in: path)
    let unshipped = try await fixture.git(["rev-parse", "HEAD"], in: path)
    #expect(try await !fixture.manager.isIntegrated(unshipped, into: ["refs/heads/main"], repositoryPath: fixture.repository.path))
}
