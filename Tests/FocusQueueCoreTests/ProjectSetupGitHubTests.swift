import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Project setup GitHub preflight")
struct ProjectSetupGitHubTests {
  private func root() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("github setup \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test("Active GitHub account uses structured status without exposing tokens")
  func activeAccount() async throws {
    let runner = GitHubPreflightRunner()
    let login = try await ProjectSetupService(runner: runner, githubExecutable: "/fake/gh").githubAccount(at: "/tmp")
    #expect(login == "example")
    let command = try #require(await runner.commands.first)
    #expect(command.arguments.contains("--active"))
    #expect(command.arguments.contains("--json"))
    #expect(!command.arguments.contains("--show-token"))
    #expect(command.workingDirectory == "/tmp")
    #expect(command.environment?["GH_PROMPT_DISABLED"] == "1")
  }

  @Test("Signed-out JSON cannot be mistaken for an authenticated account even with exit zero")
  func signedOutJSON() async throws {
    let runner = GitHubPreflightRunner(auth: .init(exitCode: 0, standardOutput: "{}", standardError: "", timedOut: false))
    do {
      _ = try await ProjectSetupService(runner: runner, githubExecutable: "/fake/gh").githubAccount(at: "/tmp")
      Issue.record("Expected sign-in requirement")
    } catch { #expect(error as? ProjectGitHubError == .signInRequired) }
  }

  @Test("Duplicate repository names are rejected before creating a folder or running Git init")
  func duplicateBeforeCreation() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = GitHubPreflightRunner(responses: [200])
    var request = ProjectSetupDraft()
    request.name = "New project"
    request.taskPrefix = "NEW"
    request.purpose = "Check duplicate repository handling."
    request.folderMode = .new
    request.folderPath = directory.path
    request.newFolderName = "New working folder"
    request.createRepository = true
    request.repositoryName = "taken"
    do {
      _ = try await ProjectSetupService(runner: runner, githubExecutable: "/fake/gh")
        .prepare(&request, supportDirectory: directory.appendingPathComponent("support"), projects: [])
      Issue.record("Expected duplicate rejection")
    } catch { #expect(error as? ProjectGitHubError == .repositoryExists("example/taken")) }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(request.newFolderName).path))
    let commands = await runner.commands
    #expect(!commands.contains { $0.arguments == ["init"] || $0.arguments.starts(with: ["repo", "create"]) })
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test("Creation rechecks a name that became occupied after the initial wizard check")
  func nameClaimedAfterCheck() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = GitHubPreflightRunner(responses: [404, 200])
    let service = ProjectSetupService(runner: runner, githubExecutable: "/fake/gh")
    #expect(try await service.checkGitHubRepository("taken", account: "example", at: directory.path).isAvailable)
    var request = ProjectSetupDraft()
    request.name = "New project"
    request.taskPrefix = "NEW"
    request.purpose = "Check repository name races."
    request.folderPath = directory.path
    request.createRepository = true
    request.repositoryName = "taken"
    do {
      _ = try await service.prepare(&request, supportDirectory: directory.appendingPathComponent("support"), projects: [])
      Issue.record("Expected second check to reject the occupied name")
    } catch { #expect(error as? ProjectGitHubError == .repositoryExists("example/taken")) }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path))
  }

  @Test("Only a repository 404 indicates an unused name", arguments: [200, 404, 401, 403, 429, 500, 0])
  func repositoryStatuses(status: Int) async throws {
    let runner = GitHubPreflightRunner(responses: [status])
    do {
      let result = try await ProjectSetupService(runner: runner, githubExecutable: "/fake/gh")
        .checkGitHubRepository("product", account: "example", at: "/tmp")
      #expect([200, 404].contains(status))
      #expect(result.isAvailable == (status == 404))
      #expect(result.fullName == "example/product")
    } catch { #expect(![200, 404].contains(status)) }
    let command = try #require(await runner.commands.first)
    #expect(command.arguments.contains("GET"))
    #expect(command.arguments.last == "repos/example/product")
  }

  @Test("Repository inputs accept GitHub URLs and owner/name while rejecting malformed endpoints")
  func repositoryInputs() async throws {
    for value in ["product", "my-org/product", "https://github.com/my-org/product.git", "github.com/my-org/product",
                  "git@github.com:my-org/product.git"] {
      #expect(ProjectSetupService.githubRepositoryName(value) != nil)
    }
    for value in ["", "../product", "/product", "owner/../product", "bad name", "owner/repo?param=x",
                  "https://gitlab.com/owner/product", "owner/repo/extra", "...", "owner_name/repo"] {
      #expect(ProjectSetupService.githubRepositoryName(value) == nil)
    }
    let runner = GitHubPreflightRunner(responses: [200])
    let result = try await ProjectSetupService(runner: runner, githubExecutable: "/fake/gh")
      .checkGitHubRepository("https://github.com/My-Org/Product.git", account: "example", at: "/tmp")
    #expect(result.fullName == "my-org/product")
    #expect(result.url == "https://github.com/my-org/product")
    #expect(!result.isAvailable)
  }

  @Test("GitHub timeouts remain unchecked instead of reporting an available name")
  func timeout() async throws {
    let runner = GitHubPreflightRunner(timesOut: true)
    do {
      _ = try await ProjectSetupService(runner: runner, githubExecutable: "/fake/gh")
        .checkGitHubRepository("product", account: "example", at: "/tmp")
      Issue.record("Expected timeout")
    } catch { #expect(error.localizedDescription.contains("timed out")) }
  }

  @Test("Sign-in command safely quotes the chosen folder")
  func signInDirectory() throws {
    let command = ProjectSetupService.githubSignInCommand(at: "/tmp/People's project $(touch nope)")
    #expect(command == "cd '/tmp/People'\\''s project $(touch nope)' && gh auth login --hostname github.com")
  }

  @Test("Live read-only GitHub sanity: signed-in account, an existing repository and an unused name",
    .enabled(if: ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_GITHUB_READ_CHECKS"] == "1"))
  func liveReadOnlyGitHub() async throws {
    let service = ProjectSetupService()
    let account = try await service.githubAccount(at: "/tmp")
    #expect(!account.isEmpty)
    let existing = try await service.checkGitHubRepository("haelyra/ECCFocusQueue", account: account, at: "/tmp")
    #expect(!existing.isAvailable)
    let unused = try await service.checkGitHubRepository("focus-queue-check-\(UUID().uuidString.lowercased())", account: account, at: "/tmp")
    #expect(unused.isAvailable)
  }
}

private actor GitHubPreflightRunner: ProcessRunning {
  var commands: [ProcessSpecification] = []
  var responses: [Int]
  let auth: ProcessResult
  let timesOut: Bool
  init(responses: [Int] = [404], auth: ProcessResult = .init(exitCode: 0,
       standardOutput: "{\"login\":\"example\",\"state\":\"success\"}", standardError: "", timedOut: false),
       timesOut: Bool = false) {
    self.responses = responses
    self.auth = auth
    self.timesOut = timesOut
  }
  func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
    commands.append(specification)
    if specification.executable == "/usr/bin/git" { return try await FoundationProcessRunner().run(specification) }
    if specification.arguments.starts(with: ["auth", "status"]) { return auth }
    if specification.arguments.first == "api" {
      if timesOut { return .init(exitCode: 15, standardOutput: "", standardError: "", timedOut: true) }
      let status = responses.isEmpty ? 404 : responses.removeFirst()
      return .init(exitCode: status == 200 ? 0 : 1,
        standardOutput: status == 0 ? "" : "HTTP/2.0 \(status) Response\r\n\r\n", standardError: "", timedOut: false)
    }
    Issue.record("Unexpected GitHub mutation during preflight: \(specification.arguments)")
    return .init(exitCode: 1, standardOutput: "", standardError: "Unexpected command", timedOut: false)
  }
}
