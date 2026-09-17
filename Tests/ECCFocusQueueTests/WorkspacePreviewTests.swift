import Foundation
import Testing
import FocusQueueCore
@testable import ECCFocusQueue

@Suite("Workspace preview") @MainActor
struct WorkspacePreviewTests {
  @Test("Changing paths cancels stale failures and only the latest workspace is displayed")
  func cancellation() async throws {
    let model = WorkspacePreviewModel()
    let first = Task {
      await model.load(path: "/old", lookup: { _ in
        try await Task.sleep(for: .seconds(10))
        throw CancellationError()
      })
    }
    try await Task.sleep(for: .milliseconds(180))
    first.cancel()
    await model.load(path: "/new", changesLookup: { _ in false }) { path in
      AgentWorkspace(path: path, repositoryPath: path, branch: "current")
    }
    await first.value
    #expect(model.error == nil)
    #expect(model.workspace?.path == "/new")
    #expect(model.hasUncommittedChanges == false)
    #expect(!model.isLoading)
    await model.load(path: "/bad", lookup: { _ in throw TaskContextError.unsafeWorktree("Missing workspace") })
    #expect(model.error == "Missing workspace")
    await model.load(path: "")
    #expect(model.error == nil)
    #expect(model.workspace == nil)
    #expect(model.hasUncommittedChanges == nil)
  }

  @Test("A stale change inspection cannot overwrite a newer clean checkout preview")
  func cancelledChangeInspection() async throws {
    let model = WorkspacePreviewModel()
    let first = Task {
      await model.load(path: "/old", changesLookup: { _ in
        try await Task.sleep(for: .seconds(10))
        return true
      }) { path in AgentWorkspace(path: path, repositoryPath: path) }
    }
    try await Task.sleep(for: .milliseconds(180))
    #expect(model.isLoading)
    #expect(model.workspace == nil)
    #expect(model.launchBlockReason(path: "/old", createWorktree: false) != nil)
    first.cancel()
    await model.load(path: "/new", changesLookup: { _ in false }) { path in
      AgentWorkspace(path: path, repositoryPath: path)
    }
    await first.value
    #expect(model.workspace?.path == "/new")
    #expect(model.hasUncommittedChanges == false)
    #expect(model.launchBlockReason(path: "/new", createWorktree: true) == nil)
  }

  @Test("Failed Git status inspection stays visible and never claims the checkout is clean")
  func failedChangeInspection() async {
    let model = WorkspacePreviewModel()
    await model.load(path: "/checkout", changesLookup: { _ in
      throw TaskContextError.commandFailed("Could not inspect checkout changes")
    }) { path in AgentWorkspace(path: path, repositoryPath: path) }
    #expect(model.workspace == nil)
    #expect(model.hasUncommittedChanges == nil)
    #expect(!model.isLoading)
    #expect(model.launchBlockReason(path: "/checkout", createWorktree: true)
      == "Could not inspect checkout changes")
  }

  @Test("Actual dirty task checkout offers a safe existing-checkout path and rechecks a clean repository")
  func actualDirtyAndCleanCheckoutSanity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-sanity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("repository")
    let worktree = root.appendingPathComponent("task-worktree")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    func git(_ arguments: [String], at directory: URL) async throws -> String {
      let result = try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git",
        arguments: arguments, workingDirectory: directory.path))
      try #require(result.succeeded, "\(result.standardError)")
      return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    _ = try await git(["init", "-q", "-b", "main"], at: repository)
    let original = Data("committed content\n".utf8)
    try original.write(to: repository.appendingPathComponent("user-file.txt"))
    _ = try await git(["add", "user-file.txt"], at: repository)
    _ = try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture"], at: repository)
    let originalCommit = try await git(["rev-parse", "HEAD"], at: repository)
    _ = try await git(["worktree", "add", "-b", "task", worktree.path], at: repository)
    let userEdits = Data("uncommitted user changes\n".utf8)
    let changedFile = worktree.appendingPathComponent("user-file.txt")
    try userEdits.write(to: changedFile)
    let untrackedFile = worktree.appendingPathComponent("user-notes.txt")
    try Data("retain these notes\n".utf8).write(to: untrackedFile)

    let model = WorkspacePreviewModel()
    await model.load(path: worktree.path)
    #expect(model.workspace?.branch == "task")
    #expect(model.hasUncommittedChanges == true)
    #expect(model.launchBlockReason(path: worktree.path, createWorktree: true)?.contains("uncommitted changes") == true)
    #expect(model.launchBlockReason(path: worktree.path, createWorktree: false) == nil)
    let manager = TaskWorktreeManager()
    let store = TaskContextStore(root: root.appendingPathComponent("support"))
    let existing = try await manager.provisionAgent(ticketID: "SANITY-1", subtaskID: UUID().uuidString,
      path: worktree.path, createWorktree: false, store: store)
    #expect(existing.path == worktree.path)
    #expect(!existing.managed)

    // A changed selection cannot use the old preview before SwiftUI starts its lookup.
    #expect(model.launchBlockReason(path: repository.path, createWorktree: true)?.contains("Checking") == true)
    await model.load(path: repository.path)
    #expect(model.workspace?.branch == "main")
    #expect(model.hasUncommittedChanges == false)
    #expect(model.launchBlockReason(path: repository.path, createWorktree: true) == nil)
    let isolated = try await manager.provisionAgent(ticketID: "SANITY-1", subtaskID: UUID().uuidString,
      path: repository.path, createWorktree: true, store: store)
    #expect(isolated.managed)
    #expect(isolated.baseCommit == originalCommit)
    #expect(try Data(contentsOf: URL(fileURLWithPath: isolated.path).appendingPathComponent("user-file.txt")) == original)
    #expect(try Data(contentsOf: changedFile) == userEdits)
    #expect(FileManager.default.fileExists(atPath: untrackedFile.path))
    #expect(try await git(["rev-parse", "HEAD"], at: worktree) == originalCommit)
    #expect(try await git(["rev-parse", "HEAD"], at: repository) == originalCommit)
    print("WORKSPACE_PREVIEW_SANITY passed: dirty task checkout blocked new worktree, explicit existing checkout allowed, repository rechecked clean, new worktree used original commit, user edits preserved")
  }
}
