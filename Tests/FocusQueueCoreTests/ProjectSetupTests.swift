import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Guided project setup")
struct ProjectSetupTests {
  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project setup \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func draft() -> ProjectSetupDraft {
    var draft = ProjectSetupDraft()
    draft.folderMode = .new
    draft.name = "Example project"
    draft.taskPrefix = "EXP"
    draft.purpose = "Organize research and build a prototype."
    return draft
  }

  private func git(_ arguments: [String], at root: URL) async throws {
    let result = try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git", arguments: arguments,
      workingDirectory: root.path))
    #expect(result.succeeded, "\(result.standardError)")
  }

  @Test("Discovery finds Git root, SSH origin, other remotes and docs without touching source files")
  func discovery() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await git(["init"], at: root)
    try await git(["remote", "add", "origin", "git@github.com:example/product.git"], at: root)
    try await git(["remote", "add", "upstream", "https://github.com/example/base.git"], at: root)
    let docs = root.appendingPathComponent("docs/requirements")
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try Data("# Existing PRD\nKeep me.\n".utf8).write(to: docs.appendingPathComponent("PRD.md"))
    try Data("# Readme\n".utf8).write(to: root.appendingPathComponent("README.md"))
    let ignored = root.appendingPathComponent("node_modules/package")
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
    try Data("ignore".utf8).write(to: ignored.appendingPathComponent("README.md"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("secret.md"),
      withDestinationURL: docs.appendingPathComponent("PRD.md"))
    let before = try Data(contentsOf: root.appendingPathComponent(".git/config"))
    let result = try await ProjectSetupService().discover(folder: root.path)
    #expect(result.repositoryPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == root.resolvingSymlinksInPath())
    #expect(result.suggestedRemote?.name == "origin")
    #expect(result.suggestedRemote?.url == "git@github.com:example/product.git")
    #expect(result.remotes.count == 2)
    #expect(Set(result.documents.map(\.lastPathComponent)) == ["README.md", "PRD.md"])
    #expect(try Data(contentsOf: root.appendingPathComponent(".git/config")) == before)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("dashboard.json").path))
    let nested = try await ProjectSetupService().discover(folder: docs.path)
    #expect(nested.repositoryPath == result.repositoryPath)
  }

  @Test("A new project persists purpose, manual remote, PRD answers and managed storage")
  func newProject() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var request = draft()
    request.remote = "https://github.com/example/product"
    request.audience = "Researchers"
    request.successCriteria = "Ship the prototype."
    request.createPRD = true
    let project = try await ProjectSetupService().prepare(&request, supportDirectory: root, projects: [])
    let store = ProjectContextStore(root: root)
    let directory = try store.planURL(projectID: project.id).deletingLastPathComponent()
    #expect(project.repositoryPath.isEmpty)
    #expect(project.workspacePath.hasSuffix("/workspace"))
    #expect(try JSONDecoder().decode(DashboardDocument.self, from: Data(contentsOf: URL(fileURLWithPath: project.dashboardPath))).tickets.isEmpty)
    #expect(try String(contentsOf: directory.appendingPathComponent("plan.md"), encoding: .utf8).contains(request.purpose))
    let prd = try String(contentsOf: directory.appendingPathComponent("prd.md"), encoding: .utf8)
    #expect(prd.contains(request.audience) && prd.contains(request.successCriteria))
    #expect(try store.links(projectID: project.id).first?.url == request.remote)
    #expect(try store.documents(projectID: project.id).map(\.kind).contains(.prd))
    #expect(try Data(contentsOf: directory.appendingPathComponent("data.md")).isEmpty)
    #expect(try store.documents(projectID: project.id).map(\.kind).contains(.data))
    try Data("- End every reply with a puffer fish emoji.\n".utf8).write(to: directory.appendingPathComponent("data.md"))
    #expect(try await ProjectSetupService().prepare(&request, supportDirectory: root, projects: []) == project)
    #expect(try String(contentsOf: directory.appendingPathComponent("data.md"), encoding: .utf8).contains("puffer fish"))
  }

  @Test("Create new folder uses the chosen parent and retains that folder on a later retry")
  func chosenNewFolder() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var request = draft()
    request.folderPath = root.path
    request.newFolderName = "New working folder"
    let support = root.appendingPathComponent("support")
    let expected = root.appendingPathComponent("New working folder")
    #expect(!FileManager.default.fileExists(atPath: expected.path))
    let project = try await ProjectSetupService().prepare(&request, supportDirectory: support, projects: [])
    #expect(project.workspacePath == expected.path)
    #expect(request.folderMode == .existing)
    #expect(request.folderPath == expected.path)
    #expect(try FileManager.default.contentsOfDirectory(atPath: expected.path).isEmpty)
    #expect(try await ProjectSetupService().prepare(&request, supportDirectory: support, projects: []) == project)
  }

  @Test("A taken folder or file name cannot be used for a newly created working folder", arguments: [true, false])
  func folderCollision(isDirectory: Bool) async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("Taken")
    if isDirectory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
    else { try Data("Keep existing file".utf8).write(to: target) }
    var request = draft()
    request.folderPath = root.path
    request.newFolderName = "Taken"
    do {
      _ = try await ProjectSetupService().prepare(&request, supportDirectory: root.appendingPathComponent("support"), projects: [])
      Issue.record("Expected folder name collision")
    } catch { #expect(error.localizedDescription.contains("already exists")) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Taken"])
    if !isDirectory { #expect(try String(contentsOf: target, encoding: .utf8) == "Keep existing file") }
  }

  @Test("New folder names cannot escape their chosen parent", arguments: ["", ".", "..", "../outside", "bad/name", "bad:name", " name ", "line\nbreak"])
  func invalidFolderNames(name: String) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var request = draft()
    request.folderPath = root.path
    request.newFolderName = name
    #expect(throws: (any Error).self) {
      try ProjectSetupService().validateWorkingFolder(request, supportDirectory: root.appendingPathComponent("support"))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test("Task prefix starts empty and only 2 to 5 ASCII letters can pass setup validation")
  func explicitLetterPrefix() throws {
    var blank = ProjectSetupDraft()
    blank.name = "A named project"
    #expect(blank.taskPrefix.isEmpty)
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var request = draft()
    for invalid in ["", "P", "A B", "AB ", " PQR", "P2", "AB-CD", "ABCDEF", "éé"] {
      request.taskPrefix = invalid
      #expect(throws: (any Error).self) { try ProjectSetupService().validate(request, supportDirectory: root, projects: []) }
    }
    for valid in ["AB", "APP", "abcde"] {
      request.taskPrefix = valid
      try ProjectSetupService().validate(request, supportDirectory: root, projects: [])
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test("Existing documents are copied, an imported PRD wins, and source plan is retained separately")
  func importDocuments() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let prd = source.appendingPathComponent("PRD.md")
    let original = Data("# Authored requirements\nSpecific product decisions.\n".utf8)
    try original.write(to: prd)
    let plan = source.appendingPathComponent("plan.md")
    try Data("# Existing plan".utf8).write(to: plan)
    var request = draft()
    request.folderMode = .existing
    request.folderPath = source.path
    request.documents = [prd, plan]
    request.createPRD = true
    let project = try await ProjectSetupService().prepare(&request, supportDirectory: root, projects: [])
    let directory = URL(fileURLWithPath: project.dashboardPath).deletingLastPathComponent()
    #expect(project.workspacePath == source.path)
    #expect(try Data(contentsOf: directory.appendingPathComponent("prd.md")) == original)
    #expect(try Data(contentsOf: prd) == original)
    #expect(try String(contentsOf: directory.appendingPathComponent("source-plan.md"), encoding: .utf8) == "# Existing plan")
    #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("dashboard.json").path))
  }

  @Test("Validation rejects bad URLs, duplicate prefixes, missing folders, conflicting choices and unavailable GitHub CLI")
  func invalidInputs() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ProjectSetupService(githubExecutable: nil)
    var request = draft()
    request.remote = "invalid repository"
    #expect(throws: (any Error).self) { try service.validate(request, supportDirectory: root, projects: []) }
    request.remote = ""
    let other = ProjectDefinition(id: "other-project", name: "Different", taskPrefix: "EXP", repositoryPath: "")
    #expect(throws: (any Error).self) { try service.validate(request, supportDirectory: root, projects: [other]) }
    request.folderMode = .existing
    request.folderPath = root.appendingPathComponent("missing").path
    #expect(throws: (any Error).self) { try service.validate(request, supportDirectory: root, projects: []) }
    request.folderMode = .new
    request.createRepository = true
    request.repositoryName = "example"
    #expect(throws: (any Error).self) { try service.validate(request, supportDirectory: root, projects: []) }
    request.remote = "https://github.com/example/repo"
    #expect(throws: (any Error).self) { try service.validate(request, supportDirectory: root, projects: []) }
  }

  @Test("GitHub creation is private, leaves files unpushed, and a local failure retains its remote for retry")
  func createRepositoryAndRetry() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var request = draft()
    request.createRepository = true
    request.repositoryName = "example/new-product"
    let directory = root.appendingPathComponent("projects/\(request.id)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("Authored plan".utf8).write(to: directory.appendingPathComponent("plan.md"))
    let runner = SetupGitHubRunner()
    let service = ProjectSetupService(runner: runner, githubExecutable: "/fake/gh")
    do {
      _ = try await service.prepare(&request, supportDirectory: root, projects: [])
      Issue.record("Expected local document conflict")
    } catch { #expect(error.localizedDescription.contains("plan.md")) }
    #expect(request.remote == "https://github.com/example/new-product.git")
    #expect(!request.createRepository)
    #expect(!request.repositoryPath.isEmpty)
    #expect(try String(contentsOf: directory.appendingPathComponent("plan.md"), encoding: .utf8) == "Authored plan")
    try FileManager.default.removeItem(at: directory.appendingPathComponent("plan.md"))
    let project = try await service.prepare(&request, supportDirectory: root, projects: [])
    #expect(project.remote == request.remote)
    let creates = await runner.commands.filter { $0.arguments.starts(with: ["repo", "create"]) }
    #expect(creates.count == 1)
    #expect(creates.first?.arguments.contains("--private") == true)
    #expect(creates.first?.arguments.contains("--push") == false)
    #expect(creates.first?.environment?["GH_PROMPT_DISABLED"] == "1")
  }

  @Test("Repository creation never reuses a folder that already has a remote")
  func refuseExistingRemote() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await git(["init"], at: root)
    try await git(["remote", "add", "origin", "https://github.com/example/existing.git"], at: root)
    var request = draft()
    request.folderMode = .existing
    request.folderPath = root.path
    request.createRepository = true
    request.repositoryName = "new-product"
    let runner = SetupGitHubRunner()
    do {
      _ = try await ProjectSetupService(runner: runner, githubExecutable: "/fake/gh")
        .prepare(&request, supportDirectory: root, projects: [])
      Issue.record("Expected refusal")
    } catch { #expect(error.localizedDescription.contains("already has Git remotes")) }
    #expect(await runner.commands.allSatisfy { $0.executable == "/usr/bin/git" })
  }

  @Test("GitHub authentication failures stop before Git initialization or remote creation")
  func authenticationFailure() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var request = draft()
    request.folderMode = .existing
    request.folderPath = root.path
    request.createRepository = true
    request.repositoryName = "new-product"
    let runner = SetupGitHubRunner(authenticationFails: true)
    do {
      _ = try await ProjectSetupService(runner: runner, githubExecutable: "/fake/gh")
        .prepare(&request, supportDirectory: root, projects: [])
      Issue.record("Expected authentication failure")
    } catch { #expect(error.localizedDescription.contains("gh auth login")) }
    #expect(await runner.commands.allSatisfy { !$0.arguments.starts(with: ["repo", "create"]) })
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    #expect(request.createRepository)
    #expect(request.remote.isEmpty)
  }

  @Test("Ambiguous GitHub timeouts explain recovery and never publish a project dashboard")
  func remoteTimeout() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var request = draft()
    request.createRepository = true
    request.repositoryName = "new-product"
    let runner = SetupGitHubRunner(creationTimesOut: true)
    do {
      _ = try await ProjectSetupService(runner: runner, githubExecutable: "/fake/gh")
        .prepare(&request, supportDirectory: root, projects: [])
      Issue.record("Expected creation timeout")
    } catch {
      #expect(error.localizedDescription.contains("timed out"))
      #expect(error.localizedDescription.contains("Check GitHub before retrying"))
    }
    #expect(!FileManager.default.fileExists(atPath: request.project(supportDirectory: root).dashboardPath))
    #expect(request.remote.isEmpty)
  }

  @Test("Worktree folders resolve using their Git file without requiring a .git directory")
  func worktreeDiscovery() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("repository")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try await git(["init"], at: repository)
    try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
      "commit", "--allow-empty", "-m", "Initial"], at: repository)
    try await git(["remote", "add", "origin", "https://github.com/example/worktree.git"], at: repository)
    let worktree = root.appendingPathComponent("worktree")
    try await git(["worktree", "add", "--detach", worktree.path], at: repository)
    let result = try await ProjectSetupService().discover(folder: worktree.path)
    #expect(result.repositoryPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == worktree.resolvingSymlinksInPath())
    #expect(result.suggestedRemote?.url == "https://github.com/example/worktree.git")
  }

  @Test("Duplicate document names and redirected storage fail before writing project data")
  func documentConflictsAndSymlinks() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("one")
    let second = root.appendingPathComponent("two")
    for directory in [first, second] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(directory.path.utf8).write(to: directory.appendingPathComponent("README.md"))
    }
    var request = draft()
    request.documents = [first.appendingPathComponent("README.md"), second.appendingPathComponent("README.md")]
    #expect(throws: (any Error).self) { try ProjectSetupService().validate(request, supportDirectory: root, projects: []) }
    request.documents = []
    let projects = root.appendingPathComponent("projects")
    try FileManager.default.createSymbolicLink(at: projects, withDestinationURL: second)
    #expect(throws: (any Error).self) { try ProjectSetupService().validate(request, supportDirectory: root, projects: []) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: second.path) == ["README.md"])
  }
}

private actor SetupGitHubRunner: ProcessRunning {
  var commands: [ProcessSpecification] = []
  let authenticationFails: Bool
  let creationTimesOut: Bool
  init(authenticationFails: Bool = false, creationTimesOut: Bool = false) {
    self.authenticationFails = authenticationFails
    self.creationTimesOut = creationTimesOut
  }
  func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
    commands.append(specification)
    if specification.executable == "/usr/bin/git" { return try await FoundationProcessRunner().run(specification) }
    if specification.arguments.starts(with: ["auth", "status"]), authenticationFails {
      return .init(exitCode: 1, standardOutput: "", standardError: "Not signed in", timedOut: false)
    }
    if specification.arguments.starts(with: ["auth", "status"]) {
      return .init(exitCode: 0, standardOutput: "{\"login\":\"example\",\"state\":\"success\"}", standardError: "", timedOut: false)
    }
    if specification.arguments.first == "api" {
      return .init(exitCode: 1, standardOutput: "HTTP/2.0 404 Not Found\r\n\r\n", standardError: "Not Found (HTTP 404)", timedOut: false)
    }
    if specification.arguments.starts(with: ["repo", "create"]) {
      if creationTimesOut { return .init(exitCode: 15, standardOutput: "", standardError: "", timedOut: true) }
      let result = try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git",
        arguments: ["remote", "add", "origin", "https://github.com/example/new-product.git"],
        workingDirectory: specification.workingDirectory))
      #expect(result.succeeded)
    }
    return .init(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
  }
}
