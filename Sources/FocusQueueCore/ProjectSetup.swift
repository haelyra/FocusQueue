import Darwin
import Foundation

public struct ProjectSetupDraft: Equatable, Sendable {
  public enum FolderMode: String, CaseIterable, Sendable { case new, existing }
  public var id = UUID().uuidString.lowercased()
  public var name = ""
  public var taskPrefix = ""
  public var folderMode: FolderMode = .existing
  public var folderPath = ""
  public var newFolderName = ""
  public var repositoryPath = ""
  public var remote = ""
  public var createRepository = false
  public var repositoryName = ""
  public var purpose = ""
  public var audience = ""
  public var successCriteria = ""
  public var documents: [URL] = []
  public var createPRD = false

  public init() {}

  public var hasValidTaskPrefix: Bool {
    taskPrefix.range(of: "^[A-Za-z]{2,5}$", options: .regularExpression) != nil
  }

  public func workingFolder(supportDirectory: URL) -> URL {
    if folderMode == .existing { return URL(fileURLWithPath: folderPath, isDirectory: true) }
    if !folderPath.isEmpty {
      return URL(fileURLWithPath: folderPath, isDirectory: true).appendingPathComponent(newFolderName, isDirectory: true)
    }
    return supportDirectory.appendingPathComponent("projects/\(id)/workspace", isDirectory: true)
  }

  public func project(supportDirectory: URL) -> ProjectDefinition {
    let directory = supportDirectory.appendingPathComponent("projects/\(id)", isDirectory: true)
    return ProjectDefinition(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      dashboardPath: directory.appendingPathComponent("dashboard.json").path,
      workspacePath: workingFolder(supportDirectory: supportDirectory).path,
      taskPrefix: taskPrefix.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
      repositoryPath: repositoryPath,
      remote: remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
        : remote.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

public struct ProjectFolderDiscovery: Equatable, Sendable {
  public struct Remote: Equatable, Sendable {
    public let name: String
    public let url: String
  }
  public let repositoryPath: String?
  public let remotes: [Remote]
  public let documents: [URL]
  public var suggestedRemote: Remote? {
    remotes.first { $0.name == "origin" }
      ?? remotes.first { ProjectCatalog.normalizedRemote($0.url)?.hasPrefix("github.com/") == true }
      ?? remotes.first
  }
}

/// Discovers local Git metadata and documentation without changing the selected folder.
public struct ProjectSetupService: Sendable {
  let runner: any ProcessRunning
  let githubExecutable: String?

  public init(runner: any ProcessRunning = FoundationProcessRunner(),
              githubExecutable: String? = SetupEnvironment.executable("gh")) {
    self.runner = runner
    self.githubExecutable = githubExecutable
  }

  public func discover(folder: String) async throws -> ProjectFolderDiscovery {
    try Self.validateFolder(folder)
    let root = try await git(["rev-parse", "--show-toplevel"], at: folder)
    var remotes: [ProjectFolderDiscovery.Remote] = []
    if let root {
      let names = try await git(["remote"], at: root) ?? ""
      for name in names.split(whereSeparator: \.isNewline).map(String.init) {
        if let url = try await git(["remote", "get-url", "--", name], at: root),
           ProjectCatalog.normalizedRemote(url) != nil {
          remotes.append(.init(name: name, url: url))
        }
      }
    }
    return ProjectFolderDiscovery(repositoryPath: root, remotes: remotes,
      documents: Self.discoverDocuments(in: URL(fileURLWithPath: folder)))
  }

  public func validate(_ draft: ProjectSetupDraft, supportDirectory: URL,
                       projects: [ProjectDefinition]) throws {
    guard draft.hasValidTaskPrefix else {
      throw Self.error("Choose a task prefix with 2 to 5 letters, without spaces or numbers.")
    }
    let project = draft.project(supportDirectory: supportDirectory)
    try ProjectCatalog.validate(projects + [project])
    guard !projects.contains(where: { $0.name.caseInsensitiveCompare(project.name) == .orderedSame }) else {
      throw Self.error("A project with this name already exists. Choose another name.")
    }
    guard !draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw Self.error("Describe the project's purpose before continuing.")
    }
    try validateWorkingFolder(draft, supportDirectory: supportDirectory)
    if !draft.repositoryPath.isEmpty { try Self.validateFolder(draft.repositoryPath) }
    let directory = try ProjectContextStore(root: supportDirectory).planURL(projectID: project.id).deletingLastPathComponent()
    for path in [directory.deletingLastPathComponent(), directory,
                 URL(fileURLWithPath: project.workspacePath).standardizedFileURL] {
      guard (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
        throw Self.error("Project setup storage is redirected. Choose a different folder.")
      }
    }
    if draft.createRepository {
      guard draft.remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw Self.error("Choose an existing repository URL or create a new repository.")
      }
      guard Self.githubRepositoryName(draft.repositoryName) != nil else {
        throw Self.error("Enter a repository name, optionally prefixed with owner/.")
      }
      guard githubExecutable != nil else {
        throw Self.error("Install GitHub CLI and run gh auth login, or use an existing repository URL.")
      }
    }
    _ = try documentPayloads(draft)
  }

  public func validateWorkingFolder(_ draft: ProjectSetupDraft, supportDirectory: URL) throws {
    if draft.folderMode == .existing { try Self.validateFolder(draft.folderPath); return }
    if draft.folderPath.isEmpty { return } // Existing callers can still request a managed workspace.
    try Self.validateFolder(draft.folderPath)
    let name = draft.newFolderName
    guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
      ![".", ".."].contains(name), !name.contains("/"), !name.contains(":"),
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw Self.error("Enter a new folder name without slashes, colons, or surrounding spaces.")
    }
    let target = draft.workingFolder(supportDirectory: supportDirectory)
    guard !FileManager.default.fileExists(atPath: target.path),
      (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw Self.error("A folder or file named \(name) already exists here. Choose another name or uncheck Create new folder.")
    }
    guard FileManager.default.isWritableFile(atPath: draft.folderPath) else {
      throw Self.error("The selected parent folder is not writable. Choose another location.")
    }
  }

  /// Updates the draft after remote creation so a failed local save can retry without creating another repository.
  public func prepare(_ draft: inout ProjectSetupDraft, supportDirectory: URL,
                      projects: [ProjectDefinition]) async throws -> ProjectDefinition {
    try validate(draft, supportDirectory: supportDirectory, projects: projects)
    var project = draft.project(supportDirectory: supportDirectory)
    let files = FileManager.default
    var repositoryToCreate: String?
    if draft.createRepository {
      // Refuse a changed folder or inherited parent repository before making a remote.
      let checkDirectory = Self.existingDirectory(for: URL(fileURLWithPath: project.workspacePath))
      if let root = try await git(["rev-parse", "--show-toplevel"], at: checkDirectory) {
        guard URL(fileURLWithPath: root).resolvingSymlinksInPath()
          == URL(fileURLWithPath: project.workspacePath).resolvingSymlinksInPath() else {
          throw Self.error("This folder is inside another repository. Choose that repository's root or a separate folder.")
        }
        guard (try await git(["remote"], at: root) ?? "").isEmpty else {
          throw Self.error("This folder already has Git remotes. Use an existing URL or choose a separate folder.")
        }
      }
      let account = try await githubAccount(at: checkDirectory)
      let check = try await checkGitHubRepository(draft.repositoryName, account: account, at: checkDirectory)
      guard check.isAvailable else { throw ProjectGitHubError.repositoryExists(check.fullName) }
      repositoryToCreate = check.fullName
    }
    if draft.folderMode == .new {
      if draft.folderPath.isEmpty {
        try files.createDirectory(atPath: project.workspacePath, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } else if mkdir(project.workspacePath, 0o700) != 0 {
        throw Self.error("The new working folder could not be created. Check that its name is unused and the parent folder is writable.")
      }
      // A later failure can reuse the folder we just created, without allowing name collisions on the first attempt.
      draft.folderMode = .existing
      draft.folderPath = project.workspacePath
    }
    if let repositoryToCreate, let gh = githubExecutable {
      if try await git(["rev-parse", "--show-toplevel"], at: project.workspacePath) == nil {
        try await requireGit(["init"], at: project.workspacePath)
      }
      let created = try await runner.run(.init(executable: gh,
        arguments: ["repo", "create", repositoryToCreate, "--private", "--source", project.workspacePath, "--remote", "origin"],
        workingDirectory: project.workspacePath, environment: ["GH_PROMPT_DISABLED": "1", "GH_HOST": "github.com"],
        timeoutSeconds: 60))
      guard created.succeeded else {
        let reason = created.timedOut ? "timed out" : "failed"
        throw Self.error("GitHub repository creation \(reason). \(created.standardError.trimmingCharacters(in: .whitespacesAndNewlines)) Check GitHub before retrying, or enter its URL.")
      }
      let detected = try? await git(["remote", "get-url", "origin"], at: project.workspacePath)
      let reported = created.standardOutput.split(whereSeparator: \.isWhitespace).map(String.init)
        .first { $0.hasPrefix("https://github.com/") && ProjectCatalog.normalizedRemote($0) != nil }
      guard let remote = detected ?? reported else {
        throw Self.error("GitHub created the repository but its URL could not be read. Enter its URL to finish setup.")
      }
      draft.remote = remote
      draft.repositoryPath = project.workspacePath
      draft.createRepository = false
      project = draft.project(supportDirectory: supportDirectory)
      try ProjectCatalog.validate(projects + [project])
    }
    if draft.repositoryPath.isEmpty,
       let repository = try await git(["rev-parse", "--show-toplevel"], at: project.workspacePath) {
      draft.repositoryPath = repository
      project = draft.project(supportDirectory: supportDirectory)
    }
    let directory = try ProjectContextStore(root: supportDirectory).planURL(projectID: project.id).deletingLastPathComponent()
    try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var payloads = try documentPayloads(draft)
    let purpose = draft.purpose.split(whereSeparator: \.isNewline).joined(separator: " ")
    payloads["plan.md"] = Data("# \(project.name)\n\n\(purpose)\n\nTasks use `\(project.taskPrefix)-###` IDs.\n".utf8)
    let context: [String: Any] = ["purpose": draft.purpose, "audience": draft.audience,
      "successCriteria": draft.successCriteria,
      "sourceDocuments": draft.documents.map(\.path),
      "links": project.remote.map { [["label": "Main repository", "url": $0, "kind": "repository"]] } ?? []]
    payloads["context.json"] = try JSONSerialization.data(withJSONObject: context, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    if draft.createPRD && payloads["prd.md"] == nil {
      payloads["prd.md"] = Data("""
      # \(project.name): Product requirements

      ## Purpose
      \(draft.purpose)

      ## Who is it for?
      \(draft.audience.isEmpty ? "To define." : draft.audience)

      ## Success criteria
      \(draft.successCriteria.isEmpty ? "To define." : draft.successCriteria)

      ## Requirements
      To define.

      ## Open questions
      To define.

      """.utf8)
    }
    // Check all collisions before writing. Never replace authored documents on a retry.
    for (name, data) in payloads {
      let target = directory.appendingPathComponent(name)
      guard (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
        throw Self.error("Project setup found a redirected \(name). Choose a new project setup.")
      }
      if files.fileExists(atPath: target.path), try Data(contentsOf: target) != data {
        throw Self.error("Project setup found an existing \(name). Keep that document and choose a new project setup.")
      }
    }
    for (name, data) in payloads {
      let target = directory.appendingPathComponent(name)
      if !files.fileExists(atPath: target.path) {
        try data.write(to: target, options: .withoutOverwriting)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      }
    }
    let dashboard = URL(fileURLWithPath: project.dashboardPath)
    guard (try? dashboard.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw Self.error("Project dashboard storage is redirected.")
    }
    if !files.fileExists(atPath: dashboard.path) {
      try Data("{\"tickets\":[]}\n".utf8).write(to: dashboard, options: .withoutOverwriting)
      try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dashboard.path)
    }
    // Project data starts empty; prompt extraction appends durable facts to it later,
    // so it stays out of the authored-document collision check above.
    try ProjectContextStore(root: supportDirectory).ensureData(projectID: project.id)
    return project
  }

  private func git(_ arguments: [String], at folder: String) async throws -> String? {
    let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: arguments,
      workingDirectory: folder, timeoutSeconds: 5))
    if result.timedOut { throw Self.error("Git discovery timed out. Check the selected folder and retry.") }
    return result.succeeded ? result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : nil
  }

  private func requireGit(_ arguments: [String], at folder: String) async throws {
    guard try await git(arguments, at: folder) != nil else { throw Self.error("Git could not initialize this project folder.") }
  }

  private static func validateFolder(_ path: String) throws {
    var isDirectory: ObjCBool = false
    guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue else { throw SetupError.invalidWorkspace }
  }

  static func existingDirectory(for url: URL) -> String {
    var current = url
    while current.path != "/", !FileManager.default.fileExists(atPath: current.path) {
      current.deleteLastPathComponent()
    }
    return current.path
  }

  private static func discoverDocuments(in root: URL) -> [URL] {
    let files = FileManager.default
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    var found: [URL] = []
    var visited = 0
    func scan(_ directory: URL, depth: Int) {
      guard found.count < 100, visited < 3000,
        let children = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
          options: [.skipsHiddenFiles]) else { return }
      for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(1000) {
        guard found.count < 100, visited < 3000 else { break }
        visited += 1
        guard let values = try? child.resourceValues(forKeys: keys),
          values.isSymbolicLink != true else { continue }
        if values.isRegularFile == true && ["md", "markdown", "txt", "pdf"].contains(child.pathExtension.lowercased()) {
          found.append(child)
        } else if values.isDirectory == true, depth < 3,
          depth > 0 || ["docs", "documentation", "documents"].contains(child.lastPathComponent.lowercased()) {
          scan(child, depth: depth + 1)
        }
      }
    }
    scan(root, depth: 0)
    return found
  }

  private func documentPayloads(_ draft: ProjectSetupDraft) throws -> [String: Data] {
    var payloads: [String: Data] = [:]
    var total = 0
    for url in Set(draft.documents) {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        ["md", "markdown", "txt", "pdf"].contains(url.pathExtension.lowercased()),
        let size = values.fileSize, size <= 10_000_000 else {
        throw Self.error("Choose a Markdown, text, or PDF document smaller than 10 MB: \(url.lastPathComponent)")
      }
      total += size
      guard total <= 40_000_000 else { throw Self.error("Choose less than 40 MB of project documentation.") }
      let base = url.deletingPathExtension().lastPathComponent.lowercased()
      var name = ["prd", "requirements", "product-requirements"].contains(base)
        && ["md", "markdown"].contains(url.pathExtension.lowercased()) ? "prd.md" : url.lastPathComponent
      if name.lowercased() == "plan.md" { name = "source-plan.md" }
      guard !payloads.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
        throw Self.error("Two documents share the name \(name). Select one copy or rename the source.")
      }
      // The limits above came from metadata; recheck them against the bytes
      // actually read, which also catches a file growing after the check.
      let data: Data
      do { data = try SafeFileRead.data(at: url, limit: 10_000_000, followSymlinks: false) }
      catch is SafeFileReadError {
        throw Self.error("Choose a Markdown, text, or PDF document smaller than 10 MB: \(url.lastPathComponent)")
      }
      total += data.count - size
      guard total <= 40_000_000 else { throw Self.error("Choose less than 40 MB of project documentation.") }
      payloads[name] = data
    }
    return payloads
  }

  private static func error(_ message: String) -> TaskContextError { .commandFailed(message) }
}
