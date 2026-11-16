import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Task search files")
struct TaskSearchFilesTests {
  private let tickets = [
    DashboardTicket(id: "FOC-1", title: "Queue polish", status: "open", summary: ""),
    DashboardTicket(id: "FOC-2", title: "Release work", status: "done", summary: ""),
  ]

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fq-search-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("Worktree files are searched only when no context-folder file matches")
  func worktreeFallback() {
    let worktree = ["FOC-2": ["Sources/App/QueueView.swift"], "FOC-1": ["README.md"]]
    let fallback = TaskSearch.search(tickets, query: "QueueView.swift",
      files: ["FOC-1": ["plan.md"]], worktreeFiles: worktree)
    #expect(fallback.tickets.map(\.id) == ["FOC-2"])
    #expect(fallback.fileSource == .worktree)
    #expect(fallback.fileMatches == ["FOC-2": ["Sources/App/QueueView.swift"]])

    let context = TaskSearch.search(tickets, query: "readme",
      files: ["FOC-2": ["evidence/readme-draft.md"]], worktreeFiles: worktree)
    #expect(context.fileSource == .context)
    #expect(context.tickets.map(\.id) == ["FOC-2"], "a context match hides worktree matches")
  }

  @Test("A context folder lists every file except locks and archived snapshots")
  func contextFolderListsEverything() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for path in ["plan.md", "agent-log.md", "evidence/shot.png", "canvas/a.json", "canvas/a.lock",
      "archive/snapshot-1/plan.md", ".hidden"] {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: url)
    }
    let listed = Set(TaskSearchFiles.contextFiles(root).map(\.relativePath))
    #expect(listed == ["plan.md", "agent-log.md", "evidence/shot.png", "canvas/a.json"])
  }

  @Test("Only worktrees owned by one task are searched, never a project's own checkout")
  func uniqueWorktrees() {
    func context(_ id: String, _ paths: [String]) -> TaskContext {
      var context = TaskContext(ticketID: id, title: id, summary: "", successCriteria: "",
        planPath: "/tmp/\(id)/plan.md", updatedAt: Date())
      context.projectRepositoryPath = "/repo"
      context.subtasks = paths.map { path in
        var subtask = TaskSubtask(title: "agent")
        subtask.workspace = AgentWorkspace(path: path, repositoryPath: "/repo", baseCommit: "abc", managed: true)
        return subtask
      }
      return context
    }
    var emptyRepository = context("FOC-4", [])
    var blank = TaskSubtask(title: "agent")
    blank.workspace = AgentWorkspace(path: "/elsewhere", repositoryPath: "")
    emptyRepository.subtasks = [blank]
    emptyRepository.repositoryPath = ""
    var selfNamed = context("FOC-3", [])
    var subtask = TaskSubtask(title: "agent")
    subtask.workspace = AgentWorkspace(path: "/repo/.worktrees/three", repositoryPath: "/repo/.worktrees/three")
    selfNamed.subtasks = [subtask]
    let found = TaskSearchFiles.uniqueWorktrees([
      context("FOC-1", ["/repo/.worktrees/one", "/repo", "/shared"]),
      context("FOC-2", ["/shared", "/repo/.worktrees/two"]),
      selfNamed, emptyRepository,
    ])
    // An empty repository path must not resolve to the current directory and hide its worktree.
    let current = TaskSearchFiles.uniqueWorktrees([
      context("FOC-5", [FileManager.default.currentDirectoryPath]), emptyRepository,
    ])
    #expect(current["FOC-5"]?.count == 1)
    #expect(found["FOC-3"]?.map(\.path) == ["/repo/.worktrees/three"], "a workspace naming itself as its repository stays")
    #expect(found["FOC-1"]?.map(\.path) == ["/repo/.worktrees/one"])
    #expect(found["FOC-2"]?.map(\.path) == ["/repo/.worktrees/two"])
    #expect(found["FOC-1"]?.first?.baseCommit == "abc")
  }

  @Test("A worktree lists files added or changed since its base and untracked files, not deleted ones")
  func worktreeChangedFiles() async throws {
    let repo = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: repo) }
    func git(_ arguments: String...) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@example.com"] + arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe()
      try process.run()
      process.waitUntilExit()
      return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func write(_ path: String, _ text: String = "x") throws {
      let url = repo.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    _ = try git("init", "-q")
    try write("unchanged.txt"); try write("gone.txt"); try write("edited.txt")
    try write(".gitignore", "ignored.log\n")
    _ = try git("add", "-A"); _ = try git("commit", "-qm", "base")
    let base = try git("rev-parse", "HEAD")
    try write("Sources/added.swift"); _ = try git("add", "-A"); _ = try git("commit", "-qm", "work")
    try write("edited.txt", "changed"); try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
    try write("notes/untracked.md"); try write("ignored.log")

    let files = await TaskSearchFiles.worktreeFiles(.init(path: repo.path, baseCommit: base))
    #expect(Set(files.map(\.relativePath)) == ["Sources/added.swift", "edited.txt", "notes/untracked.md"])
    let uncommitted = await TaskSearchFiles.worktreeFiles(.init(path: repo.path))
    #expect(Set(uncommitted.map(\.relativePath)) == ["edited.txt", "notes/untracked.md"])
  }

  @Test("Tasks found only through a file are flagged so they show as file results")
  func fileOnlyFlag() {
    let result = TaskSearch.search(tickets, query: "polish", files: ["FOC-2": ["evidence/polish-notes.md"]])
    #expect(result.tickets.map(\.id) == ["FOC-1", "FOC-2"])
    #expect(result.fileOnlyIDs == ["FOC-2"])
  }

  @Test("Linked files keep the newest view first, drop missing files from search, and stay out of outputs")
  func linkedFiles() throws {
    let context = try temporaryDirectory()
    let outside = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: context); try? FileManager.default.removeItem(at: outside) }
    let first = outside.appendingPathComponent("a.swift"), second = outside.appendingPathComponent("b.swift")
    try Data("a".utf8).write(to: first)
    try Data("b".utf8).write(to: second)
    #expect(try TaskLinkedFiles.record(first, displayPath: "Sources/a.swift", in: context))
    #expect(try TaskLinkedFiles.record(second, displayPath: "Sources/b.swift", in: context))
    #expect(try TaskLinkedFiles.record(first, displayPath: "Sources/a.swift", in: context))
    #expect(try !TaskLinkedFiles.record(first, displayPath: "Sources/a.swift", in: context), "already first")
    #expect(TaskLinkedFiles.load(context).map(\.displayPath) == ["Sources/a.swift", "Sources/b.swift"])

    try FileManager.default.removeItem(at: second)
    #expect(TaskLinkedFiles.searchFiles(context).map(\.relativePath) == ["Sources/a.swift"])
    #expect(TaskOutputs.scan(context).isEmpty, "the link record is not an agent output")
  }
}
