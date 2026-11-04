import AppKit
import Foundation
import FocusQueueCore
import SwiftUI
import Testing
@testable import ECCFocusQueue

/// Exercises the same discovery, submission, storage and task creation path used by the wizard.
/// No simulated input, application activation, terminal changes or network requests.
@Suite("Project creation workflow", .serialized)
@MainActor
struct ProjectCreationWorkflowTests {
  private func model(at root: URL, repository: (any ConfigurationLoading)? = nil) async -> QueueViewModel {
    let model = QueueViewModel(paths: AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path]),
      configurationRepository: repository, terminalController: ProjectSetupExternalBoundary(),
      pullRequestQueueLoader: ProjectSetupExternalBoundary(), discoverExternalAgents: { [] },
      labelTmuxPane: { _, _ in }, maintenanceEnabled: false, locateExistingAgent: { _, _ in nil })
    await model.bootstrap()
    await model.bootstrapTail?.value
    #expect(model.loadError == nil)
    return model
  }

  private func request() -> ProjectSetupDraft {
    var draft = ProjectSetupDraft()
    draft.folderMode = .new
    draft.name = "Wizard workflow"
    draft.taskPrefix = "WIZ"
    draft.purpose = "Help a team organize its prototype and requirements."
    draft.audience = "A small product team"
    draft.successCriteria = "A usable prototype with documented requirements."
    return draft
  }

  @Test("Connect folder, detect remote and PRD, submit, create a task, and reload persisted project")
  func existingProjectWorkflow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wizard workflow \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    let source = root.appendingPathComponent("existing project")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for arguments in [["init"], ["remote", "add", "origin", "git@github.com:example/wizard.git"]] {
      let result = try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git",
        arguments: arguments, workingDirectory: source.path))
      #expect(result.succeeded)
    }
    let prd = source.appendingPathComponent("PRD.md")
    let authored = Data("# Product requirements\n\nShip a usable prototype.\n".utf8)
    try authored.write(to: prd)
    let gitConfig = try Data(contentsOf: source.appendingPathComponent(".git/config"))
    let model = await model(at: support)
    let priorProjects = model.config.projects
    let service = ProjectSetupService()
    let discovery = try await service.discover(folder: source.path)
    var draft = request()
    draft.folderMode = .existing
    draft.folderPath = source.path
    draft.repositoryPath = discovery.repositoryPath ?? ""
    draft.remote = discovery.suggestedRemote?.url ?? ""
    draft.documents = discovery.documents
    draft.createPRD = true
    #expect(await model.createProject(&draft, service: service))
    #expect(model.config.projects.count == priorProjects.count + 1)
    #expect(model.projectError == nil)
    #expect(!model.isSavingProject)
    let project = try #require(model.config.projects.first { $0.id == draft.id })
    #expect(project.remote == "git@github.com:example/wizard.git")
    #expect(project.repositoryPath == discovery.repositoryPath)
    #expect(project.workspacePath == source.path)
    #expect(!project.dashboardPath.hasPrefix(source.path + "/"))
    #expect(try Data(contentsOf: source.appendingPathComponent(".git/config")) == gitConfig)
    #expect(try Data(contentsOf: prd) == authored)
    #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() == [".git", "PRD.md"])
    let directory = try model.projectContextStore.planURL(projectID: project.id).deletingLastPathComponent()
    #expect(try Data(contentsOf: directory.appendingPathComponent("prd.md")) == authored)
    #expect(try model.projectContextStore.links(projectID: project.id).first?.url == draft.remote)
    #expect(await model.selectProject(id: project.id))
    #expect(await model.createTask(title: "First task", summary: "Verify the newly created project's queue", projectID: project.id))
    #expect(model.openTickets.first?.id == "WIZ-001")
    let saved = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: model.configurationURL))
    #expect(saved.projects.contains(project))
    #expect(priorProjects.allSatisfy { saved.projects.contains($0) })
    let restarted = await self.model(at: support)
    #expect(restarted.config.projects.contains(project))
    #expect(restarted.selectedProjectID == project.id)
    #expect(restarted.openTickets.contains { $0.id == "WIZ-001" })
    #expect(try String(contentsOf: directory.appendingPathComponent("plan.md"), encoding: .utf8).contains(draft.purpose))
  }

  @Test("A failed configuration save preserves the catalog and draft, then retry registers one project")
  func failedSaveAndRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wizard retry \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = FailingProjectSetupConfiguration(url: root.appendingPathComponent("config.json"))
    let model = await model(at: root, repository: repository)
    let before = model.config
    let bytes = try Data(contentsOf: model.configurationURL)
    var draft = request()
    draft.remote = "https://github.com/example/manual"
    draft.createPRD = true
    await repository.failNextSave()
    #expect(await model.createProject(&draft) == false)
    #expect(model.projectError?.contains("Simulated save failure") == true)
    #expect(model.config == before)
    #expect(try Data(contentsOf: model.configurationURL) == bytes)
    #expect(!model.isSavingProject)
    #expect(await model.createProject(&draft))
    #expect(model.projectError == nil)
    #expect(model.config.projects.filter { $0.id == draft.id }.count == 1)
    #expect(await model.selectProject(id: draft.id))
    #expect(await model.createTask(title: "New workspace task", summary: "Verify managed workspace", projectID: draft.id))
    #expect(model.openTickets.first?.id == "WIZ-001")
  }

  @Test("Create new working folder outside managed storage, save the project, create a task and reload")
  func createChosenWorkingFolderWorkflow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("new working folder \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("Parent's projects")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let support = root.appendingPathComponent("support")
    let model = await model(at: support)
    var request = ProjectSetupDraft()
    request.name = "Folder creation workflow"
    request.folderMode = .new
    request.folderPath = parent.path
    request.newFolderName = "New project folder"
    request.purpose = "Exercise the explicit folder creation option through app persistence."
    #expect(request.taskPrefix.isEmpty)
    #expect(await model.createProject(&request) == false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    request.taskPrefix = "FOL"
    #expect(await model.createProject(&request))
    let project = try #require(model.config.projects.first { $0.id == request.id })
    #expect(project.workspacePath == parent.appendingPathComponent("New project folder").path)
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.workspacePath).isEmpty)
    #expect(await model.selectProject(id: project.id))
    #expect(await model.createTask(title: "Folder task", summary: "Verify the chosen working folder", projectID: project.id))
    #expect(model.openTickets.contains { $0.id == "FOL-001" })
    let restarted = await self.model(at: support)
    #expect(restarted.config.projects.contains(project))
    #expect(restarted.openTickets.contains { $0.id == "FOL-001" })
  }

  @Test("Delete a selected project, reload, preserve working files and documents, and protect Other")
  func deleteProjectWorkflow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("delete workflow \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = await model(at: root)
    var draft = request()
    #expect(await model.createProject(&draft))
    #expect(await model.selectProject(id: draft.id))
    #expect(await model.createTask(title: "Remove queue data", summary: "", projectID: draft.id))
    let project = try #require(model.selectedProject)
    let source = URL(fileURLWithPath: project.workspacePath).appendingPathComponent("source.txt")
    try Data("keep me".utf8).write(to: source)
    let plan = try model.projectContextStore.planURL(projectID: draft.id)
    let authored = try Data(contentsOf: plan)
    let otherProjects = model.config.projects.filter { $0.id != draft.id }
    #expect(await model.deleteProject(id: draft.id))
    #expect(model.config.projects == otherProjects)
    #expect(model.selectedProjectID != draft.id)
    #expect(!model.dashboard.tickets.contains { $0.id == "WIZ-001" })
    #expect(!FileManager.default.fileExists(atPath: project.dashboardPath))
    #expect(try String(contentsOf: source, encoding: .utf8) == "keep me")
    #expect(try Data(contentsOf: plan) == authored)
    let restarted = await self.model(at: root)
    #expect(!restarted.config.projects.contains { $0.id == draft.id })
    #expect(await restarted.deleteProject(id: ProjectCatalog.otherID) == false)
    #expect(restarted.config.projects.contains { $0.id == ProjectCatalog.otherID })
  }

  @Test("Invalid setup creates no files and changes no project configuration")
  func rejectedSetup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wizard invalid \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = await model(at: root)
    let original = model.config
    var draft = request()
    draft.remote = "not a repository"
    #expect(await model.createProject(&draft) == false)
    #expect(model.config == original)
    #expect(model.projectError != nil)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/\(draft.id)").path))
  }

  @Test("Every wizard page lays out offscreen and opening the wizard leaves storage unchanged")
  func offscreenWizardPages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wizard pages \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = await model(at: root)
    let original = try Data(contentsOf: model.configurationURL)
    var draft = request()
    draft.remote = "https://github.com/example/manual"
    for step in ProjectCreationStep.allCases {
      let host = NSHostingView(rootView: ProjectCreationWizard(model: model, draft: draft, step: step,
        service: ProjectSetupService(githubExecutable: nil)))
      host.frame = NSRect(x: 0, y: 0, width: 620, height: 590)
      host.layoutSubtreeIfNeeded()
      #expect(host.fittingSize.width == 620)
      #expect(host.fittingSize.height == 590)
    }
    #expect(try Data(contentsOf: model.configurationURL) == original)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/\(draft.id)").path))
  }
}

private actor FailingProjectSetupConfiguration: ConfigurationLoading {
  let repository: JSONConfigurationRepository
  var fail = false
  init(url: URL) { repository = JSONConfigurationRepository(url: url) }
  func failNextSave() { fail = true }
  func loadOrCreate(default configuration: AppConfiguration) async throws -> AppConfiguration {
    try await repository.loadOrCreate(default: configuration)
  }
  func save(_ configuration: AppConfiguration) async throws {
    if fail { fail = false; throw TaskContextError.commandFailed("Simulated save failure") }
    try await repository.save(configuration)
  }
}

private struct ProjectSetupExternalBoundary: WezTermControlling, PullRequestQueueLoading {
  private func forbidden<T>() throws -> T {
    Issue.record("Project setup attempted an unrelated terminal or network action")
    throw CancellationError()
  }
  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { try forbidden() }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { try forbidden() }
  func attach(paneID: Int, tabTitle: String, windowTitle: String, configuration: WezTermConfiguration) async throws { let _: Void = try forbidden() }
  func focusOrSpawn(directory: String, taskID: String, taskTitle: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult { try forbidden() }
  func focusOrResume(session: TaskAgentSession, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult { try forbidden() }
  func load(repository: String, closedSince: String) async throws -> PullRequestQueueSnapshot { try forbidden() }
}

/// A fresh install keeps its queue data under Application Support. An agent in
/// a project without a source folder must still start, from the home directory.
@Suite("Agents without a project folder")
@MainActor
struct NoRepositoryLaunchTests {
  private func freshModel(_ root: URL) async -> QueueViewModel {
    let model = QueueViewModel(paths: AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path]),
      terminalController: ProjectSetupExternalBoundary(), pullRequestQueueLoader: ProjectSetupExternalBoundary(),
      discoverExternalAgents: { [] }, labelTmuxPane: { _, _ in }, maintenanceEnabled: false,
      checkProviderAccount: { _ in .signedIn }, locateExistingAgent: { _, _ in nil })
    await model.bootstrap()
    await model.bootstrapTail?.value
    return model
  }

  @Test("A task in Other or the starter queue starts its agent in the home directory, not Focus Queue's data folder")
  func fallsBackToHome() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-repo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = await freshModel(root)
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    let other = DashboardTicket(id: "OTH-1", title: "Write a haiku", projectID: ProjectCatalog.otherID, status: "backlog", summary: "")
    let starter = DashboardTicket(id: "FQ-1", title: "Plan the week", status: "backlog", summary: "")
    for ticket in [other, starter] {
      let directory = model.defaultRepository(for: ticket)
      #expect(directory == home, "\(ticket.id) would start in \(directory)")
      // The tester's failure: provisioning the old default raised the Application Support guard.
      let workspace = try await TaskWorktreeManager().provisionAgent(ticketID: ticket.id,
        subtaskID: UUID().uuidString, path: directory, policy: .existingCheckout,
        store: TaskContextStore(root: root))
      #expect(workspace.path == directory)
    }
  }

  @Test("A project with its own folder keeps launching there")
  func keepsProjectFolder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-repo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("habit app", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = await freshModel(root.appendingPathComponent("support"))
    let dashboard = root.appendingPathComponent("support/projects/habit/dashboard.json")
    try FileManager.default.createDirectory(at: dashboard.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"tickets":[]}"#.utf8).write(to: dashboard)
    let project = ProjectDefinition(id: "habit", name: "Habit", dashboardPath: dashboard.path,
      workspacePath: folder.path, taskPrefix: "HAB", repositoryPath: "")
    #expect(await model.saveProject(project))
    let ticket = DashboardTicket(id: "HAB-1", title: "Streaks", projectID: "habit", status: "backlog", summary: "")
    #expect(model.defaultRepository(for: ticket) == folder.path)
  }

  @Test("Real worktrees inside Focus Queue's data folder are still refused, without pointing at Documents")
  func guardRemains() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-repo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let inside = root.appendingPathComponent("projects/other/workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    await #expect {
      _ = try await TaskWorktreeManager().provisionAgent(ticketID: "OTH-1", subtaskID: UUID().uuidString,
        path: inside.path, policy: .existingCheckout, store: TaskContextStore(root: root))
    } throws: { error in
      let message = error.localizedDescription
      return message.contains("data folder") && !message.contains("Documents")
    }
    #expect(TaskWorktreeManager.isApplicationSupportPath(inside.path, storeRoot: root))
    #expect(!TaskWorktreeManager.isApplicationSupportPath(root.deletingLastPathComponent().path, storeRoot: root))
  }
}
