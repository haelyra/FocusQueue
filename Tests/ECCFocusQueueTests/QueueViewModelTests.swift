import Foundation
import Observation
import Testing
import FocusQueueCore
import Darwin

@testable import ECCFocusQueue

@Suite("Queue app state integration")
@MainActor
struct QueueViewModelTests {
  @Test("Shift Return inserts a newline while unmodified Return submits the router objective")
  func routerComposerKeyboardSemantics() {
    #expect(RouterComposerKeyboard.action(shiftPressed: true) == .insertNewline)
    #expect(RouterComposerKeyboard.action(shiftPressed: false) == .submit)
  }

  @Test("Cancelling within the undo window restores the exact draft and never launches a router")
  func cancelRouterObjectiveWithinUndoWindow() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.projects[0].repositoryPath = fixture.root.path
    configuration.tmuxExecutable = "/usr/bin/true"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let router = ControlledObjectiveRouter(outcome: .registered(
      routeID: "must-not-launch", taskID: "ECC-101", subtaskID: "agent-one"))
    let model = await fixture.model(
      agent: ControlledQueueAgent(), objectiveRouter: router,
      routerUndoWindowSeconds: 0.2)
    let draft = "First line\nSecond line with exact spacing  "

    model.routeObjective(draft)
    #expect(model.canCancelRouterObjective)
    #expect(model.cancelRouterObjective() == draft)
    try await Task.sleep(for: .milliseconds(250))

    #expect(await router.launchCount == 0)
    #expect(!model.isRoutingObjective)
    #expect(!model.canCancelRouterObjective)
    #expect(model.routerStatus?.contains("cancelled") == true)
  }

  @Test("The Router starts after the undo window and can no longer be cancelled")
  func routerObjectiveStartsAfterUndoWindow() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.projects[0].repositoryPath = fixture.root.path
    configuration.tmuxExecutable = "/usr/bin/true"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let router = ControlledObjectiveRouter(outcome: .registered(
      routeID: "route-after-undo", taskID: "ECC-101", subtaskID: "agent-one"))
    let model = await fixture.model(
      agent: ControlledQueueAgent(), objectiveRouter: router,
      routerUndoWindowSeconds: 0.01)

    model.routeObjective("Route after the undo window")
    try await eventually { await router.launchCount == 1 && !model.canCancelRouterObjective }

    #expect(model.cancelRouterObjective() == nil)
    try await eventually { !model.isRoutingObjective }
    #expect(model.routerStatus?.contains("ECC-101") == true)
  }

  @Test("A queue objective starts one headless router and clears only after registration")
  func queueObjectiveRouterRegistration() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.projects[0].repositoryPath = fixture.root.path
    configuration.tmuxExecutable = "/usr/bin/true"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let router = ControlledObjectiveRouter(outcome: .registered(
      routeID: "route-one", taskID: "ECC-101", subtaskID: "agent-one"))
    let model = await fixture.model(agent: ControlledQueueAgent(), objectiveRouter: router)
    var completion: Bool?

    model.routeObjective("Fix exact agent recall") { completion = $0 }
    model.routeObjective("Duplicate click") { _ in }

    try await eventually { !model.isRoutingObjective && completion == true }
    #expect(await router.launchCount == 1)
    #expect(await router.objectives == ["Fix exact agent recall"])
    #expect(model.routerStatus?.contains("ECC-101") == true)
  }

  @Test("A pending router keeps its recovery locator and an empty objective never launches")
  func queueObjectiveRouterRecovery() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.projects[0].repositoryPath = fixture.root.path
    configuration.tmuxExecutable = "/usr/bin/true"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let router = ControlledObjectiveRouter(outcome: .waiting(
      routeID: "route-two", recoveryPath: "/tmp/route-two.json"))
    let model = await fixture.model(agent: ControlledQueueAgent(), objectiveRouter: router)
    var emptyCompletion: Bool?

    model.routeObjective("   ") { emptyCompletion = $0 }
    #expect(emptyCompletion == false)
    #expect(await router.launchCount == 0)
    model.routeObjective("Route unfinished work") { _ in }

    try await eventually { !model.isRoutingObjective }
    #expect(model.routerRecoveryPath == "/tmp/route-two.json")
    #expect(model.routerStatus?.contains("still working") == true)
    model.routeObjective("Do not duplicate the pending route") { _ in }
    #expect(await router.launchCount == 1)
    #expect(model.hasRouterRecovery)
  }

  @Test("A pending router keeps monitoring until delayed registration completes")
  func queueObjectiveRouterDelayedRegistration() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.projects[0].repositoryPath = fixture.root.path
    configuration.tmuxExecutable = "/usr/bin/true"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let router = ControlledObjectiveRouter(outcomes: [
      .waiting(routeID: "route-delayed", recoveryPath: "/tmp/route-delayed.json"),
      .registered(routeID: "route-delayed", taskID: "ECC-102", subtaskID: "agent-delayed"),
    ])
    let model = await fixture.model(
      agent: ControlledQueueAgent(), objectiveRouter: router,
      routerMonitorIntervalSeconds: 0.01)
    var completion: Bool?

    model.routeObjective("Route delayed work") { completion = $0 }

    try await eventually {
      completion == true && model.routerRuntime == nil
        && model.routerStatus?.contains("ECC-102") == true
    }
    #expect(await router.waitCount >= 2)
    #expect(!model.hasRouterRecovery)
  }

  @Test("A stale router monitor cannot overwrite a newer router after suspension")
  func staleRouterMonitorIsIdentityFenced() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.projects[0].repositoryPath = fixture.root.path
    configuration.tmuxExecutable = "/usr/bin/true"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let router = SuspendedRouterReplacementFixture()
    let model = await fixture.model(
      agent: ControlledQueueAgent(), objectiveRouter: router,
      routerMonitorIntervalSeconds: 0.01)

    model.routeObjective("First routed objective") { _ in }
    try await eventually { await router.hasSuspendedFirstMonitor }
    model.openRouterRecovery()
    try await eventually { model.routerRuntime == nil }

    model.routeObjective("Second routed objective") { _ in }
    try await eventually {
      !model.isRoutingObjective && model.routerRuntime?.tmuxName == "fq-router-second"
    }
    let secondCapability = try #require(model.routerRuntime?.capability)
    await router.resumeFirstMonitor()
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.routerRuntime?.capability == secondCapability)
    #expect(model.routerRuntime?.tmuxName == "fq-router-second")
    #expect(model.hasRouterRecovery)
  }

  @Test("A persisted router recovery blocks duplicate submission after app restart")
  func queueObjectiveRouterRecoverySurvivesRestart() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.projects[0].repositoryPath = fixture.root.path
    configuration.tmuxExecutable = "/usr/bin/true"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let runtime = try QueueRouterRuntime(
      tmuxName: "fq-router-restarted", tmuxExecutable: "/usr/bin/true", startedAt: Date(),
      objectiveSHA256: AgentStartupReceipt.promptDigest("Persisted restart objective"))
    try QueueRouterRuntimeStore(root: fixture.paths.supportDirectory).save(runtime)
    let router = ControlledObjectiveRouter(outcome: .waiting(
      routeID: nil, recoveryPath: QueueRouterRuntimeStore(root: fixture.paths.supportDirectory).url.path))

    let model = await fixture.model(agent: ControlledQueueAgent(), objectiveRouter: router)
    model.routeObjective("Do not duplicate after restart") { _ in }

    #expect(model.hasRouterRecovery)
    #expect(await router.launchCount == 0)
    #expect(model.routerStatus?.contains("previous router") == true)
  }

  @Test("A malformed router recovery blocks routing without blocking queue bootstrap")
  func malformedRouterRecoveryDoesNotBlockBootstrap() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = QueueRouterRuntimeStore(root: fixture.paths.supportDirectory)
    try FileManager.default.createDirectory(
      at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"tmuxName\":\"unsafe\"}".utf8).write(to: store.url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)

    let model = await fixture.model(agent: ControlledQueueAgent())

    #expect(model.loadError == nil)
    #expect(!model.openTickets.isEmpty)
    #expect(model.hasRouterRecovery)
    #expect(!model.canOpenRouterRecovery)
    #expect(model.routerStatus?.contains("new routing is blocked") == true)
  }

  @Test("Bootstrap primes saved agents from disk before background reconciliation")
  func bootstrapPrimesAgentsBeforeReconciliation() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    _ = try await store.upsertSubtask(ticketID: "ECC-101",
      subtask: TaskSubtask(id: "primed-worker", title: "Primed agent", sessionID: UUID().uuidString))
    let boundary = ForbiddenExternalActions()
    let model = QueueViewModel(paths: fixture.paths,
      terminalController: boundary, verifier: boundary, queueAgent: ControlledQueueAgent(),
      pullRequestQueueLoader: boundary, discoverExternalAgents: { [] },
      maintenanceEnabled: false, locateExistingAgent: { _, _ in nil })

    await model.bootstrap()

    #expect(model.loadError == nil)
    #expect(model.visibleAgents(for: "ECC-101").map(\.id) == ["primed-worker"])
    if let tail = model.bootstrapTail { await tail.value }
    #expect(model.visibleAgents(for: "ECC-101").map(\.id) == ["primed-worker"])
  }

  @Test("Disabling auto-exit preserves completed agents through refresh and saves the setting")
  func completedAgentOptOut() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let launcher = DirectCreationRunner()
    let model = await fixture.model(agent: ControlledQueueAgent(), taskAgentLauncher: TaskAgentLauncher(runner: launcher))
    model.setAutoExitCompletedAgents(false)
    try await eventually {
      try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile)).autoExitCompletedAgents == false
    }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let agent = TaskSubtask(id: "completed-worker", title: "Done", sessionID: UUID().uuidString, status: .completed)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: agent)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(id: "pending", title: "Pending"))
    try await Task.sleep(for: .seconds(2.1))
    await model.refresh()
    let retained = try #require(model.subtasks(for: "ECC-101").first { $0.id == agent.id })
    #expect(retained.agentRemovedAt == nil)
    #expect(await launcher.commands.isEmpty)
    model.setAutoExitCompletedAgents(true)
    try await Task.sleep(for: .seconds(2.1))
    await model.refresh()
    #expect(model.subtasks(for: "ECC-101").first { $0.id == agent.id }?.agentRemovedAt != nil)
  }

  @Test("A hidden panel skips external agent discovery, and reveal refreshes immediately")
  func hiddenPanelSkipsHeavyLanes() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let discoveries = DiscoveryCounter()
    let dashboards = CountingDashboardRepository()
    let model = await fixture.model(agent: ControlledQueueAgent(),
      dashboardRepository: dashboards, discoverExternalAgents: {
        await discoveries.record()
        return []
      })
    let discoveryBaseline = await discoveries.count

    model.setPanelVisible(false)
    await model.refresh()
    await model.refresh()
    #expect(await discoveries.count == discoveryBaseline)

    let loadBaseline = dashboards.loads
    model.setPanelVisible(true)
    try await eventually { dashboards.loads > loadBaseline }
  }

  @Test("Background polling reuses an unchanged dashboard and detects atomic updates")
  func backgroundPollingSkipsUnchangedDashboard() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = CountingDashboardRepository()
    let model = await fixture.model(agent: ControlledQueueAgent(), dashboardRepository: repository)
    await model.refresh()
    let baseline = repository.loads
    await model.refresh()
    #expect(repository.loads == baseline)

    let dashboardURL = URL(fileURLWithPath: model.config.dashboardPath)
    let updated = DashboardDocument(tickets: model.dashboard.tickets.map { ticket in
      ticket.id == "ECC-101" ? DashboardTicket(id: ticket.id,
        title: "Changed outside the app", status: "open", summary: "External update") : ticket
    })
    try JSONEncoder().encode(updated).write(to: dashboardURL, options: .atomic)
    await model.refresh()
    #expect(repository.loads == baseline + 1)
    #expect(model.dashboard.tickets[0].title == "Changed outside the app")
  }

  @Test("macOS Terminal rejects direct agents before any launch side effect")
  func macTerminalRequiresTmux() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let launcher = DirectCreationRunner()
    let model = await fixture.model(
      agent: ControlledQueueAgent(), taskAgentLauncher: TaskAgentLauncher(runner: launcher))
    var configuration = model.config
    configuration.wezTerm.applicationName = "Terminal"
    #expect(await model.finishSetup(configuration))
    var started: Bool?

    model.launchAgent(
      for: fixture.tickets[0], title: "Must use tmux", provider: .codex,
      repositoryPath: fixture.root.path, useTmux: false
    ) { started = $0 }

    #expect(started == false)
    #expect(model.actionMessages["ECC-101"]?.contains("requires tmux") == true)
    #expect(await launcher.commands.isEmpty)
    #expect(model.launchingTaskIDs.isEmpty)
  }

  @Test("Queue chat reloads a newly created project without restarting the app")
  func queueChatReloadsProjectCatalog() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let agent = ControlledQueueAgent()
    let model = await fixture.model(agent: agent)

    #expect(model.sendQueueAgentMessage("Create a Focus Queue project for ECC-101."))
    try await eventually { await agent.hasPendingReply }

    let workspace = fixture.root.appendingPathComponent("focus-queue-workspace")
    let dashboard = fixture.root.appendingPathComponent("projects/focus-queue/dashboard.json")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: dashboard.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(DashboardDocument(tickets: [])).write(to: dashboard)
    let repository = JSONConfigurationRepository(url: fixture.paths.configurationFile)
    var configuration = try await repository.loadOrCreate(
      default: SetupEnvironment.starter(supportDirectory: fixture.root))
    configuration.projects.append(ProjectConfiguration(
      id: "focus-queue", name: "Focus Queue", dashboardPath: dashboard.path,
      workspacePath: workspace.path))
    try await repository.save(configuration)

    await agent.reply("Created and verified the Focus Queue project.")
    try await eventually { !model.isQueueAgentResponding }

    #expect(model.projects.contains { $0.id == "focus-queue" && $0.name == "Focus Queue" })
    #expect(model.selectedProject?.id == configuration.selectedProjectID)
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
  }

  @Test("Central QChat receives every project dashboard while another project is selected")
  func centralChatReadsOtherProjects() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let otherWorkspace = fixture.root.appendingPathComponent("another-project")
    let otherDashboard = otherWorkspace.appendingPathComponent("dashboard.json")
    try FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
    try JSONEncoder().encode(DashboardDocument(tickets: [
      DashboardTicket(id: "APP-001", title: "Other project task", status: "open", summary: "")
    ])).write(to: otherDashboard)
    var config = try JSONDecoder().decode(AppConfiguration.self,
      from: Data(contentsOf: fixture.paths.configurationFile))
    config.projects.append(ProjectConfiguration(id: "app", name: "App",
      dashboardPath: otherDashboard.path, workspacePath: otherWorkspace.path))
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(config)
    let agent = ControlledQueueAgent()
    let model = await fixture.model(agent: agent)

    #expect(model.selectedProjectID != "app")
    #expect(model.sendQueueAgentMessage("What is APP-001 about?"))
    try await eventually { await agent.hasPendingReply }
    let sent = try #require(await agent.messages.first)
    #expect(sent.contains("App (app): dashboard \(otherDashboard.path)"))
    #expect(sent.contains("all readable without changing the UI selection"))
    #expect(!sent.contains("Ask the user to switch projects"))
    let projectScopes = await agent.projectScopes
    #expect(projectScopes.count == 1 && projectScopes[0] == nil)
    await agent.reply("APP-001 is in App.")
    try await eventually { !model.isQueueAgentResponding }
  }

  @Test("Project selection scopes task creation, task rename, and survives restart")
  func projectSelectionAndTaskMutation() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let secondWorkspace = fixture.root.appendingPathComponent("second-project")
    let secondDashboard = secondWorkspace.appendingPathComponent("dashboard.json")
    let archiveWorkspace = fixture.root.appendingPathComponent("archive-project")
    let archiveDashboard = archiveWorkspace.appendingPathComponent("dashboard.json")
    try FileManager.default.createDirectory(at: secondWorkspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archiveWorkspace, withIntermediateDirectories: true)
    let secondTicket = DashboardTicket(
      id: "APP-001", title: "Existing app task", status: "open",
      summary: "Keep this task in the app project")
    try JSONEncoder().encode(DashboardDocument(tickets: [secondTicket])).write(to: secondDashboard)
    try JSONEncoder().encode(DashboardDocument(tickets: [
      DashboardTicket(
        id: "APP-002", title: "Reserved task ID", status: "open",
        summary: "Keep task IDs globally unique")
    ])).write(to: archiveDashboard)

    var config = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    config.projects = [
      ProjectConfiguration(
        id: "ecc", name: "ECC", dashboardPath: config.dashboardPath,
        workspacePath: config.workspacePath),
      ProjectConfiguration(
        id: "app", name: "App", dashboardPath: secondDashboard.path,
        workspacePath: secondWorkspace.path),
      ProjectConfiguration(
        id: "archive", name: "Archive", dashboardPath: archiveDashboard.path,
        workspacePath: archiveWorkspace.path),
    ]
    config.selectedProjectID = "ecc"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(config)

    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.selectedProject?.name == "ECC")
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
    #expect(model.moveTicket("ECC-102", to: .top))

    #expect(await model.selectProject(id: "app"))
    #expect(model.selectedProject?.name == "App")
    #expect(model.openTickets.map(\.id) == ["APP-001"])

    #expect(await model.createTask(
      title: "Project-scoped task", summary: "Created from the detached plus button",
      doneWhen: "The task remains in the selected project", priority: "high"))
    let created = try #require(model.openTickets.first { $0.title == "Project-scoped task" })
    #expect(created.id == "APP-003")
    #expect(await model.renameTask(created, to: "Renamed everywhere"))
    #expect(model.dashboard.tickets.first { $0.id == created.id }?.title == "Renamed everywhere")
    #expect(model.moveTicket("APP-001", to: .top))
    #expect(await model.selectProject(id: "ecc"))
    #expect(model.openTickets.first?.id == "ECC-102")
    #expect(await model.selectProject(id: "app"))
    #expect(model.openTickets.first?.id == "APP-001")

    let firstSaved = try JSONDecoder().decode(
      DashboardDocument.self,
      from: Data(contentsOf: URL(fileURLWithPath: config.projects[0].dashboardPath)))
    let secondSaved = try JSONDecoder().decode(
      DashboardDocument.self, from: Data(contentsOf: secondDashboard))
    let archiveSaved = try JSONDecoder().decode(
      DashboardDocument.self, from: Data(contentsOf: archiveDashboard))
    #expect(firstSaved.tickets.map(\.id) == ["ECC-101", "ECC-102"])
    #expect(secondSaved.tickets.first { $0.id == created.id }?.title == "Renamed everywhere")
    #expect(archiveSaved.tickets.map(\.id) == ["APP-002"])

    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.selectedProject?.id == "app")
    #expect(restarted.openTickets.contains { $0.title == "Renamed everywhere" })
  }

  @Test("Task rename updates a loaded context and rejects an empty replacement")
  func taskRenamePropagation() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let ticket = try #require(model.openTickets.first)
    model.openPlan(for: ticket)
    try await eventually { model.taskContexts[ticket.id] != nil }

    #expect(await model.renameTask(ticket, to: "A clearer task title"))
    #expect(model.openTickets.first { $0.id == ticket.id }?.title == "A clearer task title")
    #expect(model.taskContexts[ticket.id]?.title == "A clearer task title")
    #expect(model.presentedPlanTicket?.title == "A clearer task title")
    let plan = try String(contentsOf: URL(fileURLWithPath: model.taskContexts[ticket.id]!.planPath))
    #expect(plan.hasPrefix("# \(ticket.id): A clearer task title\n"))
    #expect(!(await model.renameTask(ticket, to: "   ")))
    #expect(model.openTickets.first { $0.id == ticket.id }?.title == "A clearer task title")
  }

  @Test("A rename finishing after a project switch never repaints the prior project")
  func renameProjectSwitchRace() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let secondWorkspace = fixture.root.appendingPathComponent("rename-race-project")
    let secondDashboard = secondWorkspace.appendingPathComponent("dashboard.json")
    try FileManager.default.createDirectory(at: secondWorkspace, withIntermediateDirectories: true)
    try JSONEncoder().encode(DashboardDocument(tickets: [
      DashboardTicket(id: "APP-001", title: "Selected app task", status: "open", summary: "")
    ])).write(to: secondDashboard)
    var config = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    config.projects.append(ProjectConfiguration(
      id: "app", name: "App", dashboardPath: secondDashboard.path,
      workspacePath: secondWorkspace.path))
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(config)

    let repository = SuspendedRenameDashboardRepository()
    let model = await fixture.model(
      agent: ControlledQueueAgent(), dashboardRepository: repository)
    let original = try #require(model.openTickets.first { $0.id == "ECC-101" })
    let rename = Task { await model.renameTask(original, to: "Renamed in ECC") }
    try await eventually { await repository.hasPendingRename }
    #expect(await model.selectProject(id: "app"))
    await repository.resumeRename()
    #expect(await rename.value)
    #expect(model.selectedProject?.id == "app")
    #expect(model.dashboard.tickets.map(\.id) == ["APP-001"])
    let ecc = try JSONDecoder().decode(
      DashboardDocument.self,
      from: Data(contentsOf: URL(fileURLWithPath: config.projects[0].dashboardPath)))
    #expect(ecc.tickets.first { $0.id == "ECC-101" }?.title == "Renamed in ECC")
  }

  @Test("A canonical rename remains successful and visible when context repair must retry")
  func renameWithDamagedContext() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let ticket = try #require(model.openTickets.first)
    model.openPlan(for: ticket)
    try await eventually { model.taskContexts[ticket.id] != nil }
    let contextURL = fixture.root.appendingPathComponent("tasks/\(ticket.id)/context.json")
    try Data("not-json".utf8).write(to: contextURL, options: .atomic)

    #expect(await model.renameTask(ticket, to: "Canonical rename"))
    #expect(model.openTickets.first { $0.id == ticket.id }?.title == "Canonical rename")
    #expect(model.taskContexts[ticket.id]?.title == "Canonical rename")
    #expect(model.actionMessages[ticket.id]?.contains("Context repair will retry") == true)
    let saved = try JSONDecoder().decode(
      DashboardDocument.self,
      from: Data(contentsOf: URL(fileURLWithPath: model.config.dashboardPath)))
    #expect(saved.tickets.first { $0.id == ticket.id }?.title == "Canonical rename")
  }

  @Test("The collapse button repeats and persists the selected minimization behavior")
  func preferredMinimization() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    var dockMinimizations = 0
    model.minimizeHandler = { dockMinimizations += 1 }

    model.minimize(using: .topTask)
    #expect(model.isTopTaskOnly)
    model.setPanelMode(.expanded)
    model.performPreferredMinimization()
    #expect(model.isTopTaskOnly)

    model.setPanelMode(.expanded)
    model.minimize(using: .fq)
    #expect(model.isPanelCollapsed)

    model.setPanelMode(.expanded)
    model.minimize(using: .dock)
    #expect(dockMinimizations == 1)
    #expect(model.panelMode == .expanded)
    try await eventually {
      try await JSONLocalStateStore(url: fixture.paths.stateFile).load()
        .minimizationPreference == .dock
    }
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    restarted.minimizeHandler = { dockMinimizations += 1 }
    restarted.performPreferredMinimization()
    #expect(dockMinimizations == 2)
  }

  @Test("Program Log visibility persists while each process receives a fresh log")
  func programLogVisibility() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstLog = ProgramLogStore()
    let model = await fixture.model(agent: ControlledQueueAgent(), programLog: firstLog)
    var visibilityChanges: [Bool] = []
    model.programLogVisibilityHandler = { visibilityChanges.append($0) }

    model.setProgramLogWindowVisible(true)

    #expect(model.isProgramLogWindowVisible)
    #expect(visibilityChanges == [true])
    #expect(firstLog.entries.last?.message == "Program Log window shown.")
    try await eventually {
      (try? await JSONLocalStateStore(url: fixture.paths.stateFile).load()
        .programLogWindowVisible) == true
    }

    let restartedLog = ProgramLogStore()
    let restarted = await fixture.model(
      agent: ControlledQueueAgent(), programLog: restartedLog)
    #expect(restarted.isProgramLogWindowVisible)
    #expect(!restartedLog.entries.contains { $0.message == "Program Log window shown." })
  }

  @Test("Disabling automatic reports suppresses missing-report attention and persists")
  func disabledAutomaticReports() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.showsReportNotification)
    var reportedEnabledValue: Bool?
    model.dailyReportsEnabledHandler = { reportedEnabledValue = $0 }

    model.setDailyReportsEnabled(false)
    #expect(!model.config.dailyReport.enabled)
    #expect(!model.showsReportNotification)
    #expect(reportedEnabledValue == false)
    try await eventually {
      let saved = try JSONDecoder().decode(
        AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
      return !saved.dailyReport.enabled
    }
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(!restarted.config.dailyReport.enabled)
    #expect(!restarted.showsReportNotification)
  }

  @Test("Automatic agent routing can be enabled from Settings and persists")
  func automaticAgentRoutingSetting() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(!model.config.automaticAgentRouting)

    model.setAutomaticAgentRouting(true)
    #expect(model.config.automaticAgentRouting)
    try await eventually {
      let saved = try JSONDecoder().decode(
        AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
      return saved.automaticAgentRouting
    }

    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.config.automaticAgentRouting)
  }

  @Test("Agent usage bar defaults on and its Settings value persists")
  func agentUsageBarSetting() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.config.agentUsageBarEnabled)

    model.setAgentUsageBarEnabled(false)
    #expect(!model.config.agentUsageBarEnabled)
    try await eventually {
      let saved = try JSONDecoder().decode(
        AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
      return !saved.agentUsageBarEnabled
    }

    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(!restarted.config.agentUsageBarEnabled)
  }

  @Test("Managed usage presentation repairs task sessions outside the selected project")
  func managedUsagePresentationRepairsEveryStoredTask() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    let hiddenTicket = DashboardTicket(
      id: "OTH-103", title: "Stored task outside the visible project", status: "open",
      summary: "Keep its Codex usage rows current")
    _ = try await store.ensureContext(ticket: hiddenTicket)
    let runtime = try #require(TmuxController.decode(
      "fq-task-oth-103|123|1000|%9|456|/dev/ttys099|0\n", executable: "/mock/tmux").first)
    _ = try await store.upsertSubtask(ticketID: hiddenTicket.id, subtask: TaskSubtask(
      id: "stored-agent", title: "Stored agent", provider: .codex,
      sessionID: UUID().uuidString, status: .working, tmux: runtime))
    let shellDirectory = fixture.paths.supportDirectory.appendingPathComponent("shell")
    try FileManager.default.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
    try Data("process.stdout.write('ok')\n".utf8).write(
      to: shellDirectory.appendingPathComponent("focus_queue_codex_bar.js"))
    let runner = PresentationRepairRunner(taskID: hiddenTicket.id)

    _ = await fixture.model(agent: ControlledQueueAgent(),
      taskAgentLauncher: TaskAgentLauncher(runner: runner))

    try await eventually { await runner.repairedContextIDs.contains(hiddenTicket.id) }
  }

  @Test("App and agent share queue moves across refreshes, state saves, and restarts")
  func sharedQueueOrder() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
    #expect(model.moveTicket("ECC-102", to: .top))
    #expect(model.openTickets.map(\.id) == ["ECC-102", "ECC-101"])
    await model.refresh()
    #expect(model.openTickets.first?.id == "ECC-102")
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.openTickets.first?.id == "ECC-102")
    let external = QueueOrderStore(
      root: fixture.root, projectID: model.config.selectedProjectID)
    try external.move("ECC-101", to: .top, tickets: fixture.tickets, fallbackIDs: [])
    model.setPanelCollapsed(true)
    await model.refresh()
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
    #expect(!model.moveTicket("missing", to: .top))
    #expect(model.openTickets.first?.id == "ECC-101")
    model.resetQueueOrder()
    #expect(try external.load() == [])
  }

  @Test("Queued work items can exist without agents and retain their description")
  func standaloneSubtaskCreation() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())

    model.createSubtask(
      for: fixture.tickets[0], title: "Review the session list",
      explanation: "Clarify which agents are active before assigning one.")

    try await eventually { model.focusSubtasks(for: "ECC-101").count == 1 }
    let subtask = try #require(model.focusSubtasks(for: "ECC-101").first)
    #expect(!subtask.isAssignmentOnly)
    #expect(subtask.title == "Review the session list")
    #expect(subtask.assignmentDescription == "Clarify which agents are active before assigning one.")
    #expect(model.agents(for: subtask, ticketID: "ECC-101").isEmpty)
    #expect(model.visibleAgents(for: "ECC-101").isEmpty)
  }

  @Test("Subtask edits appear immediately while durable context is saved")
  func optimisticSubtaskEditing() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.createSubtask(
      for: fixture.tickets[0], title: "Original title", explanation: "Original explanation")
    try await eventually { model.focusSubtasks(for: "ECC-101").count == 1 }
    let original = try #require(model.focusSubtasks(for: "ECC-101").first)
    let externalStore = TaskContextStore(root: fixture.root)
    _ = try await externalStore.updateProgress(
      ticketID: "ECC-101", subtaskID: original.id, status: .working,
      summary: "Concurrent agent progress", sessionID: "live-session")

    model.updateSubtask(
      original, for: fixture.tickets[0], title: "Readable updated title",
      explanation: "Full updated explanation")

    #expect(model.focusSubtasks(for: "ECC-101").first?.title == "Readable updated title")
    #expect(
      model.focusSubtasks(for: "ECC-101").first?.assignmentDescription
        == "Full updated explanation")
    #expect(model.actionMessages["ECC-101"] == "Saving subtask…")
    try await eventually {
      model.actionMessages["ECC-101"] == "Subtask updated."
    }
    let saved = try #require(try await externalStore.load(ticketID: "ECC-101")?.subtasks.first)
    #expect(saved.title == "Readable updated title")
    #expect(saved.assignmentDescription == "Full updated explanation")
    #expect(saved.status == .working)
    #expect(saved.progressSummary == "Concurrent agent progress")
    #expect(saved.sessionID == "live-session")

    let current = try #require(model.focusSubtasks(for: "ECC-101").first)
    model.updateSubtask(
      current, for: fixture.tickets[0], title: "Readable updated title",
      explanation: "Superseded explanation")
    model.updateSubtask(
      current, for: fixture.tickets[0], title: "Readable updated title",
      explanation: "Newest explanation")
    #expect(
      model.focusSubtasks(for: "ECC-101").first?.assignmentDescription
        == "Newest explanation")
    try await eventually {
      guard model.actionMessages["ECC-101"] == "Subtask updated." else { return false }
      return try await externalStore.load(ticketID: "ECC-101")?.subtasks.first?
        .assignmentDescription == "Newest explanation"
    }
  }

  @Test("New agents remain independent titled work items with their own workspaces")
  func nestedAgentLaunch() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = externalWorkspace(for: fixture.root)
    defer { try? FileManager.default.removeItem(at: repository) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let git = FoundationProcessRunner()
    for arguments in [["init", "-q"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"]] {
      #expect(try await git.run(.init(executable: "/usr/bin/git", arguments: arguments, workingDirectory: repository.path)).succeeded)
    }
    let launcher = DirectCreationRunner()
    let model = await fixture.model(agent: ControlledQueueAgent(), terminalController: DirectViewRecorder(root: fixture.root, failReveal: false),
      taskAgentLauncher: TaskAgentLauncher(runner: launcher, candidateSockets: []))
    model.launchAgent(for: fixture.tickets[0], title: "New work", provider: .codex,
      repositoryPath: repository.path, includePrompt: false, useTmux: false, createWorktree: false,
      initialPrompt: "Do the requested work", subtaskID: "first-agent", createAssignment: true,
      modelName: "gpt-test", effort: "high")
    try await eventually { model.launchingTaskIDs.isEmpty }
    let assignment = try #require(model.focusSubtasks(for: "ECC-101").first)
    #expect(!assignment.isAssignmentOnly)
    #expect(assignment.tracksCompletion)
    #expect(assignment.status == .working)
    #expect(assignment.title == "New work")
    #expect(assignment.assignmentDescription == "Do the requested work")
    #expect(assignment.launchConfiguration?.model == "gpt-test")
    #expect(assignment.launchConfiguration?.effort == "high")
    #expect(assignment.workspace?.path == repository.path)
    #expect(model.agents(for: assignment, ticketID: "ECC-101").map(\.id) == ["first-agent"])
    model.launchAgent(for: fixture.tickets[0], title: "Second worker", provider: .claude,
      repositoryPath: repository.path, includePrompt: false, useTmux: false, createWorktree: false,
      initialPrompt: "Verify the second independent item", subtaskID: "second-agent")
    try await eventually { model.launchingTaskIDs.isEmpty }
    #expect(model.focusSubtasks(for: "ECC-101").count == 2)
    #expect(Set(model.taskItems(for: "ECC-101").map(\.id)) == ["first-agent", "second-agent"])
    #expect(model.agents(for: assignment, ticketID: "ECC-101").map(\.id) == ["first-agent"])
    let second = try #require(model.subtasks(for: "ECC-101").first { $0.id == "second-agent" })
    #expect(second.title == "Second worker")
    #expect(second.assignmentDescription == "Verify the second independent item")
    #expect(second.parentSubtaskID == nil)
    let first = try #require(model.subtasks(for: "ECC-101").first { $0.id == "first-agent" })
    model.removeAgent(first, from: fixture.tickets[0])
    try await eventually { model.subtasks(for: "ECC-101").first { $0.id == first.id }?.agentRemovedAt != nil }
    #expect(model.focusSubtasks(for: "ECC-101").count == 2)
    #expect(model.visibleAgents(for: "ECC-101").map(\.id) == ["second-agent"])
  }

  @Test("Direct launch persists its pane before revealing it and keeps it on reveal failure", arguments: [false, true])
  func directLaunchRevealsSavedPane(failReveal: Bool) async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = externalWorkspace(for: fixture.root)
    defer { try? FileManager.default.removeItem(at: repository) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let git = FoundationProcessRunner()
    for arguments in [["init", "-q"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"]] {
      let result = try await git.run(.init(executable: "/usr/bin/git", arguments: arguments,
        workingDirectory: repository.path))
      #expect(result.succeeded)
    }
    let launcherRunner = DirectCreationRunner()
    let recorder = DirectViewRecorder(root: fixture.root, failReveal: failReveal)
    let model = await fixture.model(agent: ControlledQueueAgent(), terminalController: recorder,
      taskAgentLauncher: TaskAgentLauncher(runner: launcherRunner, candidateSockets: []))
    model.launchAgent(for: fixture.tickets[0], title: "Direct worker", provider: .codex,
      repositoryPath: repository.path, assignmentDescription: "Keep the exact pane identity",
      includePrompt: false, useTmux: false)
    try await eventually { model.launchingTaskIDs.isEmpty }
    #expect(await recorder.opened == true)
    #expect(await launcherRunner.spawnCount == 1)
    let subtask = try #require(model.subtasks(for: "ECC-101").first)
    #expect(subtask.terminalPaneID == 42)
    #expect(subtask.runtimeMode == .terminal)
    #expect(subtask.status == .working)
    #expect(subtask.assignmentDescription == "Keep the exact pane identity")
    let message = try #require(model.actionMessages["ECC-101"])
    #expect(message.contains(failReveal ? "Click the subtask to retry" : "empty input"))
    model.openLaunchDiagnostics(for: subtask)
    #expect(model.launchDiagnostics?.text.contains(failReveal ? "view-failed" : "\"phase\":\"ready\"") == true)
  }

  @Test("One-click New Agent uses Codex, no custom prompt, and an isolated task worktree")
  func oneClickAgentLaunch() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = externalWorkspace(for: fixture.root, suffix: "one-click-repo")
    defer { try? FileManager.default.removeItem(at: repository) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let git = FoundationProcessRunner()
    for arguments in [["init", "-q"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"]] {
      #expect(try await git.run(.init(executable: "/usr/bin/git", arguments: arguments,
        workingDirectory: repository.path)).succeeded)
    }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.workspacePath = repository.path
    configuration.projects[0].workspacePath = repository.path
    configuration.projects[0].repositoryPath = repository.path
    configuration.tmuxExecutable = "/usr/bin/true"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(
      ticket: fixture.tickets[0], project: configuration.projects[0])
    _ = try await store.setWorktree(
      ticketID: "ECC-101", path: repository.appendingPathComponent(".worktrees/previous-agent").path,
      branch: "focus-queue/previous-agent", baseBranch: "main", managed: true,
      repositoryPath: repository.path)
    let agentID = "11111111-1111-4111-8111-111111111111"
    let runner = ManagedResumeRunner(taskID: "ECC-101", agentID: agentID)
    let terminal = ManagedResumeRecorder()
    let model = await fixture.model(
      agent: ControlledQueueAgent(), terminalController: terminal,
      taskAgentLauncher: TaskAgentLauncher(runner: runner, tmuxServerName: "one-click-test"))

    #expect(model.defaultRepository(for: fixture.tickets[0]) == repository.path)
    model.launchDefaultAgent(for: fixture.tickets[0], subtaskID: agentID)
    try await eventually { model.launchingTaskIDs.isEmpty }

    let agent = try #require(model.subtasks(for: "ECC-101").first { $0.id == agentID })
    #expect(agent.title == "Codex agent")
    #expect(agent.provider == .codex)
    #expect(agent.initialPrompt == nil)
    #expect(agent.assignmentDescription.isEmpty)
    #expect(!agent.includeInitializationPrompt)
    #expect(agent.runtimeMode == .tmux)
    #expect(agent.tmux?.name == "fq-task-ecc-101")
    #expect(agent.workspace?.managed == true)
    #expect(agent.workspace?.path != repository.path)
    #expect(agent.workspace?.repositoryPath == repository.path)
    #expect(await terminal.opened.count == 1)
    let launchCommands = await runner.commands.map(\.arguments).flatMap { $0 }
    #expect(!launchCommands.contains { $0.contains("Prepare the task context") })
  }

  @Test("New Agent menu choices pick the provider, name the agent, and pass the launch configuration")
  func oneClickAgentModelChoice() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = externalWorkspace(for: fixture.root, suffix: "model-choice-repo")
    defer { try? FileManager.default.removeItem(at: repository) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let git = FoundationProcessRunner()
    for arguments in [["init", "-q"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"]] {
      #expect(try await git.run(.init(executable: "/usr/bin/git", arguments: arguments,
        workingDirectory: repository.path)).succeeded)
    }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.workspacePath = repository.path
    configuration.projects[0].workspacePath = repository.path
    configuration.projects[0].repositoryPath = repository.path
    configuration.tmuxExecutable = "/usr/bin/true"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(
      ticket: fixture.tickets[0], project: configuration.projects[0])
    _ = try await store.upsertSubtask(ticketID: "ECC-101",
      subtask: TaskSubtask(title: "claude sonnet", provider: .claude))
    let agentID = "22222222-2222-4222-8222-222222222222"
    let runner = ManagedResumeRunner(taskID: "ECC-101", agentID: agentID)
    let terminal = ManagedResumeRecorder()
    let model = await fixture.model(
      agent: ControlledQueueAgent(), terminalController: terminal,
      taskAgentLauncher: TaskAgentLauncher(runner: runner, tmuxServerName: "model-choice-test"))

    model.launchDefaultAgent(for: fixture.tickets[0], provider: .claude,
      model: "sonnet", effort: "low", subtaskID: agentID)
    try await eventually { model.launchingTaskIDs.isEmpty }

    let agent = try #require(model.subtasks(for: "ECC-101").first { $0.id == agentID })
    #expect(agent.title == "Claude sonnet 2")
    #expect(agent.provider == .claude)
    #expect(agent.launchConfiguration?.model == "sonnet")
    #expect(agent.launchConfiguration?.effort == "low")
    let launchCommands = await runner.commands.map(\.arguments).flatMap { $0 }
    #expect(launchCommands.contains("--model"))
    #expect(launchCommands.contains("sonnet"))
    #expect(launchCommands.contains("--effort"))
    #expect(launchCommands.contains("low"))
  }

  @Test("A failed New Agent launch returns its error and retries its saved workspace and assignment")
  func launchRetryPreservesAssignment() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = externalWorkspace(for: fixture.root)
    defer { try? FileManager.default.removeItem(at: repository) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    for arguments in [["init", "-q", "-b", "main"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"]] {
      #expect(try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git", arguments: arguments,
        workingDirectory: repository.path)).succeeded)
    }
    let launcher = DirectCreationRunner(failFirstSpawn: true)
    let model = await fixture.model(agent: ControlledQueueAgent(),
      terminalController: DirectViewRecorder(root: fixture.root, failReveal: false),
      taskAgentLauncher: TaskAgentLauncher(runner: launcher, candidateSockets: []))
    let id = UUID().uuidString
    var outcomes: [Bool] = []
    func launch() {
      model.launchAgent(for: fixture.tickets[0], title: "Retry worker", provider: .codex,
        repositoryPath: repository.path, includePrompt: false, useTmux: false,
        subtaskID: id, createAssignment: true) { outcomes.append($0) }
    }
    launch()
    try await eventually { outcomes.count == 1 }
    #expect(outcomes == [false])
    #expect(model.actionMessages["ECC-101"]?.contains("Fixture launch unavailable") == true)
    let original = try #require(model.subtasks(for: "ECC-101").first { $0.id == id })
    #expect(original.status == .blocked)
    #expect(original.workspace?.managed == true)
    // The retry already owns a safe workspace, even if another agent edits the source.
    try Data("other agent's work".utf8).write(to: repository.appendingPathComponent("other.txt"))
    launch()
    try await eventually { outcomes.count == 2 }
    #expect(outcomes == [false, true])
    let retried = try #require(model.subtasks(for: "ECC-101").first { $0.id == id })
    #expect(retried.workspace == original.workspace)
    #expect(retried.parentSubtaskID == original.parentSubtaskID)
    #expect(retried.terminalPaneID == 42)
    #expect(model.focusSubtasks(for: "ECC-101").count == 1)
    #expect(await launcher.spawnCount == 2)
    launch()
    try await eventually { outcomes.count == 3 }
    #expect(outcomes == [false, true, false])
    #expect(await launcher.spawnCount == 2)
    #expect(model.actionMessages["ECC-101"]?.contains("already has a saved session") == true)
  }

  @Test("New Agent preflight failures finish visibly before any provider is started")
  func launchPreflightFeedback() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let launcher = DirectCreationRunner()
    let model = await fixture.model(agent: ControlledQueueAgent(),
      taskAgentLauncher: TaskAgentLauncher(runner: launcher, candidateSockets: []))
    var completed = false
    model.launchAgent(for: fixture.tickets[0], title: "Missing workspace", provider: .codex,
      repositoryPath: externalWorkspace(for: fixture.root, suffix: "missing").path) { started in
        #expect(!started)
        completed = true
      }
    try await eventually { completed }
    #expect(model.launchingTaskIDs.isEmpty)
    #expect(model.actionMessages["ECC-101"]?.contains("workspace is missing") == true)
    #expect(model.actionMessages["ECC-101"]?.contains("document icon") == false)
    #expect(await launcher.spawnCount == 0)
    #expect(model.subtasks(for: "ECC-101").isEmpty)
  }

  @Test("Queue chat can open beside the task list and remains mutually exclusive with other inspectors")
  func queueChatSideInspector() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    var visibility: [Bool] = []
    model.reportVisibilityHandler = { visibility.append($0) }

    model.setQueueChatInspectorPresented(true)
    #expect(model.isQueueChatInspectorPresented)
    #expect(model.isInspectorPresented)
    #expect(visibility.last == true)

    model.openPlan(for: fixture.tickets[0])
    #expect(!model.isQueueChatInspectorPresented)
    #expect(model.presentedPlanTicketID == "ECC-101")

    model.setQueueChatInspectorPresented(true)
    #expect(model.presentedPlanTicketID == nil)
    model.setDailyReportPresented(true)
    #expect(!model.isQueueChatInspectorPresented)
    #expect(model.isDailyReportPresented)

    model.setQueueChatInspectorPresented(true)
    model.toggleQueueChatInspector()
    #expect(!model.isQueueChatInspectorPresented)
    #expect(!model.isInspectorPresented)
    #expect(visibility.last == false)

    model.setQueueChatInspectorPresented(true)
    model.setPanelCollapsed(true)
    #expect(model.isPanelCollapsed)
    #expect(!model.isQueueChatInspectorPresented)
    #expect(!model.isInspectorPresented)

    var panelModes: [QueuePanelMode] = []
    model.panelModeHandler = { panelModes.append($0) }
    model.showTopTaskOnly()
    #expect(model.isTopTaskOnly)
    #expect(!model.isPanelCollapsed)
    model.setPanelMode(.expanded)
    #expect(model.panelMode == .expanded)
    #expect(panelModes == [.topTask, .expanded])
  }
  @Test("Launch diagnostics open inside Focus Queue without a JSONL file association")
  func inlineLaunchDiagnostics() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let logger = AgentLaunchLogger(supportDirectory: fixture.paths.supportDirectory)
    let subtask = TaskSubtask(id: "diagnostic-worker", title: "Direct launch")
    try await logger.record(.init(timestamp: Date(), taskID: "ECC-101", subtaskID: subtask.id,
      provider: "codex", runtime: "terminal", phase: "direct-confirm", outcome: "succeeded",
      message: "Saved exact pane", details: ["paneID": "1"]))
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.openLaunchDiagnostics(for: subtask)
    #expect(model.launchDiagnostics?.title == "Direct launch")
    #expect(model.launchDiagnostics?.text.contains("Saved exact pane") == true)
    model.launchDiagnostics = nil
    model.openLaunchDiagnostics(for: TaskSubtask(id: "missing", title: "Missing log"))
    #expect(model.launchDiagnostics?.text.contains("Could not read launch diagnostics") == true)
  }
  @Test("An unchanged background poll does not invalidate queue content or rewrite task files")
  func unchangedPollingDoesNotPublishContent() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let report = fixture.report("current", finishedAt: ISO8601DateFormatter().string(from: Date()))
    try JSONEncoder().encode(report).write(to: fixture.paths.latestDailyReportFile)
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.openPlan(for: fixture.tickets[0])
    try await eventually { !model.presentedPlanMarkdown.isEmpty }
    let context = try #require(model.taskContexts["ECC-101"])
    let contextURL = context.contextDirectory.appendingPathComponent("context.json")
    let before = try contextURL.resourceValues(forKeys: [.contentModificationDateKey])
    try await Task.sleep(for: .milliseconds(2100))
    let changes = ObservationCounter()
    withObservationTracking {
      _ = model.dashboard
      _ = model.taskContexts
      _ = model.localState
      _ = model.isRefreshing
      _ = model.sourceModificationDate
      _ = model.loadError
      _ = model.actionMessages
      _ = model.presentedPlanMarkdown
      _ = model.isPlanLoading
      _ = model.planError
      _ = model.dailyReport
      _ = model.latestDailyReport
      _ = model.dailyReportLoadError
      _ = model.reportHistory
      _ = model.reportHistoryError
      _ = model.recurringPRProgressByTicketID
      _ = model.recurringPRProgressErrors
    } onChange: { changes.record() }
    await model.refresh()
    await model.reloadDailyReport(preservingSelection: true)
    #expect(changes.count == 0)
    let after = try contextURL.resourceValues(forKeys: [.contentModificationDateKey])
    #expect(before.contentModificationDate == after.contentModificationDate)
  }

  @Test("Polling detects atomic external updates with preserved metadata and archives changed plans")
  func pollingDetectsExternalContextAndPlan() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let initialContext = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(
      id: "worker", title: "Worker", status: .working, progressSummary: "Before", lastHeartbeatAt: Date()))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)],
      ofItemAtPath: initialContext.contextDirectory.appendingPathComponent("context.json").path)
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.openPlan(for: fixture.tickets[0])
    try await eventually { !model.presentedPlanMarkdown.isEmpty }
    let context = try #require(model.taskContexts["ECC-101"])
    let contextURL = context.contextDirectory.appendingPathComponent("context.json")
    // Use a filesystem-stable timestamp. Reapplying an arbitrary subsecond
    // APFS timestamp can round differently even when the displayed value is identical.
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)],
      ofItemAtPath: contextURL.path)
    let attributes = try FileManager.default.attributesOfItem(atPath: contextURL.path)
    let original = try String(contentsOf: contextURL, encoding: .utf8)
    try Data(original.replacingOccurrences(of: "Before", with: "After!").utf8).write(to: contextURL, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: try #require(attributes[.modificationDate])], ofItemAtPath: contextURL.path)
    let changedAttributes = try FileManager.default.attributesOfItem(atPath: contextURL.path)
    #expect(attributes[.size] as? NSNumber == changedAttributes[.size] as? NSNumber)
    #expect(attributes[.modificationDate] as? Date == changedAttributes[.modificationDate] as? Date)
    let updatedPlan = model.presentedPlanMarkdown + "\nExternal agent decision retained.\n"
    try Data(updatedPlan.utf8).write(to: URL(fileURLWithPath: context.planPath), options: .atomic)
    try await Task.sleep(for: .milliseconds(2100))
    let changes = ObservationCounter()
    withObservationTracking { _ = model.taskContexts } onChange: { changes.record() }
    await model.refresh()
    #expect(changes.count == 1)
    #expect(model.subtasks(for: "ECC-101").first?.progressSummary == "After!")
    #expect(model.presentedPlanMarkdown == updatedPlan)
    let archives = try FileManager.default.contentsOfDirectory(
      at: context.contextDirectory.appendingPathComponent("archive"), includingPropertiesForKeys: nil)
    #expect(try archives.contains {
      try String(contentsOf: $0.appendingPathComponent("plan.md"), encoding: .utf8) == updatedPlan
    })
  }

  @Test("Heartbeat expiration updates activity without republishing unchanged task context")
  func heartbeatAgingPublishesOnlyActivity() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let subtask = TaskSubtask(id: "worker", title: "Worker", status: .working,
      lastHeartbeatAt: Date().addingTimeInterval(-290))
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    let model = await fixture.model(agent: ControlledQueueAgent())
    // Leave enough pre-expiry margin for a heavily concurrent suite bootstrap.
    #expect(model.effectiveStatus(for: subtask) == .working)
    let activity = ObservationCounter()
    let contexts = ObservationCounter()
    withObservationTracking { _ = model.effectiveStatus(for: subtask) } onChange: { activity.record() }
    withObservationTracking { _ = model.taskContexts } onChange: { contexts.record() }
    try await Task.sleep(for: .milliseconds(10_100))
    await model.refresh()
    #expect(model.effectiveStatus(for: subtask) == .idle)
    try await eventually { activity.count == 1 }
    #expect(contexts.count == 0)
    #expect(model.subtasks(for: "ECC-101").first?.status == .working)
  }

  @Test("Batch context polling reuses unchanged documents across one hundred tasks")
  func batchedContextPollingBenchmark() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    let tickets = (1...100).map {
      DashboardTicket(id: "PERF-\($0)", title: "Task \($0)", status: "open", summary: "Preserve task context")
    }
    let clock = ContinuousClock()
    let coldStart = clock.now
    let initial = await store.refreshContexts(tickets: tickets)
    let coldDuration = coldStart.duration(to: clock.now)
    _ = await store.refreshContexts(tickets: tickets)
    let warmStart = clock.now
    for _ in 0..<10 {
      let polled = await store.refreshContexts(tickets: tickets)
      #expect(polled.contexts == initial.contexts)
      #expect(polled.errors.isEmpty)
    }
    let warmDuration = warmStart.duration(to: clock.now)
    let uncachedStart = clock.now
    for _ in 0..<10 {
      for ticket in tickets { _ = try await store.ensureContext(ticket: ticket) }
    }
    let uncachedDuration = uncachedStart.duration(to: clock.now)
    #expect(initial.contexts.count == 100)
    print("Context polling benchmark:100 tasks, cold creation=\(coldDuration); 10 old per-ticket polls=\(uncachedDuration); 10 cached batch polls=\(warmDuration)")
  }

  @Test("A plan-only external change bypasses the cache and creates a retained snapshot")
  func planOnlyChangesAreArchivedByPolling() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = await store.refreshContexts(tickets: fixture.tickets)
    let cached = await store.refreshContexts(tickets: fixture.tickets)
    let context = try #require(cached.contexts["ECC-101"])
    let contextURL = context.contextDirectory.appendingPathComponent("context.json")
    let originalContextBytes = try Data(contentsOf: contextURL)
    let planURL = URL(fileURLWithPath: context.planPath)
    let changedPlan = try String(contentsOf: planURL, encoding: .utf8) + "\nPlan-only external decision.\n"
    try Data(changedPlan.utf8).write(to: planURL, options: .atomic)
    let refreshed = await store.refreshContexts(tickets: fixture.tickets)
    #expect(refreshed.contexts == cached.contexts)
    #expect(refreshed.errors.isEmpty)
    #expect(try Data(contentsOf: contextURL) == originalContextBytes)
    let archives = try FileManager.default.contentsOfDirectory(
      at: context.contextDirectory.appendingPathComponent("archive"), includingPropertiesForKeys: nil)
    #expect(try archives.contains {
      try String(contentsOf: $0.appendingPathComponent("plan.md"), encoding: .utf8) == changedPlan
    })
  }

  @Test("Task replies stay with their task when the inspector changes, and conversations survive restart")
  func taskChatIsolationAndPersistence() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let agent = ControlledQueueAgent()
    let model = await fixture.model(agent: agent)
    let globalBefore = model.chatMessages(ticketID: nil).map(\.text)
    model.openPlan(for: fixture.tickets[0])
    try await eventually { !model.presentedPlanMarkdown.isEmpty }
    let selection = PlanCanvasSelection(
      kind: .diagram, documentPath: "/tmp/ECC-101/plan.md",
      selector: "figure:nth-of-type(1)", tag: "figure",
      excerpt: "flowchart LR\nA[Decision] --> B[Implementation]")
    model.sendQueueAgentMessage(
      "Keep the task decision", ticketID: "ECC-101", canvasSelection: selection)
    try await eventually { await agent.hasPendingReply }
    #expect(model.respondingTicketID == "ECC-101")
    model.openPlan(for: fixture.tickets[1])
    try await eventually { model.presentedPlanMarkdown.contains("ECC-102") }
    await agent.reply("Decision recorded for task one")
    try await eventually { !model.isQueueAgentResponding }
    #expect(model.chatMessages(ticketID: "ECC-101").map(\.text) == [
      "Keep the task decision", "Decision recorded for task one"
    ])
    #expect(model.chatMessages(ticketID: "ECC-102").isEmpty)
    #expect(model.chatMessages(ticketID: nil).map(\.text) == globalBefore)
    let sent = try #require(await agent.messages.first)
    #expect(sent.contains("Task scope: ECC-101"))
    #expect(sent.contains(try #require(model.taskContexts["ECC-101"]).planPath))
    #expect(sent.contains("<focus-queue-plan-selection>"))
    #expect(sent.contains(#""kind":"diagram""#))
    #expect(sent.contains("A[Decision] --> B[Implementation]"))
    #expect(sent.contains("User request:\nKeep the task decision"))
    #expect(model.chatMessages(ticketID: "ECC-101").first?.canvasSelection == selection)

    let store = QueueConversationStore(root: fixture.paths.supportDirectory)
    try await eventually { try await store.load(ticketID: "ECC-101")?.count == 2 }
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    restarted.openPlan(for: fixture.tickets[0])
    try await eventually { restarted.chatMessages(ticketID: "ECC-101").count == 2 }
    #expect(restarted.chatMessages(ticketID: "ECC-101").map(\.text)
      == model.chatMessages(ticketID: "ECC-101").map(\.text))
    #expect(restarted.chatMessages(ticketID: "ECC-101").first?.canvasSelection == selection)
    #expect(restarted.chatMessages(ticketID: "ECC-102").isEmpty)
  }

  @Test("Central plan edits preserve another agent's changes and reload the latest document")
  func planSaveConflictAndReload() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.openPlan(for: fixture.tickets[0])
    try await eventually { !model.presentedPlanMarkdown.isEmpty }
    let original = model.presentedPlanMarkdown
    let context = try #require(model.taskContexts["ECC-101"])
    let document = URL(fileURLWithPath: context.planPath)
    let externalEdit = original + "\nAgent decision: preserve this result.\n"
    try Data(externalEdit.utf8).write(to: document, options: .atomic)
    let staleSave = await model.savePlan("Stale editor", expectedMarkdown: original, ticketID: "ECC-101")
    #expect(!staleSave)
    #expect(model.planError != nil)
    #expect(try String(contentsOf: document, encoding: .utf8) == externalEdit)
    await model.reloadPresentedPlan()
    #expect(model.planError == nil)
    #expect(model.presentedPlanMarkdown == externalEdit)
    let mergedEdit = externalEdit + "User decision: ready for implementation.\n"
    let saved = await model.savePlan(mergedEdit, expectedMarkdown: externalEdit, ticketID: "ECC-101")
    #expect(saved)
    #expect(model.presentedPlanMarkdown == mergedEdit)
    model.closePlan()
    #expect(!model.isInspectorPresented)
  }

  @Test("Queue-wide decisions persist separately from task conversations")
  func globalChatPersistence() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let agent = ControlledQueueAgent()
    let model = await fixture.model(agent: agent)
    model.sendQueueAgentMessage("Prefer the highest priority tasks")
    try await eventually { await agent.hasPendingReply }
    await agent.reply("Queue preference recorded")
    try await eventually { !model.isQueueAgentResponding }
    let store = QueueConversationStore(root: fixture.paths.supportDirectory)
    try await eventually { try await store.load(ticketID: nil)?.last?.text == "Queue preference recorded" }
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.queueChatMessages.suffix(2).map(\.text) == [
      "Prefer the highest priority tasks", "Queue preference recorded"
    ])
    #expect(restarted.taskChatMessages.isEmpty)
  }

  @Test("A damaged conversation or draft does not prevent task details loading", arguments: ["conversation.json", "plan-draft.json"])
  func planLoadsDespiteDamagedAuxiliaryFile(filename: String) async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let context = try #require(model.taskContexts["ECC-101"])
    try Data("damaged JSON".utf8).write(to: context.contextDirectory.appendingPathComponent(filename))

    model.openPlan(for: fixture.tickets[0])
    try await eventually { model.actionMessages["ECC-101"]?.contains("Could not load") == true }
    #expect(model.presentedPlanMarkdown.contains("ECC-101"))
    #expect(model.planError == nil)
  }

  @Test("An empty plan finishes loading and document switches clear prior errors")
  func emptyPlanAndDocumentSwitch() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let context = try #require(model.taskContexts["ECC-101"])
    try Data().write(to: URL(fileURLWithPath: context.planPath))
    model.openPlan(for: fixture.tickets[0])
    try await eventually { !model.isPlanLoading }
    #expect(model.presentedPlanMarkdown.contains("ECC-101"))
    #expect(model.planError == nil)

    model.openPlan(for: fixture.tickets[0], sourceURL: fixture.root.appendingPathComponent("missing.md"))
    try await eventually { model.planError != nil }
    model.openPlan(for: fixture.tickets[1])
    try await eventually { !model.isPlanLoading }
    #expect(model.presentedPlanMarkdown.contains("ECC-102"))
    #expect(model.planError == nil)
  }

  @Test("Plan drafts survive closing and restart, preserve conflicts, and clear after saving")
  func planDraftPersistenceAndConflict() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.openPlan(for: fixture.tickets[0])
    try await eventually { !model.presentedPlanMarkdown.isEmpty }
    let baseline = model.presentedPlanMarkdown
    let draft = baseline + "\nUnfinished user decision.\n"
    model.updatePlanDraft(draft, baseline: baseline, ticketID: "ECC-101")
    let store = QueueConversationStore(root: fixture.paths.supportDirectory)
    try await eventually { try await store.loadPlanDraft(ticketID: "ECC-101")?.markdown == draft }
    model.closePlan()
    model.openPlan(for: fixture.tickets[0])
    try await eventually { !model.presentedPlanMarkdown.isEmpty }
    #expect(model.planEditDrafts["ECC-101"]?.markdown == draft)

    let context = try #require(model.taskContexts["ECC-101"])
    let document = URL(fileURLWithPath: context.planPath)
    let externalChange = baseline + "\nAgent's concurrent change.\n"
    try Data(externalChange.utf8).write(to: document, options: .atomic)
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    restarted.openPlan(for: fixture.tickets[0])
    try await eventually { restarted.planEditDrafts["ECC-101"] != nil }
    #expect(restarted.planEditDrafts["ECC-101"]?.markdown == draft)
    #expect(restarted.planEditDrafts["ECC-101"]?.baseline == baseline)
    let conflicted = await restarted.savePlan(draft, expectedMarkdown: baseline, ticketID: "ECC-101")
    #expect(!conflicted)
    #expect(restarted.planEditDrafts["ECC-101"]?.markdown == draft)
    #expect(try await store.loadPlanDraft(ticketID: "ECC-101")?.markdown == draft)
    #expect(try String(contentsOf: document, encoding: .utf8) == externalChange)
    let merged = externalChange + "\nUnfinished user decision.\n"
    let saved = await restarted.savePlan(merged, expectedMarkdown: externalChange, ticketID: "ECC-101")
    #expect(saved)
    #expect(restarted.planEditDrafts["ECC-101"] == nil)
    #expect(try await store.loadPlanDraft(ticketID: "ECC-101") == nil)
    #expect(try String(contentsOf: document, encoding: .utf8) == merged)
  }

  @Test("Opening reports records viewing across restart and history selection preserves the latest file")
  func reportViewingAndHistorySelection() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let latest = fixture.report("latest", finishedAt: ISO8601DateFormatter().string(from: Date()))
    let older = fixture.report("older", finishedAt: "2026-09-09T15:00:00Z")
    try fixture.archive(latest)
    try fixture.archive(older)
    try JSONEncoder().encode(latest).write(to: fixture.paths.latestDailyReportFile)
    let originalFile = try Data(contentsOf: fixture.paths.latestDailyReportFile)
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.reportNeedsAttention)
    #expect(model.reportAttentionTitle == "Your daily report is ready")
    model.setDailyReportPresented(true)
    let history = JSONDailyReportHistoryRepository(runtimeDirectory: fixture.paths.ingestionRuntimeDirectory)
    try await eventually { try await history.load().viewedReportIDs.contains("latest") }
    await model.reloadReportHistory()
    #expect(!model.reportNeedsAttention)
    model.selectHistoricalReport(older)
    try await eventually { try await history.load().viewedReportIDs.contains("older") }
    #expect(model.dailyReport?.runID == "older")
    #expect(model.isDailyReportPresented)
    #expect(try Data(contentsOf: fixture.paths.latestDailyReportFile) == originalFile)
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.dailyReport?.runID == "latest")
    #expect(!restarted.reportNeedsAttention)
  }

  @Test("Daily run failures survive restart and block chat only while the run is active")
  func reportFailurePersistenceAndChatGate() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let agent = ControlledQueueAgent()
    let model = await fixture.model(agent: agent)
    model.setDailyReportRunState(isRunning: true, message: "Reading configured platforms")
    #expect(!model.sendQueueAgentMessage("Change the queue"))
    #expect(!model.isQueueAgentResponding)
    #expect(await agent.messages.isEmpty)
    model.setDailyReportRunState(isRunning: false, message: "Mail reader timed out", isError: true)
    try await eventually { model.reportHistory.runs.first?.phase == .failed }
    #expect(model.reportHistory.runs.count == 1)
    #expect(model.reportNeedsAttention)
    #expect(model.sendQueueAgentMessage("Change the queue"))
    try await eventually { await agent.hasPendingReply }
    #expect(!model.sendQueueAgentMessage("Keep this second draft"))
    await agent.reply("Queue updated")
    try await eventually { !model.isQueueAgentResponding }
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.reportAttentionTitle == "Daily report failed")
    #expect(restarted.reportHistory.runs.first?.message == "Mail reader timed out")
  }

  @Test("Cancelling a daily report requests one cancellation until the run stops")
  func dailyReportCancellationState() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    var cancellationCount = 0
    model.dailyReportCancelHandler = { cancellationCount += 1 }
    model.setDailyReportRunState(isRunning: true, message: "Reading configured platforms")

    model.cancelDailyReport()
    model.cancelDailyReport()

    #expect(cancellationCount == 1)
    #expect(model.isDailyReportRunning)
    #expect(model.isDailyReportCancellationRequested)
    #expect(model.dailyReportRunMessage == "Cancelling daily report…")

    model.setDailyReportRunState(
      isRunning: false,
      message: "Daily report cancelled.",
      finalPhase: .interrupted
    )
    #expect(!model.isDailyReportCancellationRequested)
    try await eventually { model.reportHistory.runs.first?.phase == .interrupted }
  }

  @Test("A live report recovered after restart stays gated and cancellable")
  func recoveredDailyReportCancellation() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let history = JSONDailyReportHistoryRepository(
      runtimeDirectory: fixture.paths.ingestionRuntimeDirectory)
    try await history.recordRun(isRunning: true, message: "Reading configured platforms")
    let lockURL = fixture.paths.ingestionRuntimeDirectory.appendingPathComponent("daily-report.lock")
    FileManager.default.createFile(atPath: lockURL.path, contents: Data())
    let descriptor = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW)
    #expect(descriptor >= 0)
    defer {
      flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
    }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    let token = UUID().uuidString
    try JSONSerialization.data(withJSONObject: [
      "version": 1,
      "token": token,
      "pid": 123,
    ]).write(to: fixture.paths.ingestionRuntimeDirectory
      .appendingPathComponent("daily-report-control.json"))

    let model = await fixture.model(agent: ControlledQueueAgent())
    var cancellationCount = 0
    model.dailyReportCancelHandler = { cancellationCount += 1 }

    #expect(model.reportIsRunning)
    #expect(model.canCancelDailyReport)
    model.runComprehensiveDailyReport()
    model.cancelDailyReport()

    #expect(cancellationCount == 1)
    #expect(model.isDailyReportCancellationRequested)
    try await eventually {
      FileManager.default.fileExists(atPath: fixture.paths.ingestionRuntimeDirectory
        .appendingPathComponent("daily-report-cancel.json").path)
    }
  }

  @Test("Cleared report notifications stay dismissed while a newer report can notify")
  func reportNotificationDismissal() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.setDailyReportRunState(isRunning: true, message: "Reading configured platforms")
    model.setDailyReportRunState(isRunning: false, message: "Mail reader timed out", isError: true)
    try await eventually { model.relevantFailedReportRun != nil }
    let notificationID = model.reportNotificationID
    #expect(model.showsReportNotification)

    model.dismissReportNotification()
    #expect(!model.showsReportNotification)
    try await eventually {
      try await JSONLocalStateStore(url: fixture.paths.stateFile).load()
        .dismissedNotificationIDs.contains(notificationID)
    }
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(!restarted.showsReportNotification)

    let newer = fixture.report(
      "newer-report",
      finishedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
    )
    try fixture.archive(newer)
    try JSONEncoder().encode(newer).write(to: fixture.paths.latestDailyReportFile)
    await restarted.reloadDailyReport()
    #expect(restarted.showsReportNotification)
    #expect(restarted.reportNotificationID != notificationID)
  }

  @Test("Connector diagnostics use the installed offline checker and expose every platform")
  func connectorDiagnostics() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let script = fixture.paths.connectorDiagnosticsScript
    try FileManager.default.createDirectory(
      at: script.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/usr/bin/env python3\n".utf8).write(to: script)
    let runner = ConnectorDiagnosticsRunnerStub()
    let model = await fixture.model(
      agent: ControlledQueueAgent(),
      connectorDiagnosticsRunner: runner
    )

    await model.diagnoseConnectors()

    #expect(model.connectorDiagnosticsError == nil)
    #expect(model.connectorDiagnostics?.connectors.count == 4)
    #expect(model.connectorDiagnostics?.diagnostic(for: .email)?.statusLabel == "Configured, not verified")
    let command = try #require(await runner.commands.first)
    #expect(command.executable == "/usr/bin/python3")
    #expect(command.arguments == [
      script.path, "--config", fixture.paths.ingestionConfigurationFile.path,
    ])
  }

  @Test("Reading an archived report keeps the latest unread report notification")
  func historicalViewingPreservesLatestAttention() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let latest = fixture.report("latest-unread", finishedAt: ISO8601DateFormatter().string(from: Date()))
    let older = fixture.report("older-viewed", finishedAt: "2026-09-09T15:00:00Z")
    try fixture.archive(latest)
    try fixture.archive(older)
    try JSONEncoder().encode(latest).write(to: fixture.paths.latestDailyReportFile)
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.selectHistoricalReport(older)
    let history = JSONDailyReportHistoryRepository(runtimeDirectory: fixture.paths.ingestionRuntimeDirectory)
    try await eventually { try await history.load().viewedReportIDs.contains(older.runID) }
    await model.reloadReportHistory()
    #expect(model.reportHistory.isUnread(latest))
    #expect(model.reportNeedsAttention)
    #expect(model.reportAttentionTitle == "Your daily report is ready")
  }

  @Test("Subtask closure requires persisted completion evidence and keeps the parent task open", arguments: [false, true])
  func subtaskClosureRequiresEvidence(persistCompletion: Bool) async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let contextStore = TaskContextStore(root: fixture.paths.supportDirectory)
    _ = try await contextStore.ensureContext(ticket: fixture.tickets[0])
    let subtask = TaskSubtask(id: "review-subtask", title: "Review implementation")
    _ = try await contextStore.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    let verifier = SubtaskVerifier(store: contextStore, persistCompletion: persistCompletion)
    let model = await fixture.model(agent: ControlledQueueAgent(), verifier: verifier)
    model.requestSubtaskCompletion(subtask, for: fixture.tickets[0])
    try await eventually {
      guard let status = model.localState.completionRequests.first?.status else { return false }
      return status == .accepted || status == .needsWork || status == .failed
    }
    let request = try #require(model.localState.completionRequests.first)
    #expect(request.status == (persistCompletion ? .accepted : .needsWork))
    #expect(request.subtaskID == subtask.id)
    let context = try #require(model.taskContexts["ECC-101"])
    #expect(request.contextPath == context.contextDirectory.path)
    #expect(model.latestReview(for: "ECC-101") == nil)
    #expect(!model.ticketIsChecked(fixture.tickets[0]))
    #expect(model.dashboard.tickets.first?.isOpen == true)
  }

  @Test("Restart retains closure review for a completed task with unfinished subtasks")
  func completedTaskClosureWarningSurvivesRestart() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.paths.supportDirectory)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    _ = try await store.upsertSubtask(ticketID: "ECC-101",
      subtask: TaskSubtask(id: "unfinished", title: "Confirm acceptance criteria", status: .working))
    let completed = DashboardTicket(id: "ECC-101", title: "Task ECC-101",
      status: "resolved", summary: "Implement and verify ECC-101")
    let legacyCompleted = DashboardTicket(id: "ECC-999", title: "Historical task",
      status: "resolved", summary: "Finished before context tracking")
    try JSONEncoder().encode(DashboardDocument(tickets: [completed, legacyCompleted]))
      .write(to: fixture.root.appendingPathComponent("dashboard.json"))

    for _ in 0..<2 {
      let restarted = await fixture.model(agent: ControlledQueueAgent())
      #expect(restarted.closureMessages["ECC-101"]?.contains("subtasks remain open") == true)
      #expect(restarted.openTickets.map(\.id).contains("ECC-101"))
      #expect(!restarted.completedTickets.map(\.id).contains("ECC-101"))
      #expect(restarted.subtasks(for: "ECC-101").first?.status == .working)
      #expect(restarted.taskContexts["ECC-999"] == nil)
      #expect(restarted.completedTickets.map(\.id).contains("ECC-999"))
    }
    #expect(try await store.load(ticketID: "ECC-999") == nil)
  }

  @Test("Completed subtasks trigger one parent review, ignore blank agent activity, and respect human review",
    arguments: [false, true], [TaskSubtaskStatus.working, .completed])
  func automaticParentReviewIsBounded(customerConcern: Bool, blankStatus: TaskSubtaskStatus) async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let ticket = DashboardTicket(id: "ECC-101", title: "Review task",
      status: "open", summary: "Verify the finished subtasks",
      taskType: customerConcern ? "customer-concern" : "task")
    try JSONEncoder().encode(DashboardDocument(tickets: [ticket]))
      .write(to: fixture.root.appendingPathComponent("dashboard.json"))
    let store = TaskContextStore(root: fixture.paths.supportDirectory)
    _ = try await store.ensureContext(ticket: ticket)
    for id in ["implementation", "verification"] {
      _ = try await store.upsertSubtask(ticketID: ticket.id,
        subtask: TaskSubtask(id: id, title: id, status: .completed,
          lastHeartbeatAt: Date().addingTimeInterval(-60)))
    }
    let verifier = CountingRefusalVerifier()
    let model = await fixture.model(agent: ControlledQueueAgent(), verifier: verifier)
    if !customerConcern {
      try await eventually { model.latestReview(for: ticket.id)?.status == .failed }
      #expect(await verifier.ticketIDs == [ticket.id])
      #expect(model.localState.completionRequests.count == 1)
      #expect(model.latestReview(for: ticket.id)?.subtaskID == nil)
    }
    var blankAgent = TaskSubtask(id: "blank", title: "Unrelated blank agent",
      status: blankStatus, lastHeartbeatAt: Date())
    blankAgent.tracksCompletion = false
    _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: blankAgent)
    // Pass the model's real context-refresh throttle, so the second refresh
    // exercises review deduplication rather than taking the fast return.
    try await Task.sleep(for: .milliseconds(2100))
    await model.refresh()
    #expect(model.localState.completionRequests.count == (customerConcern ? 0 : 1))
    #expect(await verifier.ticketIDs == (customerConcern ? [] : [ticket.id]))
    #expect(model.dashboard.tickets.first?.isOpen == true)
    if !customerConcern {
      #expect(model.latestReview(for: ticket.id)?.status == .failed)
      #expect(model.latestReview(for: ticket.id)?.summary == "Acceptance evidence still missing")
    }
  }

  @Test("A failed daily run never attributes an older displayed report to the failed attempt")
  func failedRunDoesNotReuseOlderReportID() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let older = fixture.report("previous-success", finishedAt: "2026-09-09T15:00:00Z")
    try fixture.archive(older)
    try JSONEncoder().encode(older).write(to: fixture.paths.latestDailyReportFile)
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.dailyReport?.runID == older.runID)
    model.setDailyReportRunState(isRunning: true, message: "Reading platforms")
    model.setDailyReportRunState(isRunning: false, message: "Worker failed before producing a report", isError: true)
    try await eventually { model.reportHistory.runs.first?.phase == .failed }
    let receipt = try #require(model.reportHistory.runs.first)
    #expect(receipt.reportID == nil)
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.reportHistory.runs.first?.reportID == nil)
    #expect(restarted.reportHistory.reports.first?.runID == older.runID)
  }

  @Test("An agent update opens its own inspector, preserves the verdict, and closes on collapse")
  func agentUpdateNavigation() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.openPlan(for: fixture.tickets[0])
    try await eventually { !model.presentedPlanMarkdown.isEmpty }
    let review = CompletionRequest(ticketID: "ECC-101", status: .needsWork,
      summary: "Verdict not complete: acceptance evidence missing", requestFilePath: "/tmp/request.json")
    let update = QueueAgentUpdate(id: review.id.uuidString, ticketID: "ECC-101",
      title: "Completion needs more work", summary: try #require(review.summary), review: review)
    model.openAgentUpdate(update)
    #expect(model.presentedAgentUpdate == update)
    #expect(model.presentedPlanTicketID == nil)
    #expect(!model.isDailyReportPresented)
    #expect(model.isInspectorPresented)
    #expect(model.dashboard.tickets[0].status == "open")
    model.showLatestDailyReport()
    #expect(model.presentedAgentUpdate == nil)
    model.openAgentUpdate(update)
    model.setPanelCollapsed(true)
    #expect(model.presentedAgentUpdate == nil)
    #expect(!model.isInspectorPresented)
    #expect(model.isPanelCollapsed)
  }

  @Test("Subtask notifications retain the full reply and mark only the viewed completion read")
  func subtaskUpdateAcknowledgement() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    for id in ["first", "second"] {
      _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(
        id: id, title: id, status: .completed, progressSummary: "Full reply for \(id)", completionUnread: true))
    }
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(id: "pending", title: "Pending"))
    let model = await fixture.model(agent: ControlledQueueAgent())
    let update = try #require(model.agentUpdates.first(where: { $0.subtaskID == "first" }))
    #expect(update.summary == "Full reply for first")
    model.openAgentUpdate(update)
    #expect(model.subtasks(for: "ECC-101").first(where: { $0.id == "first" })?.completionUnread == true)
    await model.acknowledgeAgentUpdate(update)
    #expect(model.subtasks(for: "ECC-101").first(where: { $0.id == "first" })?.completionUnread == false)
    #expect(model.subtasks(for: "ECC-101").first(where: { $0.id == "second" })?.completionUnread == true)
    #expect(model.presentedAgentUpdate?.summary == "Full reply for first")
    #expect(model.dashboard.tickets[0].status == "open")

    let second = try #require(model.agentUpdates.first(where: { $0.subtaskID == "second" }))
    model.dismissAgentUpdate(second)
    #expect(!model.agentUpdates.contains(where: { $0.presentationID == second.presentationID }))
    try await eventually {
      try await JSONLocalStateStore(url: fixture.paths.stateFile).load()
        .dismissedNotificationIDs.contains(second.presentationID)
    }
  }

  @Test("The notification feed excludes ordinary results and completions")
  func notificationFeedOnlyIncludesAttention() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])

    var result = TaskSubtask(
      id: "result", title: "Fresh result", status: .idle,
      progressSummary: "A new result is ready", completionUnread: true)
    result.resultID = "result-1"
    var completed = TaskSubtask(
      id: "completed", title: "Finished work", status: .completed,
      progressSummary: "The work is complete", completionUnread: true)
    completed.resultID = "result-2"
    var attention = TaskSubtask(
      id: "attention", title: "Needs a decision", status: .idle,
      progressSummary: "Choose a deployment target", completionUnread: true)
    attention.attention = .question
    attention.resultID = "attention-1"
    for subtask in [result, completed, attention] {
      _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    }

    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(Set(model.agentUpdates.compactMap(\.subtaskID)) == ["result", "completed", "attention"])
    #expect(model.notificationAgentUpdates.map(\.subtaskID) == ["attention"])
  }

  @Test("Changing type shows a pending response and the agent's result in the same task")
  func taskTypeChangeFeedback() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let agent = ControlledQueueAgent()
    let model = await fixture.model(agent: agent)
    model.changeTaskKind(.longRunning, for: fixture.tickets[0])
    #expect(model.presentedAgentUpdate?.ticketID == "ECC-101")
    #expect(model.presentedPlanTicketID == nil)
    #expect(model.isQueueAgentResponding)
    try await eventually { await agent.hasPendingReply }
    await agent.reply("Could not change task type: dashboard is read-only")
    try await eventually { !model.isQueueAgentResponding }
    #expect(model.chatMessages(ticketID: "ECC-101").last?.text == "Could not change task type: dashboard is read-only")
    #expect(model.chatMessages(ticketID: "ECC-102").isEmpty)
    #expect(model.dashboard.tickets[0].queueTaskKind == .task)
  }

  @Test("Deleted and completed merged subtasks do not retain review notifications")
  func staleReviewNotifications() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    var completed = TaskSubtask(id: "canonical", title: "Finished assignment", status: .completed)
    completed.isAssignmentOnly = true
    completed.completionOverrideAt = Date()
    var alias = TaskSubtask(id: "old-id", title: "Old assignment", status: .blocked)
    alias.isAssignmentOnly = true
    alias.mergedIntoSubtaskID = completed.id
    for subtask in [completed, alias] {
      _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    }
    var state = LocalState()
    state.completionRequests = ["deleted", alias.id].map {
      CompletionRequest(ticketID: "ECC-101", status: .needsWork,
        summary: "Old review", requestFilePath: "/tmp/old-review.json", subtaskID: $0)
    }
    try await JSONLocalStateStore(url: fixture.paths.stateFile).save(state)
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.agentUpdates.isEmpty)
    #expect(model.localState.completionRequests.count == 2)
  }

  @Test("Managed subtasks remain openable before provider registration arrives")
  func contextOnlyManagedAgentSession() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let uuid = UUID().uuidString
    let runtime = try #require(TmuxController.decode(
      "fq-worker\t123\t1000\t%0\t124\t/dev/ttys099\t0\n", executable: "/mock/tmux").first)
    let subtask = TaskSubtask(id: "worker", title: "Review session ownership", provider: .claude,
      sessionID: uuid, includeInitializationPrompt: false, tmux: runtime)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.agentSessions(for: "ECC-101").isEmpty)
    let recovered = try #require(model.session(for: subtask, ticketID: "ECC-101"))
    #expect(recovered.provider == .claude)
    #expect(recovered.sessionID == uuid)
    #expect(recovered.id == UUID(uuidString: uuid))
    #expect(recovered.resumePrompt == nil)
    #expect(recovered.tmux == runtime)
    #expect(model.session(for: subtask, ticketID: "ECC-102") == nil)
    model.removeAgent(recovered, from: fixture.tickets[0])
    try await eventually { model.subtasks(for: "ECC-101").first?.agentRemovedAt != nil }
    #expect(model.subtasks(for: "ECC-101").first?.sessionID == uuid)
    #expect(model.visibleAgents(for: "ECC-101").isEmpty)
    #expect(model.subtasks(for: "ECC-101").first?.title == "Review session ownership")
  }

  @Test("Opening an agent publishes progress and retains a session error", arguments: [false, true])
  func agentOpeningFeedback(fails: Bool) async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let sessionID = UUID().uuidString
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(
      id: "window-finder", title: "Find the exact agent window", provider: .codex,
      sessionID: sessionID, status: .working, lastHeartbeatAt: Date(),
      tmux: try TmuxController.decode("fq-window-finder|123|1000|%0|124|/dev/ttys099|0\n", executable: "/mock/tmux").first))
    let terminal = HoldingRecallRecorder(fails: fails)
    let model = await fixture.model(
      agent: ControlledQueueAgent(), terminalController: terminal,
      identifyManagedAgent: { subtask, _ in subtask.sessionID })
    let subtask = try #require(model.subtasks(for: "ECC-101").first)

    model.openSubtask(subtask, for: fixture.tickets[0])
    try await eventually { model.isOpening(subtask, ticketID: "ECC-101") }
    let session = try #require(model.session(for: subtask, ticketID: "ECC-101"))
    #expect(model.isOpening(session))
    await terminal.release()
    try await eventually { !model.isOpening(subtask, ticketID: "ECC-101") }

    if fails {
      #expect(model.agentSessionError(for: subtask, ticketID: "ECC-101")?.contains("Fixture session failure") == true)
      #expect(model.agentSessionIssue(for: "ECC-101") != nil)
    } else {
      #expect(model.agentSessionError(for: subtask, ticketID: "ECC-101") == nil)
      #expect(model.agentSessionIssue(for: "ECC-101") == nil)
    }
  }

  @Test("Opening a task title focuses its one shared tmux session")
  func taskTitleOpensSharedAgentSession() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let sessionName = "fq-task-ecc-101"
    for index in 1...2 {
      let sessionID = UUID().uuidString
      let runtime = try #require(TmuxController.decode(
        "\(sessionName)|123|1000|%\(index)|\(500 + index)|/dev/ttys09\(index)|0\n",
        executable: "/mock/tmux").first)
      _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(
        id: "agent-\(index)", title: "Agent \(index)", provider: .codex,
        sessionID: sessionID, status: .working, lastHeartbeatAt: Date(), tmux: runtime))
    }
    let terminal = ManagedResumeRecorder()
    let model = await fixture.model(
      agent: ControlledQueueAgent(), terminalController: terminal,
      identifyManagedAgent: { subtask, _ in subtask.sessionID })

    model.openTaskAgents(for: fixture.tickets[0])
    try await eventually { await terminal.opened.count == 1 }
    #expect(await terminal.opened.first?.name == sessionName)
    #expect(model.agentSessionIssue(for: "ECC-101") == nil)
  }

  @Test("Opening status stays scoped when two tasks use the same subtask name")
  func agentOpeningStatusUsesTaskIdentity() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    for ticket in fixture.tickets {
      _ = try await store.ensureContext(ticket: ticket)
      _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: TaskSubtask(
        id: "worker", title: "Worker", sessionID: UUID().uuidString,
        status: .working, lastHeartbeatAt: Date(),
        tmux: try TmuxController.decode("fq-worker|123|1000|%0|124|/dev/ttys099|0\n", executable: "/mock/tmux").first))
    }
    let terminal = HoldingRecallRecorder(fails: false)
    let model = await fixture.model(
      agent: ControlledQueueAgent(), terminalController: terminal,
      identifyManagedAgent: { subtask, _ in subtask.sessionID })
    let first = try #require(model.subtasks(for: "ECC-101").first)
    let second = try #require(model.subtasks(for: "ECC-102").first)

    model.openSubtask(first, for: fixture.tickets[0])
    try await eventually { model.isOpening(first, ticketID: "ECC-101") }

    #expect(!model.isOpening(second, ticketID: "ECC-102"))
    await terminal.release()
    try await eventually { !model.isOpening(first, ticketID: "ECC-101") }
  }

  @Test("Archiving one agent leaves it recoverable and other task agents intact")
  func archiveAgentFromOneTask() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    let first = TaskSubtask(id: "first", title: "First agent", sessionID: UUID().uuidString)
    let second = TaskSubtask(id: "second", title: "Second agent", sessionID: UUID().uuidString)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    _ = try await store.ensureContext(ticket: fixture.tickets[1])
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: first)
    _ = try await store.upsertSubtask(ticketID: "ECC-102", subtask: second)
    let firstSession = TaskAgentSession(
      ticketID: "ECC-101", provider: .codex, sessionID: try #require(first.sessionID),
      tabTitle: first.title, workingDirectory: fixture.root.path, subtaskID: first.id)
    let secondSession = TaskAgentSession(
      ticketID: "ECC-102", provider: .codex, sessionID: try #require(second.sessionID),
      tabTitle: second.title, workingDirectory: fixture.root.path, subtaskID: second.id)
    try await JSONLocalStateStore(url: fixture.paths.stateFile).save(
      LocalState(agentSessions: [firstSession, secondSession]))
    let model = await fixture.model(agent: ControlledQueueAgent())

    model.archiveAgent(first, from: fixture.tickets[0])
    try await eventually { model.visibleAgents(for: "ECC-101").isEmpty }

    #expect(model.agentSessions(for: "ECC-101").isEmpty)
    #expect(model.archivedAgents(for: "ECC-101").map(\.id) == ["first"])
    #expect(model.archivedAgents(for: "ECC-101").first?.sessionID == first.sessionID)
    #expect(model.subtasks(for: "ECC-102").map(\.id) == ["second"])
    #expect(model.agentSessions(for: "ECC-102").map(\.subtaskID) == ["second"])
  }

  @Test("Removing all agents is scoped to the selected task")
  func clearAgentsFromOneTask() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    let first = TaskSubtask(id: "first", title: "First agent", sessionID: UUID().uuidString)
    let second = TaskSubtask(id: "second", title: "Second agent", sessionID: UUID().uuidString)
    for (ticket, subtask) in zip(fixture.tickets, [first, second]) {
      _ = try await store.ensureContext(ticket: ticket)
      _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: subtask)
    }
    let sessions = zip(fixture.tickets, [first, second]).map { ticket, subtask in
      TaskAgentSession(
        ticketID: ticket.id, provider: .codex, sessionID: subtask.sessionID!,
        tabTitle: subtask.title, workingDirectory: fixture.root.path, subtaskID: subtask.id)
    }
    try await JSONLocalStateStore(url: fixture.paths.stateFile).save(
      LocalState(agentSessions: sessions))
    let model = await fixture.model(agent: ControlledQueueAgent())

    model.clearAgentQueue(for: fixture.tickets[0])
    try await eventually { model.visibleAgents(for: "ECC-101").isEmpty }

    #expect(model.agentSessions(for: "ECC-101").isEmpty)
    #expect(model.subtasks(for: "ECC-102").map(\.id) == ["second"])
    #expect(model.agentSessions(for: "ECC-102").map(\.subtaskID) == ["second"])
  }

  @Test("Managed recall preserves its exact runtime and avoids title-only window focus")
  func managedRecallPreservesIdentity() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = RecallRecorder()
    let model = await fixture.model(agent: ControlledQueueAgent(), terminalController: recorder)
    model.terminalFocusHandler = { _, _ in Issue.record("Recall attempted ambiguous task-title window focus") }
    let runtime = try #require(TmuxController.decode(
      "fq-session-recall\t123\t1000\t%0\t124\t/dev/ttys099\t0\n", executable: "/mock/tmux").first)
    let session = TaskAgentSession(ticketID: "ECC-101", provider: .codex,
      sessionID: UUID().uuidString, tabTitle: "Historical", workingDirectory: fixture.root.path,
      resumePrompt: "Automatically start implementing again", tmux: runtime)
    model.viewAgent(session, for: fixture.tickets[0])
    try await eventually { model.actionMessages["ECC-101"]?.contains("Managed session") == true }
    let recalled = try #require(await recorder.sessions.first)
    #expect(recalled.workingDirectory == fixture.root.path)
    #expect(recalled.resumePrompt == nil)
    #expect(recalled.sessionID == session.sessionID)
    #expect(recalled.contextDirectory != nil)
    #expect(recalled.tmux == runtime)
    #expect(model.localState.agentSessions.first?.sessionID == session.sessionID)
    #expect(model.localState.agentSessions.first?.paneID == 42)
  }

  @Test("Override completes only the selected subtask and removes its agent without queuing parent review")
  func manualOverride() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let subtask = TaskSubtask(id: "accidental", title: "Undone assignment", status: .blocked)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.overrideCompletion(subtask, for: fixture.tickets[0])
    try await eventually { model.subtasks(for: "ECC-101").first?.agentRemovedAt != nil }
    #expect(model.subtasks(for: "ECC-101").first?.status == .completed)
    #expect(model.visibleAgents(for: "ECC-101").isEmpty)
    #expect(model.dashboard.tickets[0].isOpen)
    try await Task.sleep(for: .milliseconds(2100))
    await model.refresh()
    #expect(model.localState.completionRequests.isEmpty)
    #expect(model.dashboard.tickets[0].isOpen)
  }

  @Test("An assignment override settles running child reviews and survives a late verifier result")
  func overrideSettlesChildReview() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    var assignment = TaskSubtask(id: "assignment", title: "Finish the assignment")
    assignment.isAssignmentOnly = true
    var child = TaskSubtask(id: "child", title: "Check the result", status: .blocked)
    child.parentSubtaskID = assignment.id
    child.tracksCompletion = false
    for subtask in [assignment, child] {
      _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    }
    let verifier = ControlledCompletionVerifier()
    let model = await fixture.model(agent: ControlledQueueAgent(), verifier: verifier)
    model.requestSubtaskCompletion(child, for: fixture.tickets[0])
    try await eventually { await verifier.hasPendingReply }
    model.overrideCompletion(assignment, for: fixture.tickets[0])
    try await eventually { model.subtasks(for: "ECC-101").first(where: { $0.id == child.id })?.agentRemovedAt != nil }
    #expect(model.localState.completionRequests.first?.status == .accepted)
    await verifier.reply()
    try await eventually { model.localState.completionRequests.first?.logPath != nil }
    #expect(model.localState.completionRequests.first?.status == .accepted)
    #expect(model.agentUpdates.isEmpty)
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.localState.completionRequests.first?.status == .accepted)
    #expect(restarted.agentUpdates.isEmpty)
  }

  @Test("Restart settles an interrupted review that was already completed by the user")
  func recoverOverriddenChildReview() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let subtask = TaskSubtask(id: "completed", title: "User completed this")
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    _ = try await store.overrideCompletion(ticketID: "ECC-101", subtaskID: subtask.id)
    var state = LocalState()
    state.completionRequests = [CompletionRequest(ticketID: "ECC-101", status: .running,
      summary: "Earlier evidence", requestFilePath: "/tmp/stale-request.json", subtaskID: subtask.id)]
    try await JSONLocalStateStore(url: fixture.paths.stateFile).save(state)

    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.localState.completionRequests.first?.status == .accepted)
    #expect(model.agentUpdates.isEmpty)
    try await eventually {
      try await JSONLocalStateStore(url: fixture.paths.stateFile).load().completionRequests.first?.status == .accepted
    }
  }

  @Test("Completed agents disappear automatically while blank agents never drive parent completion")
  func completedAndBlankAgents() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    var blank = TaskSubtask(id: "blank", title: "Interactive conversation", status: .completed)
    blank.tracksCompletion = false
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: blank)
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.visibleAgents(for: "ECC-101").isEmpty)
    #expect(model.subtasks(for: "ECC-101").first?.agentRemovedAt != nil)
    #expect(model.localState.completionRequests.isEmpty)
    #expect(model.dashboard.tickets[0].isOpen)
  }

  @Test("A closed direct agent resumes its saved conversation; transport failures never duplicate it", arguments: [false, true])
  func directResume(transportFailure: Bool) async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = externalWorkspace(for: fixture.root)
    defer { try? FileManager.default.removeItem(at: repository) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let git = FoundationProcessRunner()
    for arguments in [["init", "-q", "-b", "feature"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"]] {
      #expect(try await git.run(.init(executable: "/usr/bin/git", arguments: arguments, workingDirectory: repository.path)).succeeded)
    }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let identity = UUID().uuidString
    var subtask = TaskSubtask(id: "resume-worker", title: "Existing conversation", sessionID: identity,
      runtimeMode: .terminal, terminalPaneID: 7)
    subtask.workspace = try await TaskWorktreeManager().workspace(at: repository.path)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    let launcher = DirectCreationRunner()
    let terminal = ClosedDirectRecorder(transportFailure: transportFailure)
    let model = await fixture.model(agent: ControlledQueueAgent(), terminalController: terminal,
      taskAgentLauncher: TaskAgentLauncher(runner: launcher, candidateSockets: []))
    var centered = 0
    model.agentTerminalFocusHandler = { application, ticketID in
      #expect(application == "WezTerm" && ticketID == "ECC-101")
      centered += 1
    }
    model.openSubtask(subtask, for: fixture.tickets[0])
    try await eventually { model.launchingTaskIDs.isEmpty }
    #expect(centered == (transportFailure ? 0 : 1))
    let commands = await launcher.commands
    if transportFailure {
      #expect(!commands.contains { $0.arguments.contains("spawn") })
      #expect(model.subtasks(for: "ECC-101").first?.terminalPaneID == 7)
    } else {
      let spawn = try #require(commands.first(where: { $0.arguments.contains("spawn") }))
      #expect(spawn.arguments.contains("resume"))
      #expect(spawn.arguments.contains(identity))
      #expect(spawn.arguments.contains(repository.path))
      #expect(!spawn.arguments.contains { $0.contains("Work on ECC-101") })
      #expect(model.subtasks(for: "ECC-101").first?.terminalPaneID == 42)
      #expect(model.subtasks(for: "ECC-101").first?.sessionID == identity)
    }
  }

  @Test("A legacy tmux record never opens another conversation and resumes the clicked UUID once")
  func legacyTmuxConversationMismatch() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = externalWorkspace(for: fixture.root, suffix: "managed-resume")
    defer { try? FileManager.default.removeItem(at: repository) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let git = FoundationProcessRunner()
    for arguments in [["init", "-q", "-b", "feature"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"]] {
      #expect(try await git.run(.init(executable: "/usr/bin/git", arguments: arguments, workingDirectory: repository.path)).succeeded)
    }
    let expectedID = UUID().uuidString.lowercased()
    let wrongLiveID = UUID().uuidString.lowercased()
    let agentID = "legacy-agent"
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    var subtask = TaskSubtask(id: agentID, title: "Resume the clicked conversation",
      sessionID: expectedID, runtimeMode: .tmux)
    subtask.workspace = try await TaskWorktreeManager().workspace(at: repository.path)
    let legacyRuntime = try TmuxController.decode(
      "fq-codex-shared-history|9|10|%1|11|/dev/ttys099|0\n",
      executable: "/mock/legacy-tmux")
    #expect(legacyRuntime.count == 1)
    subtask.tmux = legacyRuntime.first
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    let runner = ManagedResumeRunner(taskID: "ECC-101", agentID: agentID)
    let terminal = ManagedResumeRecorder()
    let model = await fixture.model(
      agent: ControlledQueueAgent(), terminalController: terminal,
      taskAgentLauncher: TaskAgentLauncher(runner: runner),
      identifyManagedAgent: { requested, _ in
        #expect(requested.id == agentID)
        return wrongLiveID
      })

    model.openSubtask(subtask, for: fixture.tickets[0], showResult: false)
    try await eventually { model.launchingTaskIDs.isEmpty }

    let opened = try #require(await terminal.opened.last)
    #expect(opened.name == "fq-task-ecc-101")
    #expect(opened.paneID == "%9")
    #expect(await terminal.opened.count == 1)
    let calls = await runner.commands
    let launch = try #require(calls.first { $0.arguments.contains("new-session") })
    #expect(launch.arguments.contains("resume"))
    #expect(launch.arguments.contains(expectedID))
    #expect(!launch.arguments.contains(wrongLiveID))
    #expect(launch.arguments.contains("--cd"))
    #expect(launch.arguments.contains(repository.path))
    let saved = try #require(model.subtasks(for: "ECC-101").first { $0.id == agentID })
    #expect(saved.sessionID == expectedID)
    #expect(saved.tmux == opened)
    #expect(saved.workspace?.path == repository.path)
  }

  @Test("Runtime-less external sessions never duplicate a live or unverified provider", arguments: [false, true])
  func externalSessionRecallFailsClosed(unknown: Bool) async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let sessionID = UUID().uuidString.lowercased()
    let registry = ExternalAgentRegistry(root: fixture.root)
    let record = try await registry.register(.init(sessionID: sessionID, cwd: fixture.root.path,
      hookEventName: "SessionStart", prompt: "External editor"), provider: .codex, explicitTaskID: "ECC-101")
    #expect(record.tmux == nil && record.paneID == nil)
    let launcher = DirectCreationRunner()
    let model = await fixture.model(agent: ControlledQueueAgent(),
      taskAgentLauncher: TaskAgentLauncher(runner: launcher, candidateSockets: []),
      locateExistingAgent: { provider, suppliedID in
        #expect(provider == .codex && suppliedID == sessionID)
        if unknown { throw WezTermError.actionFailed("Provider ownership lookup failed; running state is unknown.") }
        return KnownProviderProcess(provider: provider, sessionID: suppliedID, processID: 123,
          tty: nil, cwd: fixture.root.path)
      })
    let subtask = try #require(model.subtasks(for: "ECC-101").first { $0.id == record.subtaskID })
    model.openSubtask(subtask, for: fixture.tickets[0])
    try await eventually { model.openingSubtaskIDs.isEmpty }
    #expect(await launcher.spawnCount == 0)
    let error = try #require(model.agentSessionError(for: subtask, ticketID: "ECC-101"))
    #expect(error.contains(unknown ? "running state is unknown" : "already running"))
    #expect(try await store.load(ticketID: "ECC-101")?.subtasks.count == 1)
  }

  @Test("A task-tagged launch appears immediately and receives provisional terminal labels")
  func provisionalLaunchAppearsImmediately() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let terminal = LabelRecorder()
    let model = await fixture.model(agent: ControlledQueueAgent(), terminalController: terminal)
    let launchID = UUID().uuidString.lowercased()
    let workspace = fixture.root.appendingPathComponent("ECCFocusQueue-worktrees/ecc-101/agents/\(launchID)")
    let receipt: [String: Any] = [
      "launchID": launchID, "taskID": "ECC-101", "agentID": launchID,
      "cwd": workspace.path, "repositoryPath": fixture.root.path,
      "workspacePolicy": "isolated", "phase": "ready", "title": "Fix agent launch",
      "reference": ["name": "fq-codex-\(launchID)", "serverPID": 10, "createdAt": 20,
        "paneID": "%3", "panePID": 30, "tty": "/dev/ttys099", "executable": "/opt/homebrew/bin/tmux"],
    ]
    let intake = try JSONDecoder().decode(AgentIntakeReceipt.self,
      from: JSONSerialization.data(withJSONObject: receipt))

    try await model.importProvisionalAgentIntakes([intake])

    let agent = try #require(model.visibleAgents(for: "ECC-101").first { $0.id == launchID })
    #expect(agent.workspace?.path == workspace.path)
    #expect(agent.workspace?.managed == true)
    #expect(agent.sessionID == nil)
    let label = try #require(await terminal.labels.last)
    #expect(label.terminalWindowTitle == "Task ECC-101")
    #expect(label.terminalTabTitle == "Task ECC-101 · Codex · \(launchID.suffix(6))")
    let unchanged = try #require(try await store.load(ticketID: "ECC-101"))
    try await model.importProvisionalAgentIntakes([intake])
    #expect(try await store.load(ticketID: "ECC-101")?.updatedAt == unchanged.updatedAt)
    #expect(await terminal.labels.count == 1)
  }

  @Test("An app-created launch enriches its assigned row without replacing task configuration")
  func assignedLaunchEnrichesExistingAgent() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let agentID = UUID().uuidString.lowercased()
    let launchID = UUID().uuidString.lowercased()
    let sessionID = UUID().uuidString.lowercased()
    let workspace = fixture.root.appendingPathComponent("assigned-agent")
    var assigned = TaskSubtask(id: agentID, title: "Keep configured title",
      assignmentDescription: "Keep configured scope", provider: .codex,
      status: .queued, progressSummary: "Waiting for launch",
      includeInitializationPrompt: true, runtimeMode: .tmux)
    assigned.initialPrompt = "Keep configured prompt"
    assigned.tracksCompletion = true
    assigned.parentSubtaskID = "parent-assignment"
    assigned.workspace = .init(path: workspace.path, repositoryPath: fixture.root.path,
      branch: "focus-queue/assigned", managed: true)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: assigned)
    let terminal = LabelRecorder()
    let paneLabels = PaneLabelRecorder()
    let model = await fixture.model(agent: ControlledQueueAgent(), terminalController: terminal,
      labelTmuxPane: { reference, title in
        await paneLabels.record(reference: reference, title: title)
      })
    let intake = try JSONDecoder().decode(AgentIntakeReceipt.self,
      from: JSONSerialization.data(withJSONObject: [
        "launchID": launchID, "taskID": "ECC-101", "agentID": agentID,
        "sessionID": sessionID, "cwd": workspace.path,
        "phase": "ready", "title": "Receipt title must not replace configuration",
        "reference": ["name": "fq-task-ecc-101", "serverPID": 10,
          "createdAt": 20, "paneID": "%3", "panePID": 30,
          "tty": "/dev/ttys099", "executable": "/mock/tmux"],
      ]))

    try await model.importProvisionalAgentIntakes([intake])

    let context = try #require(try await store.load(ticketID: "ECC-101"))
    #expect(context.subtasks.count == 1)
    let enriched = try #require(context.subtasks.first)
    #expect(enriched.id == agentID)
    #expect(enriched.title == "Keep configured title")
    #expect(enriched.assignmentDescription == "Keep configured scope")
    #expect(enriched.initialPrompt == "Keep configured prompt")
    #expect(enriched.parentSubtaskID == "parent-assignment")
    #expect(enriched.tracksCompletion)
    #expect(enriched.workspace == assigned.workspace)
    #expect(enriched.sessionID == sessionID)
    #expect(enriched.tmux == intake.reference)
    #expect(enriched.runtimeMode == .tmux)
    #expect(!context.subtasks.contains { $0.id == launchID })
    #expect(intake.discoveryEnvironment(in: context)["FOCUS_QUEUE_SUBTASK_ID"] == agentID)
    let label = try #require(await terminal.labels.last)
    #expect(label.subtaskID == agentID)
    #expect(label.sessionID == sessionID)
    let paneLabel = try #require(await paneLabels.labels.last)
    #expect(paneLabel.reference == intake.reference)
    #expect(paneLabel.title == "Codex: Keep configured title")
  }

  @Test("Pre-reference notifications do not discover, while one exact reference notification does")
  func intakeReferenceGatesForcedDiscovery() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let counter = DiscoveryCounter()
    let model = await fixture.model(agent: ControlledQueueAgent(), discoverExternalAgents: {
      await counter.record()
      return []
    })
    await counter.reset()
    _ = try await TaskContextStore(root: fixture.root).ensureContext(ticket: fixture.tickets[0])
    let launchID = UUID().uuidString.lowercased()
    let directory = fixture.root.appendingPathComponent("tracking/launches")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("\(launchID).json")
    var receipt: [String: Any] = [
      "launchID": launchID, "taskID": "ECC-101", "agentID": "inherited-agent",
      "cwd": fixture.root.path, "phase": "ready", "title": "Reference race",
    ]
    try JSONSerialization.data(withJSONObject: receipt).write(to: path)

    await model.refreshExternalAgentRegistrations(force: true)
    #expect(await counter.count == 0)
    #expect(model.visibleAgents(for: "ECC-101").contains { $0.id == launchID })
    #expect(!model.visibleAgents(for: "ECC-101").contains { $0.id == "inherited-agent" })

    receipt["reference"] = ["name": "fq-codex-\(launchID)", "serverPID": 10,
      "createdAt": 20, "paneID": "%3", "panePID": 30, "tty": "/dev/ttys099",
      "executable": "/mock/tmux"]
    try JSONSerialization.data(withJSONObject: receipt).write(to: path)
    await model.refreshExternalAgentRegistrations(force: true)
    await model.refreshExternalAgentRegistrations(force: true)
    #expect(await counter.count == 1)
  }

  @Test("Dismissed launches stay dismissed and blocked launches remain until acknowledged")
  func provisionalLaunchDismissalPersists() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let model = await fixture.model(agent: ControlledQueueAgent())
    let launchID = UUID().uuidString.lowercased()
    func intake(phase: String) throws -> AgentIntakeReceipt {
      try JSONDecoder().decode(AgentIntakeReceipt.self,
        from: JSONSerialization.data(withJSONObject: [
          "launchID": launchID, "taskID": "ECC-101", "cwd": fixture.root.path,
          "phase": phase, "title": "Dismiss me",
        ]))
    }
    let preparing = try intake(phase: "preparing")
    try await model.importProvisionalAgentIntakes([preparing])
    let provisional = try #require(model.visibleAgents(for: "ECC-101").first { $0.id == launchID })
    model.removeAgent(provisional, from: fixture.tickets[0])
    try await eventually { model.visibleAgents(for: "ECC-101").isEmpty }

    try await model.importProvisionalAgentIntakes([preparing])
    #expect(model.visibleAgents(for: "ECC-101").isEmpty)
    let blockedID = UUID().uuidString.lowercased()
    let blocked = try JSONDecoder().decode(AgentIntakeReceipt.self,
      from: JSONSerialization.data(withJSONObject: [
        "launchID": blockedID, "taskID": "ECC-101", "cwd": fixture.root.path,
        "phase": "blocked", "note": "Workspace setup failed",
    ]))
    try await model.importProvisionalAgentIntakes([blocked])
    let blockedAgent = try #require(model.visibleAgents(for: "ECC-101").first { $0.id == blockedID })
    #expect(blockedAgent.status == .blocked)
    #expect(blockedAgent.progressSummary == "Workspace setup failed")
    model.removeAgent(blockedAgent, from: fixture.tickets[0])
    try await eventually { !model.visibleAgents(for: "ECC-101").contains { $0.id == blockedID } }
    let terminalContext = try #require(try await store.load(ticketID: "ECC-101"))
    #expect(terminalContext.hasDismissedLaunch(blockedID))
    try await model.importProvisionalAgentIntakes([blocked])
    #expect(try await store.load(ticketID: "ECC-101")?.updatedAt == terminalContext.updatedAt)
  }

  @Test("A launch initializes an existing task directory when its context is missing")
  func provisionalLaunchInitializesMissingContext() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let taskID = "ECC-404"
    try FileManager.default.createDirectory(
      at: fixture.root.appendingPathComponent("tasks/\(taskID)"),
      withIntermediateDirectories: true)
    let launchID = UUID().uuidString.lowercased()
    let receipt = try JSONDecoder().decode(AgentIntakeReceipt.self,
      from: JSONSerialization.data(withJSONObject: [
        "launchID": launchID, "taskID": taskID, "cwd": fixture.root.path,
        "phase": "ready", "title": "Recover missing context",
      ]))

    try await model.importProvisionalAgentIntakes([receipt])

    let context = try #require(try await TaskContextStore(root: fixture.root).load(ticketID: taskID))
    #expect(context.subtasks.contains { $0.id == launchID })
    #expect(FileManager.default.fileExists(atPath: context.planPath))
  }

  @Test("The default provider follows the configured fallback order")
  func defaultProviderFollowsFallbackOrder() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.projects[0].repositoryPath = fixture.root.path
    configuration.tmuxExecutable = "/usr/bin/true"
    configuration.agentProviderFallbackOrder = [.claude, .codex]
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let router = ControlledObjectiveRouter(outcome: .registered(
      routeID: "route-claude", taskID: "ECC-101", subtaskID: "agent-one"))
    let model = await fixture.model(
      agent: ControlledQueueAgent(), objectiveRouter: router, routerUndoWindowSeconds: 0.01)

    #expect(model.defaultAgentProvider == .claude)
    model.routeObjective("Route with the configured provider")
    try await eventually { !model.isRoutingObjective && model.routerStatus?.contains("ECC-101") == true }

    #expect(await router.providers == [.claude])
  }

  @Test("Quota fallback claims the next installed provider once per subtask inside a per-ticket cooldown")
  func quotaFallbackDecision() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    func exhausted(_ id: String, provider: AgentProvider, status: TaskSubtaskStatus = .blocked) -> TaskSubtask {
      var subtask = TaskSubtask(id: id, title: "Worker", provider: provider,
        sessionID: UUID().uuidString, status: status)
      subtask.attention = .quotaExhausted
      return subtask
    }

    let first = exhausted("agent-one", provider: .codex)
    #expect(model.claimQuotaFallback(ticketID: "ECC-101", subtask: first,
      executableAvailable: { $0 == .claude }) == .claude)
    // One fallback per subtask.
    #expect(model.claimQuotaFallback(ticketID: "ECC-101", subtask: first,
      executableAvailable: { _ in true }) == nil)
    // The per-ticket cooldown blocks a different subtask right after.
    let second = exhausted("agent-two", provider: .codex)
    #expect(model.claimQuotaFallback(ticketID: "ECC-101", subtask: second,
      executableAvailable: { _ in true }) == nil)
    let afterCooldown = Date().addingTimeInterval(QueueViewModel.quotaFallbackCooldownSeconds + 1)
    #expect(model.claimQuotaFallback(ticketID: "ECC-101", subtask: second, now: afterCooldown,
      executableAvailable: { _ in true }) == .claude)
    // Another ticket is not covered by the first ticket's cooldown.
    #expect(model.claimQuotaFallback(ticketID: "ECC-102", subtask: exhausted("agent-three", provider: .codex),
      executableAvailable: { _ in true }) == .claude)
    // The last provider in the order has nowhere to fall back to.
    #expect(model.claimQuotaFallback(ticketID: "ECC-900", subtask: exhausted("agent-four", provider: .claude),
      executableAvailable: { _ in true }) == nil)
    // No installed CLI means no fallback.
    #expect(model.claimQuotaFallback(ticketID: "ECC-901", subtask: exhausted("agent-five", provider: .codex),
      executableAvailable: { _ in false }) == nil)
    // Completed, removed, and non-quota subtasks never fall back.
    var completed = exhausted("agent-six", provider: .codex, status: .completed)
    #expect(model.claimQuotaFallback(ticketID: "ECC-902", subtask: completed,
      executableAvailable: { _ in true }) == nil)
    completed = exhausted("agent-seven", provider: .codex)
    completed.attention = .failed
    #expect(model.claimQuotaFallback(ticketID: "ECC-903", subtask: completed,
      executableAvailable: { _ in true }) == nil)

    #expect(QueueViewModel.quotaFallbackProvider(for: .codex, fallbackOrder: [.codex, .claude],
      executableAvailable: { _ in false }) == nil)
    // A provider listed last has no later fallback; an unlisted provider starts at the front.
    #expect(QueueViewModel.quotaFallbackProvider(for: .codex, fallbackOrder: [.claude, .codex],
      executableAvailable: { _ in true }) == nil)
    #expect(QueueViewModel.quotaFallbackProvider(for: .codex, fallbackOrder: [.claude],
      executableAvailable: { $0 == .claude }) == .claude)
  }

  @Test("Escalation provider resolution prefers the request and falls back when its CLI is missing")
  func escalationProviderResolution() {
    #expect(QueueViewModel.escalationProvider(requested: "claude", fallbackOrder: [.codex, .claude],
      executableAvailable: { _ in true }) == .claude)
    #expect(QueueViewModel.escalationProvider(requested: "claude", fallbackOrder: [.codex, .claude],
      executableAvailable: { $0 == .codex }) == .codex)
    #expect(QueueViewModel.escalationProvider(requested: "kimi", fallbackOrder: [.codex, .claude],
      executableAvailable: { $0 == .claude }) == .claude)
    #expect(QueueViewModel.escalationProvider(requested: nil, fallbackOrder: [.codex, .claude],
      executableAvailable: { _ in false }) == nil)
  }

  @Test("Escalation launch requests auto-launch one agent per pass and are consumed")
  func escalationLaunchRequestConsumption() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = externalWorkspace(for: fixture.root, suffix: "escalation-repo")
    defer { try? FileManager.default.removeItem(at: repository) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let git = FoundationProcessRunner()
    for arguments in [["init", "-q"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"]] {
      #expect(try await git.run(.init(executable: "/usr/bin/git", arguments: arguments,
        workingDirectory: repository.path)).succeeded)
    }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.workspacePath = repository.path
    configuration.projects[0].workspacePath = repository.path
    configuration.projects[0].repositoryPath = repository.path
    configuration.tmuxExecutable = "/usr/bin/true"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let requests = fixture.paths.launchRequestsDirectory
    try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    try encoder.encode(AgentLaunchRequest(ticketId: "ECC-101", title: "Fix the customer crash",
      provider: "claude", model: "claude-test", effort: "high",
      prompt: "Focus Queue task ECC-101: reproduce the crash"))
      .write(to: requests.appendingPathComponent("ECC-101.json"))
    try encoder.encode(AgentLaunchRequest(ticketId: "ECC-102", title: "Second escalation",
      provider: "codex")).write(to: requests.appendingPathComponent("ECC-102.json"))
    try encoder.encode(AgentLaunchRequest(ticketId: "ECC-999", title: "Unknown ticket"))
      .write(to: requests.appendingPathComponent("ECC-999.json"))
    let runner = EscalationLaunchRunner()
    let model = await fixture.model(agent: ControlledQueueAgent(),
      terminalController: ManagedResumeRecorder(),
      taskAgentLauncher: TaskAgentLauncher(runner: runner, tmuxServerName: "escalation-test"),
      providerExecutableAvailable: { _ in true })

    await model.refresh(userInitiated: true)
    try await eventually { model.launchingTaskIDs.isEmpty && !model.subtasks(for: "ECC-101").isEmpty }

    let first = try #require(model.subtasks(for: "ECC-101").first)
    #expect(first.provider == .claude)
    #expect(first.title == "Fix the customer crash")
    #expect(first.launchConfiguration?.model == "claude-test")
    #expect(first.launchConfiguration?.effort == "high")
    #expect(first.initialPrompt?.contains("ECC-101") == true)
    // One auto-launch per pass; the second request stays queued and unknown tickets are left alone.
    #expect(model.subtasks(for: "ECC-102").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: requests.appendingPathComponent("ECC-101.json").path))
    #expect(FileManager.default.fileExists(atPath: requests.appendingPathComponent("ECC-102.json").path))
    #expect(FileManager.default.fileExists(atPath: requests.appendingPathComponent("ECC-999.json").path))

    await model.refresh(userInitiated: true)
    try await eventually { model.launchingTaskIDs.isEmpty && !model.subtasks(for: "ECC-102").isEmpty }
    #expect(model.subtasks(for: "ECC-102").first?.provider == .codex)
    #expect(!FileManager.default.fileExists(atPath: requests.appendingPathComponent("ECC-102.json").path))
    // Consumed requests never relaunch.
    await model.refresh(userInitiated: true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.subtasks(for: "ECC-101").count == 1)
    #expect(model.subtasks(for: "ECC-102").count == 1)
  }

  @Test("A launch request for a ticket with a live agent is consumed without relaunching")
  func escalationLaunchRequestDedupesLiveAgents() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    _ = try await store.upsertSubtask(ticketID: "ECC-101",
      subtask: TaskSubtask(id: "live-worker", title: "Live agent",
        sessionID: UUID().uuidString, status: .working, lastHeartbeatAt: Date()))
    let requests = fixture.paths.launchRequestsDirectory
    try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
    try JSONEncoder().encode(AgentLaunchRequest(ticketId: "ECC-101", title: "Duplicate escalation"))
      .write(to: requests.appendingPathComponent("ECC-101.json"))
    let runner = EscalationLaunchRunner()
    let model = await fixture.model(agent: ControlledQueueAgent(),
      taskAgentLauncher: TaskAgentLauncher(runner: runner, tmuxServerName: "escalation-dedupe"),
      providerExecutableAvailable: { _ in true })

    await model.refresh(userInitiated: true)
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.subtasks(for: "ECC-101").map(\.id) == ["live-worker"])
    #expect(!FileManager.default.fileExists(atPath: requests.appendingPathComponent("ECC-101.json").path))
    #expect(await runner.commands.contains { $0.arguments.contains("new-session") } == false)
  }

  @Test("The escalation auto-launch setting leaves requests queued when disabled")
  func escalationLaunchRequestsRespectDisabledSetting() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.agentEscalationAutoLaunch = false
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let requests = fixture.paths.launchRequestsDirectory
    try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
    try JSONEncoder().encode(AgentLaunchRequest(ticketId: "ECC-101", title: "Held escalation"))
      .write(to: requests.appendingPathComponent("ECC-101.json"))
    let runner = EscalationLaunchRunner()
    let model = await fixture.model(agent: ControlledQueueAgent(),
      taskAgentLauncher: TaskAgentLauncher(runner: runner, tmuxServerName: "escalation-off"),
      providerExecutableAvailable: { _ in true })

    await model.refresh(userInitiated: true)
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.subtasks(for: "ECC-101").isEmpty)
    #expect(FileManager.default.fileExists(atPath: requests.appendingPathComponent("ECC-101.json").path))
    #expect(await runner.commands.contains { $0.arguments.contains("new-session") } == false)
  }

  private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.conditionTimedOut
  }
}

private enum TestFailure: Error { case unexpectedExternalAction, conditionTimedOut }

private actor SuspendedRenameDashboardRepository: DashboardManaging {
  private let base = JSONDashboardRepository()
  private var renameContinuation: CheckedContinuation<Void, Never>?

  var hasPendingRename: Bool { renameContinuation != nil }

  func load(from url: URL) async throws -> DashboardDocument {
    try await base.load(from: url)
  }

  func modificationDate(at url: URL) async throws -> Date? {
    try await base.modificationDate(at: url)
  }

  func loadSnapshot(from url: URL) async throws -> DashboardSnapshot {
    try await base.loadSnapshot(from: url)
  }

  func createTicket(
    _ ticket: DashboardTicket,
    in url: URL,
    expectedRevision: DashboardRevision,
    checking otherDashboardURLs: [URL]
  ) async throws -> DashboardSnapshot {
    try await base.createTicket(
      ticket, in: url, expectedRevision: expectedRevision, checking: otherDashboardURLs)
  }

  func renameTicket(
    id: String,
    to title: String,
    in url: URL,
    expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    let updated = try await base.renameTicket(
      id: id, to: title, in: url, expectedRevision: expectedRevision)
    await withCheckedContinuation { continuation in
      renameContinuation = continuation
    }
    return updated
  }

  func resumeRename() {
    renameContinuation?.resume()
    renameContinuation = nil
  }
}

private final class ObservationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func record() { lock.withLock { value += 1 } }
}

private func externalWorkspace(for supportRoot: URL, suffix: String = "repo") -> URL {
  supportRoot.deletingLastPathComponent().appendingPathComponent(
    "\(supportRoot.lastPathComponent)-\(suffix)")
}

@MainActor
private struct Fixture {
  let root: URL
  let paths: AppPaths
  let tickets: [DashboardTicket]

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("focus-queue-model-\(UUID().uuidString)")
    paths = AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path])
    tickets = ["ECC-101", "ECC-102"].map {
      DashboardTicket(id: $0, title: "Task \($0)", status: "open", summary: "Implement and verify \($0)")
    }
    try FileManager.default.createDirectory(at: paths.ingestionRuntimeDirectory, withIntermediateDirectories: true)
    let dashboardURL = root.appendingPathComponent("dashboard.json")
    try JSONEncoder().encode(DashboardDocument(tickets: tickets)).write(to: dashboardURL)
    var config = AppConfiguration.eccDefault()
    config.dashboardPath = dashboardURL.path
    config.workspacePath = root.path
    config.refreshIntervalSeconds = 300
    config.dailyRoutines = []
    try await JSONConfigurationRepository(url: paths.configurationFile).save(config)
  }

  func model(agent: ControlledQueueAgent, programLog: ProgramLogStore = ProgramLogStore(),
             verifier: (any CompletionVerifying)? = nil,
             terminalController: (any WezTermControlling)? = nil,
             dashboardRepository: any DashboardManaging = JSONDashboardRepository(),
             taskAgentLauncher: TaskAgentLauncher = TaskAgentLauncher(),
             objectiveRouter: any QueueObjectiveRouting = QueueObjectiveRouter(),
             routerMonitorIntervalSeconds: Double = 2,
             routerUndoWindowSeconds: Double = 0,
             connectorDiagnosticsRunner: any ProcessRunning = FoundationProcessRunner(),
             discoverExternalAgents: @escaping @Sendable () async throws -> [KnownProviderProcess] = { [] },
             labelTmuxPane: @escaping @Sendable (TmuxSessionReference, String) async -> Void = { _, _ in },
             identifyManagedAgent: (@Sendable (TaskSubtask, WezTermConfiguration) async throws -> String?)? = nil,
             providerExecutableAvailable: (@Sendable (AgentProvider) -> Bool)? = nil,
             locateExistingAgent: @escaping @Sendable (AgentProvider, String) async throws -> KnownProviderProcess? = { _, _ in nil }) async -> QueueViewModel {
    let boundary = ForbiddenExternalActions()
    let model = QueueViewModel(paths: paths, programLog: programLog,
      dashboardRepository: dashboardRepository,
      terminalController: terminalController ?? boundary,
      verifier: verifier ?? boundary, queueAgent: agent, pullRequestQueueLoader: boundary,
      taskAgentLauncher: taskAgentLauncher,
      objectiveRouter: objectiveRouter,
      routerMonitorIntervalSeconds: routerMonitorIntervalSeconds,
      routerUndoWindowSeconds: routerUndoWindowSeconds,
      connectorDiagnosticsRunner: connectorDiagnosticsRunner,
      discoverExternalAgents: discoverExternalAgents,
      labelTmuxPane: labelTmuxPane,
      maintenanceEnabled: false,
      identifyManagedAgent: identifyManagedAgent,
      providerExecutableAvailable: providerExecutableAvailable,
      locateExistingAgent: locateExistingAgent)
    await model.bootstrap()
    await model.bootstrapTail?.value
    #expect(model.loadError == nil)
    return model
  }

  func report(_ id: String, finishedAt: String) -> DailyReportDocument {
    DailyReportDocument(runID: id, trigger: .manual, mode: .unseenOnly,
      startedAt: finishedAt, finishedAt: finishedAt, status: .success,
      summary: "Messages reviewed", tokenBudget: 1000, usage: nil, platforms: [], errors: [])
  }

  func archive(_ report: DailyReportDocument) throws {
    let directory = paths.ingestionRuntimeDirectory.appendingPathComponent("reports/2026-09-10")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(report).write(to: directory.appendingPathComponent("\(report.runID).json"))
  }
}

private final class CountingDashboardRepository: DashboardManaging, @unchecked Sendable {
  private let base = JSONDashboardRepository()
  private let lock = NSLock()
  private var loadCount = 0
  var loads: Int { lock.withLock { loadCount } }
  func load(from url: URL) async throws -> DashboardDocument {
    lock.withLock { loadCount += 1 }
    return try await base.load(from: url)
  }
  func modificationDate(at url: URL) async throws -> Date? { try await base.modificationDate(at: url) }
  func loadSnapshot(from url: URL) async throws -> DashboardSnapshot {
    try await base.loadSnapshot(from: url)
  }
  func createTicket(
    _ ticket: DashboardTicket, in url: URL, expectedRevision: DashboardRevision,
    checking otherDashboardURLs: [URL]
  ) async throws -> DashboardSnapshot {
    try await base.createTicket(ticket, in: url, expectedRevision: expectedRevision,
      checking: otherDashboardURLs)
  }
  func renameTicket(
    id: String, to title: String, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.renameTicket(id: id, to: title, in: url, expectedRevision: expectedRevision)
  }
}

private actor ControlledObjectiveRouter: QueueObjectiveRouting {
  private(set) var launchCount = 0
  private(set) var waitCount = 0
  private(set) var objectives: [String] = []
  private(set) var providers: [AgentProvider] = []
  private var outcomes: [QueueRouterOutcome]

  init(outcome: QueueRouterOutcome) { outcomes = [outcome] }
  init(outcomes: [QueueRouterOutcome]) { self.outcomes = outcomes }

  func launch(
    objective: String, repositoryPath: String, supportDirectory: URL,
    tmuxExecutable: String, shellPath: String?
  ) async throws -> QueueRouterRuntime {
    try await launch(
      objective: objective, repositoryPath: repositoryPath, supportDirectory: supportDirectory,
      tmuxExecutable: tmuxExecutable, shellPath: shellPath, provider: .codex)
  }

  func launch(
    objective: String, repositoryPath: String, supportDirectory: URL,
    tmuxExecutable: String, shellPath: String?, provider: AgentProvider
  ) async throws -> QueueRouterRuntime {
    launchCount += 1
    objectives.append(objective)
    providers.append(provider)
    try await Task.sleep(for: .milliseconds(30))
    let reference = try TmuxController.decode(
      "fq-router-test|1|1|%1|2|/dev/ttys001|0\n", executable: tmuxExecutable)[0]
    return QueueRouterRuntime(tmux: reference, startedAt: Date())
  }

  func waitForOutcome(
    _ runtime: QueueRouterRuntime, supportDirectory: URL, timeoutSeconds: Double
  ) async throws -> QueueRouterOutcome {
    waitCount += 1
    if outcomes.count > 1 { return outcomes.removeFirst() }
    return outcomes[0]
  }
}

private actor SuspendedRouterReplacementFixture: QueueObjectiveRouting {
  private var launchCount = 0
  private var firstWaitCount = 0
  private var firstMonitor: CheckedContinuation<QueueRouterOutcome, any Error>?

  var hasSuspendedFirstMonitor: Bool { firstMonitor != nil }

  func launch(
    objective: String, repositoryPath: String, supportDirectory: URL,
    tmuxExecutable: String, shellPath: String?
  ) async throws -> QueueRouterRuntime {
    launchCount += 1
    let isFirst = launchCount == 1
    let name = isFirst ? "fq-router-first" : "fq-router-second"
    let reference = try TmuxController.decode(
      "\(name)|\(100 + launchCount)|\(launchCount)|%\(launchCount)|\(200 + launchCount)|/dev/ttys00\(launchCount)|0\n",
      executable: tmuxExecutable)[0]
    return QueueRouterRuntime(tmux: reference, startedAt: Date())
  }

  func waitForOutcome(
    _ runtime: QueueRouterRuntime, supportDirectory: URL, timeoutSeconds: Double
  ) async throws -> QueueRouterOutcome {
    if runtime.tmuxName == "fq-router-first" {
      firstWaitCount += 1
      if firstWaitCount == 1 {
        return .waiting(routeID: "route-first", recoveryPath: "/tmp/route-first.json")
      }
      if firstWaitCount == 2 {
        return try await withCheckedThrowingContinuation { firstMonitor = $0 }
      }
      return .registered(
        routeID: "route-first", taskID: "ECC-101", subtaskID: "agent-first")
    }
    return .waiting(routeID: "route-second", recoveryPath: "/tmp/route-second.json")
  }

  func recoveryReference(
    _ runtime: QueueRouterRuntime, supportDirectory: URL
  ) async throws -> TmuxSessionReference {
    if runtime.tmuxName == "fq-router-first" { throw TmuxError.stopped }
    return try #require(runtime.confirmedReference)
  }

  func resumeFirstMonitor() {
    firstMonitor?.resume(returning: .registered(
      routeID: "route-first", taskID: "ECC-101", subtaskID: "agent-first"))
    firstMonitor = nil
  }
}

private actor DiscoveryCounter {
  private(set) var count = 0
  func record() { count += 1 }
  func reset() { count = 0 }
}

private actor DirectCreationRunner: ProcessRunning {
  private(set) var spawnCount = 0
  private(set) var commands: [ProcessSpecification] = []
  private let failFirstSpawn: Bool
  init(failFirstSpawn: Bool = false) { self.failFirstSpawn = failFirstSpawn }
  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    commands.append(specification)
    if specification.arguments == ["cli", "list", "--format", "json"] {
      return .init(exitCode: 0, standardOutput: "[]", standardError: "", timedOut: false)
    }
    guard specification.arguments.starts(with: ["cli", "spawn"]) else {
      throw TestFailure.unexpectedExternalAction
    }
    spawnCount += 1
    if failFirstSpawn && spawnCount == 1 {
      return .init(exitCode: 1, standardOutput: "", standardError: "Fixture launch unavailable", timedOut: false)
    }
    return .init(exitCode: 0, standardOutput: "42\n", standardError: "", timedOut: false)
  }
}

private actor ManagedResumeRunner: ProcessRunning {
  private(set) var commands: [ProcessSpecification] = []
  private var started = false
  let taskID: String
  let agentID: String

  init(taskID: String, agentID: String) {
    self.taskID = taskID
    self.agentID = agentID
  }

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    commands.append(specification)
    let arguments = specification.arguments
    if arguments.contains("has-session") {
      return result(exit: 1, error: "no server running")
    }
    if arguments.contains("new-session") {
      started = true
      return result("fq-task-\(taskID.lowercased())|123|1000|%9|||0\n")
    }
    if arguments.contains("display-message") {
      return result("fq-task-\(taskID.lowercased())|123|1000|%9|456|/dev/ttys099|0\n")
    }
    if arguments.contains("list-panes") {
      guard started else { return result(exit: 1, error: "no server running") }
      return result("fq-task-\(taskID.lowercased())|123|1000|%9|456|/dev/ttys099|0|@1|0|160|50|0|0|80|24|\(agentID)|||1|auto\n")
    }
    if arguments.contains("show-options"), arguments.contains("status") {
      return result("off\n")
    }
    if arguments.contains("list-clients") {
      return result()
    }
    return result()
  }

  private func result(_ output: String = "", exit: Int32 = 0, error: String = "") -> ProcessResult {
    .init(exitCode: exit, standardOutput: output, standardError: error, timedOut: false)
  }
}

private actor EscalationLaunchRunner: ProcessRunning {
  private(set) var commands: [ProcessSpecification] = []
  private var started = false

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    commands.append(specification)
    let arguments = specification.arguments
    let name = arguments.first(where: { $0.hasPrefix("fq-task-") }) ?? "fq-task-ecc-101"
    if arguments.contains("has-session") {
      return result(exit: 1, error: "no server running")
    }
    if arguments.contains("new-session") {
      started = true
      return result("\(name)|123|1000|%9|||0\n")
    }
    if arguments.contains("display-message") {
      return result("\(name)|123|1000|%9|456|/dev/ttys099|0\n")
    }
    if arguments.contains("list-panes") {
      guard started else { return result(exit: 1, error: "no server running") }
      return result("\(name)|123|1000|%9|456|/dev/ttys099|0|@1|0|160|50|0|0|80|24|\(UUID().uuidString)|||1|auto\n")
    }
    if arguments.contains("show-options"), arguments.contains("status") {
      return result("off\n")
    }
    if arguments.contains("list-clients") {
      return result()
    }
    return result()
  }

  private func result(_ output: String = "", exit: Int32 = 0, error: String = "") -> ProcessResult {
    .init(exitCode: exit, standardOutput: output, standardError: error, timedOut: false)
  }
}

private actor PresentationRepairRunner: ProcessRunning {
  private(set) var repairedContextIDs: Set<String> = []
  private let taskID: String

  init(taskID: String) { self.taskID = taskID }

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    let arguments = specification.arguments
    if arguments.contains("@focus-queue-usage-command"),
       arguments.contains(where: { $0.contains("/tasks/\(taskID)/context.json") }) {
      repairedContextIDs.insert(taskID)
    }
    if arguments.contains("@focus-queue-task") { return result("\(taskID)\n") }
    if arguments.contains("list-panes") {
      return result("fq-task-\(taskID.lowercased())|123|1000|%9|456|/dev/ttys099|0|@1|0|160|50|0|0|160|49|stored-agent|||1|auto\n")
    }
    if arguments.contains("display-message") { return result("%9\n") }
    if arguments.contains("@focus-queue-task-title") {
      return result("Stored task outside the visible project\n")
    }
    if arguments.contains("status-format[0]") { return result("#[align=left] #I:#W\n") }
    if arguments.contains("status") { return result("on\n") }
    return result()
  }

  private func result(_ output: String = "") -> ProcessResult {
    .init(exitCode: 0, standardOutput: output, standardError: "", timedOut: false)
  }
}

private actor ManagedResumeRecorder: WezTermControlling {
  private(set) var opened: [TmuxSessionReference] = []

  func openManagedAgentRuntime(_ tmux: TmuxSessionReference, taskID: String,
    subtaskID: String, provider: AgentProvider, taskTitle: String,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    opened.append(tmux)
    return .spawned(paneID: nil)
  }

  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { [] }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { [] }
  func attach(paneID: Int, tabTitle: String, windowTitle: String,
    configuration: WezTermConfiguration) async throws { throw TestFailure.unexpectedExternalAction }
  func focusOrSpawn(directory: String, taskID: String, taskTitle: String,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
  func focusOrResume(session: TaskAgentSession, taskID: String,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
}

private actor ConnectorDiagnosticsRunnerStub: ProcessRunning {
  private(set) var commands: [ProcessSpecification] = []

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    commands.append(specification)
    return ProcessResult(
      exitCode: 0,
      standardOutput: """
        {
          "version": 1,
          "mode": "offline",
          "authenticationVerified": false,
          "connectors": [
            {"id":"discord","status":"setup_required","coverage":"unconfigured","nextStep":"Configure Discord."},
            {"id":"telegram","status":"limited","coverage":"agent_session_archive","nextStep":"Configure Telegram."},
            {"id":"email","status":"configured_unverified","coverage":"configured_apple_mail_account_and_mailboxes","nextStep":"Verify Mail."},
            {"id":"github","status":"configured_unverified","coverage":"configured_repositories","nextStep":"Verify GitHub."}
          ]
        }
        """,
      standardError: "",
      timedOut: false
    )
  }
}

private actor DirectViewRecorder: WezTermControlling {
  let root: URL
  let failReveal: Bool
  private(set) var opened = false
  init(root: URL, failReveal: Bool) { self.root = root; self.failReveal = failReveal }
  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { [] }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { [] }
  func attach(paneID: Int, tabTitle: String, windowTitle: String,
    configuration: WezTermConfiguration) async throws { throw TestFailure.unexpectedExternalAction }
  func focusOrResume(session: TaskAgentSession, taskID: String,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
  func openDirectRuntime(paneID: Int, socketPath: String?, taskID: String,
    provider: AgentProvider, taskTitle: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    let context = try await TaskContextStore(root: root).load(ticketID: taskID)
    let saved = context?.subtasks.first { $0.terminalPaneID == paneID && $0.provider == provider }
    #expect(saved?.terminalPaneID == paneID)
    #expect(saved?.runtimeMode == .terminal)
    opened = true
    if failReveal { throw WezTermError.actionFailed("Fixture window failure") }
    return .focused(paneID: paneID)
  }
  func focusOrSpawn(directory: String, taskID: String, taskTitle: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
}

private actor LabelRecorder: WezTermControlling {
  private(set) var labels: [TaskAgentSession] = []
  func labelTmuxClients(session: TaskAgentSession,
    configuration: WezTermConfiguration) async throws { labels.append(session) }
  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { [] }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { [] }
  func attach(paneID: Int, tabTitle: String, windowTitle: String,
    configuration: WezTermConfiguration) async throws { throw TestFailure.unexpectedExternalAction }
  func focusOrResume(session: TaskAgentSession, taskID: String,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
  func focusOrSpawn(directory: String, taskID: String, taskTitle: String,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
}

private actor PaneLabelRecorder {
  struct Label: Sendable {
    let reference: TmuxSessionReference
    let title: String
  }
  private(set) var labels: [Label] = []
  func record(reference: TmuxSessionReference, title: String) {
    labels.append(.init(reference: reference, title: title))
  }
}

private actor ControlledQueueAgent: QueueAgentChatting {
  private(set) var messages: [String] = []
  private(set) var projectScopes: [String?] = []
  private var pending: CheckedContinuation<QueueAgentReply, any Error>?
  var hasPendingReply: Bool { pending != nil }

  func send(message: String, dashboardPath: String, workspace: String, visibleOrder: [String],
    deferredTicketIDs: [String], configuration: VerifierConfiguration) async throws -> QueueAgentReply {
    messages.append(message)
    projectScopes.append(configuration.projectScopeID)
    return try await withCheckedThrowingContinuation { pending = $0 }
  }

  func reply(_ message: String) {
    pending?.resume(returning: QueueAgentReply(message: message, log: "headless test"))
    pending = nil
  }
}

private struct SubtaskVerifier: CompletionVerifying {
  let store: TaskContextStore
  let persistCompletion: Bool
  func verify(ticketID: String, requestFile: URL, workspace: String,
    configuration: VerifierConfiguration) async throws -> VerificationRunResult {
    let request = try JSONDecoder().decode(CompletionRequest.self, from: Data(contentsOf: requestFile))
    if persistCompletion, let subtaskID = request.subtaskID {
      _ = try await store.updateProgress(ticketID: ticketID, subtaskID: subtaskID,
        status: .completed, summary: "Headless verification passed")
    }
    return VerificationRunResult(succeeded: true, summary: "Review finished", log: "Test evidence")
  }
}

private actor CountingRefusalVerifier: CompletionVerifying {
  private(set) var ticketIDs: [String] = []
  func verify(ticketID: String, requestFile: URL, workspace: String,
    configuration: VerifierConfiguration) async throws -> VerificationRunResult {
    ticketIDs.append(ticketID)
    return VerificationRunResult(succeeded: false,
      summary: "Acceptance evidence still missing", log: "Headless review refusal")
  }
}

private actor ControlledCompletionVerifier: CompletionVerifying {
  private var pending: CheckedContinuation<VerificationRunResult, Never>?
  var hasPendingReply: Bool { pending != nil }
  func verify(ticketID: String, requestFile: URL, workspace: String,
    configuration: VerifierConfiguration) async throws -> VerificationRunResult {
    await withCheckedContinuation { pending = $0 }
  }
  func reply() {
    pending?.resume(returning: VerificationRunResult(succeeded: false,
      summary: "A late review still needs evidence", log: "Retained review evidence"))
    pending = nil
  }
}

/// All integration boundaries fail immediately if these state tests accidentally
/// attempt terminal manipulation, model execution, or network access.
private struct ForbiddenExternalActions: WezTermControlling, CompletionVerifying, PullRequestQueueLoading {
  private func forbidden<T>() throws -> T {
    Issue.record("State integration test attempted an external action")
    throw TestFailure.unexpectedExternalAction
  }
  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { try forbidden() }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { try forbidden() }
  func attach(paneID: Int, tabTitle: String, windowTitle: String, configuration: WezTermConfiguration) async throws { let _: Void = try forbidden() }
  func focusOrSpawn(directory: String, taskID: String, taskTitle: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult { try forbidden() }
  func focusOrResume(session: TaskAgentSession, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult { try forbidden() }
  func verify(ticketID: String, requestFile: URL, workspace: String, configuration: VerifierConfiguration) async throws -> VerificationRunResult { try forbidden() }
  func load(repository: String, closedSince: String) async throws -> PullRequestQueueSnapshot { try forbidden() }
}

private actor RecallRecorder: WezTermControlling {
  private(set) var sessions: [TaskAgentSession] = []
  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { [] }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { [] }
  func attach(paneID: Int, tabTitle: String, windowTitle: String, configuration: WezTermConfiguration) async throws {}
  func focusOrSpawn(directory: String, taskID: String, taskTitle: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    Issue.record("Recall attempted to open a plain shell")
    return .spawned(paneID: 42)
  }
  func focusOrResume(session: TaskAgentSession, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    sessions.append(session)
    return .focused(paneID: 42)
  }
}

private actor ClosedDirectRecorder: WezTermControlling {
  let transportFailure: Bool
  init(transportFailure: Bool) { self.transportFailure = transportFailure }
  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { [] }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { [] }
  func attach(paneID: Int, tabTitle: String, windowTitle: String, configuration: WezTermConfiguration) async throws { }
  func focusOrSpawn(directory: String, taskID: String, taskTitle: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
  func focusOrResume(session: TaskAgentSession, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
  func openDirectRuntime(paneID: Int, socketPath: String?, taskID: String, provider: AgentProvider,
    taskTitle: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    if paneID == 7 {
      if transportFailure { throw WezTermError.actionFailed("Transport failed") }
      throw WezTermError.runtimeClosed
    }
    return .focused(paneID: paneID)
  }
}

private actor HoldingRecallRecorder: WezTermControlling {
  let fails: Bool
  private var released = false

  init(fails: Bool) { self.fails = fails }

  func openManagedRuntime(_ saved: TmuxSessionReference, taskID: String, provider: AgentProvider,
    taskTitle: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    while !released { try await Task.sleep(for: .milliseconds(10)) }
    if fails { throw WezTermError.actionFailed("Fixture session failure") }
    return .focused(paneID: 42)
  }

  func release() { released = true }

  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { [] }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { [] }
  func attach(paneID: Int, tabTitle: String, windowTitle: String,
    configuration: WezTermConfiguration) async throws {}
  func focusOrSpawn(directory: String, taskID: String, taskTitle: String,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
  func focusOrResume(session: TaskAgentSession, taskID: String,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    while !released { try await Task.sleep(for: .milliseconds(10)) }
    if fails { throw WezTermError.actionFailed("Fixture session failure") }
    return .focused(paneID: 42)
  }
}
