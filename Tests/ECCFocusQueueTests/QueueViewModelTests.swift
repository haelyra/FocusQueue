import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import FocusQueueCore
import Darwin

@testable import ECCFocusQueue

@Suite("Queue app state integration")
@MainActor
struct QueueViewModelTests {
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
      terminalController: boundary, queueAgent: ControlledQueueAgent(),
      pullRequestQueueLoader: boundary, discoverExternalAgents: { [] },
      maintenanceEnabled: false, locateExistingAgent: { _, _ in nil })

    await model.bootstrap()

    #expect(model.loadError == nil)
    #expect(model.visibleAgents(for: "ECC-101").map(\.id) == ["primed-worker"])
    if let tail = model.bootstrapTail { await tail.value }
    #expect(model.visibleAgents(for: "ECC-101").map(\.id) == ["primed-worker"])
  }

  @Test("PDF dark mode follows the app appearance until the viewer toggle overrides it")
  func pdfDarkModeDefaultsToAppearance() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.setAppearance(.light)
    #expect(!model.isPDFDarkMode)
    model.setAppearance(.dark)
    #expect(model.isPDFDarkMode)
    model.togglePDFDarkMode()
    #expect(!model.isPDFDarkMode)
    model.togglePDFDarkMode()
    #expect(model.isPDFDarkMode)
    model.togglePDFDarkMode()
    model.setAppearance(.dark)
    #expect(model.isPDFDarkMode, "Changing the app appearance returns PDFs to the default")
  }

  @Test("A completed agent keeps running and is never archived through refresh")
  func completedAgentKeepsRunning() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let launcher = DirectCreationRunner()
    let model = await fixture.model(agent: ControlledQueueAgent(), taskAgentLauncher: TaskAgentLauncher(runner: launcher))
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let agent = TaskSubtask(id: "completed-worker", title: "Done", sessionID: UUID().uuidString, status: .completed)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: agent)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(id: "pending", title: "Pending"))
    try await Task.sleep(for: .seconds(2.1))
    await model.refresh()
    let retained = try #require(model.subtasks(for: "ECC-101").first { $0.id == agent.id })
    #expect(retained.agentRemovedAt == nil)
    #expect(retained.completionTerminalRetained == nil)
    #expect(await launcher.commands.isEmpty)
    // Approving the subtask by hand is completion too; it must not retire the agent either.
    model.overrideCompletion(retained, for: fixture.tickets[0])
    try await Task.sleep(for: .seconds(2.1))
    await model.refresh()
    #expect(model.subtasks(for: "ECC-101").first { $0.id == agent.id }?.agentRemovedAt == nil)
    #expect(await launcher.commands.isEmpty)
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

  @Test("Discovered Codex subagents never add a second agent for one Codex session")
  func discoveredSubagentDoesNotAddAgent() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let parentID = UUID().uuidString.lowercased()
    let childID = UUID().uuidString.lowercased()
    let laterID = UUID().uuidString.lowercased()
    let rootPath = fixture.root.path
    var parent = TaskSubtask(id: "parent-agent", title: "Parent agent", sessionID: parentID)
    parent.workspace = AgentWorkspace(path: rootPath, repositoryPath: rootPath)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: parent)

    // The root process is listed after the subagent, so its row proves the
    // subagent was already processed.
    let model = await fixture.model(
      agent: ControlledQueueAgent(), terminalController: LabelRecorder(),
      discoverExternalAgents: {
      [KnownProviderProcess(
        provider: .codex, sessionID: childID, parentSessionID: parentID,
        isSubagent: true, promptHint: "registration fix", processID: 42,
        tty: nil, cwd: rootPath),
       KnownProviderProcess(provider: .codex, sessionID: laterID, processID: 43,
        tty: nil, cwd: rootPath)]
      })
    model.setPanelVisible(false)
    model.setPanelVisible(true)
    await model.refresh()

    try await eventually {
      try await store.load(ticketID: "ECC-101")?.subtasks.contains { $0.sessionID == laterID } == true
    }
    let sessions = try await store.load(ticketID: "ECC-101")?.subtasks.compactMap(\.sessionID)
    #expect(sessions?.contains(childID) == false)
    #expect(sessions?.filter { $0 == parentID }.count == 1)
  }

  @Test("Transcript observer retains a result followed by newer working activity")
  func transcriptObserverAppliesEveryEventInOnePoll() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let sessionID = UUID().uuidString
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(
      id: "observed-worker", title: "Observed worker", provider: .codex,
      sessionID: sessionID))
    let transcriptRoot = fixture.root.appendingPathComponent("activity")
    let sessions = transcriptRoot.appendingPathComponent(".codex/sessions/2026/09/29")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let result = #"{"timestamp":"2026-09-29T18:00:00Z","type":"event_msg","payload":{"type":"turn_complete","thread_id":"\#(sessionID)","last_agent_message":"Ready to review"}}"#
    let working = #"{"timestamp":"2026-09-29T18:01:00Z","type":"event_msg","payload":{"type":"turn_started","thread_id":"\#(sessionID)"}}"#
    try Data("\(result)\n\(working)\n".utf8).write(to:
      sessions.appendingPathComponent("rollout-observer-\(sessionID).jsonl"))
    let observer = AgentActivityObserver(
      codexRoot: transcriptRoot.appendingPathComponent(".codex"),
      claudeRoot: transcriptRoot.appendingPathComponent(".claude"))

    _ = await fixture.model(agent: ControlledQueueAgent(), agentActivityObserver: observer)

    let context = try #require(try await store.load(ticketID: "ECC-101"))
    let agent = try #require(context.subtasks.first { $0.id == "observed-worker" })
    #expect(agent.status == .working)
    #expect(agent.completionUnread)
    #expect(agent.resultSummary == "Ready to review")
    #expect(agent.lastOutputAt == ISO8601DateFormatter().date(from: "2026-09-29T18:00:00Z"))
  }

  @Test("A prompt typed into a seen, completed agent returns it to work items")
  func promptReopensSeenCompletedAgent() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let sessionID = UUID().uuidString
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(
      id: "finished-worker", title: "Finished worker", provider: .codex, sessionID: sessionID))
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(id: "pending", title: "Pending"))
    let completedAt = try #require(ISO8601DateFormatter().date(from: "2026-09-29T18:00:00Z"))
    _ = try await store.updateProgress(ticketID: "ECC-101", subtaskID: "finished-worker",
      status: .completed, summary: "Ready", now: completedAt)
    let seen = try await store.acknowledgeCompletion(ticketID: "ECC-101", subtaskID: "finished-worker")
    #expect(seen.isCompletionSeen(try #require(seen.subtasks.first { $0.id == "finished-worker" })))
    let transcriptRoot = fixture.root.appendingPathComponent("activity")
    let sessions = transcriptRoot.appendingPathComponent(".codex/sessions/2026/09/29")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let prompt = #"{"timestamp":"2026-09-29T18:05:00Z","type":"event_msg","payload":{"type":"user_message","thread_id":"\#(sessionID)","message":"One more change"}}"#
    try Data("\(prompt)\n".utf8).write(to:
      sessions.appendingPathComponent("rollout-reopen-\(sessionID).jsonl"))
    let observer = AgentActivityObserver(
      codexRoot: transcriptRoot.appendingPathComponent(".codex"),
      claudeRoot: transcriptRoot.appendingPathComponent(".claude"))

    let model = await fixture.model(agent: ControlledQueueAgent(), agentActivityObserver: observer)

    let agent = try #require(model.subtasks(for: "ECC-101").first { $0.id == "finished-worker" })
    #expect(agent.status == .working)
    #expect(!model.isCompletionSeen(agent, ticketID: "ECC-101"))
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
    // The merged all-projects scope reloads each scoped dashboard on a change.
    #expect(repository.loads > baseline)
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

  @Test("Central QChat falls back to the project workspace when no repository is bound")
  func centralChatSkipsEmptyRepositoryPath() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let eccWorkspace = fixture.root.appendingPathComponent("ecc-workspace")
    let eccDashboard = eccWorkspace.appendingPathComponent("dashboard.json")
    try FileManager.default.createDirectory(at: eccWorkspace, withIntermediateDirectories: true)
    try JSONEncoder().encode(DashboardDocument(tickets: [])).write(to: eccDashboard)
    var config = try JSONDecoder().decode(AppConfiguration.self,
      from: Data(contentsOf: fixture.paths.configurationFile))
    let eccIndex = try #require(config.projects.firstIndex { $0.id == "ecc" })
    config.projects[eccIndex].dashboardPath = eccDashboard.path
    config.projects[eccIndex].workspacePath = eccWorkspace.path
    config.projects[eccIndex].repositoryPath = ""
    config.selectedProjectID = "ecc"
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(config)
    let agent = ControlledQueueAgent()
    let model = await fixture.model(agent: agent)

    #expect(model.selectedProjectID == "ecc")
    #expect(model.sendQueueAgentMessage("Summarize ECC work."))
    try await eventually { await agent.hasPendingReply }

    // An empty repositoryPath must never reach the harness as the working directory.
    #expect(await agent.sentWorkspaces == [eccWorkspace.path])
    await agent.reply("Done.")
    try await eventually { !model.isQueueAgentResponding }
  }

  @Test("Queue chat follows the configured default provider, model, and effort at send time")
  func queueChatFollowsProviderSettings() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let codexAgent = ControlledQueueAgent()
    let claudeAgent = ControlledQueueAgent()
    let model = await fixture.model(agent: codexAgent, queueAgentFactory: { provider in
      provider == .claude ? claudeAgent : codexAgent
    })

    model.setDefaultAgentProvider(.claude)
    // Agent-launch defaults no longer leak into QChat (FOC-075).
    model.setDefaultAgentModel("claude-opus-5-5", for: .claude)
    model.setChatModel("claude-haiku-5-5", for: .claude)
    model.setChatEffort("high", for: .claude)

    #expect(model.sendQueueAgentMessage("Why is ECC-102 second?"))
    try await eventually { await claudeAgent.hasPendingReply }

    #expect(await codexAgent.messages.isEmpty)
    #expect(await claudeAgent.messages.count == 1)
    #expect(await claudeAgent.sentModels.first == "claude-haiku-5-5")
    #expect(await claudeAgent.sentEfforts.first == "high")
    let firstMessage = try #require(await claudeAgent.messages.first)
    #expect(QueueAgentPrompt.userRequest(in: firstMessage) == "Why is ECC-102 second?")
    #expect(firstMessage.contains("Task snapshot"))
    #expect(firstMessage.contains("- ECC-102:"))
    #expect(!firstMessage.contains("Recent conversation"))
    let executable = try #require(await claudeAgent.sentExecutables.first)
    #expect(executable.hasSuffix("/.local/bin/focus-queue-claude"))

    await claudeAgent.reply("ECC-101 outranks ECC-102.")
    try await eventually { !model.isQueueAgentResponding }

    model.setDefaultAgentProvider(.codex)
    #expect(model.sendQueueAgentMessage("And now with Codex?"))
    try await eventually { await codexAgent.hasPendingReply }
    let followUp = try #require(await codexAgent.messages.first)
    #expect(followUp.contains("Recent conversation"))
    #expect(followUp.contains("agent: ECC-101 outranks ECC-102."))
    #expect(QueueAgentPrompt.userRequest(in: followUp) == "And now with Codex?")
    #expect(await codexAgent.sentExecutables.first == model.config.verifier.executable)
    await codexAgent.reply("Same order.")
    try await eventually { !model.isQueueAgentResponding }
  }

  @Test("Cancelling a queue chat stops without an error bubble")
  func queueChatCancellationIsSilent() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let agent = ControlledQueueAgent()
    let model = await fixture.model(agent: agent)
    let baseline = model.chatMessages(ticketID: nil).count

    #expect(model.sendQueueAgentMessage("Scan the queue for me."))
    try await eventually { await agent.hasPendingReply }

    model.cancelQueueAgentMessage()
    await agent.failPending()
    try await eventually { !model.isQueueAgentResponding }

    let messages = model.chatMessages(ticketID: nil)
    #expect(messages.count == baseline + 1)
    #expect(messages.last?.role == .user)
  }

  @Test("Clearing the queue chat erases the transcript and resets the provider session")
  func clearQueueChatResetsSession() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let agent = ControlledQueueAgent()
    let model = await fixture.model(agent: agent)

    #expect(model.sendQueueAgentMessage("Remember this exchange."))
    try await eventually { await agent.hasPendingReply }
    await agent.reply("Noted.")
    try await eventually { !model.isQueueAgentResponding }
    #expect(model.chatMessages(ticketID: nil).count > 1)

    model.clearQueueChat(ticketID: nil)
    try await eventually { await !agent.resetSessionNames.isEmpty }

    #expect(model.chatMessages(ticketID: nil).isEmpty)
    #expect(model.loadError == nil)
    let transcriptURL = fixture.paths.supportDirectory
      .appendingPathComponent("queue-conversation.json")
    let persisted = try JSONDecoder().decode(
      [QueueChatMessage].self, from: Data(contentsOf: transcriptURL))
    #expect(persisted.isEmpty)
  }

  @Test("Clearing a task chat resets its task-scoped harness session")
  func clearTaskChatResetsTaskSession() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let agent = ControlledQueueAgent()
    let model = await fixture.model(agent: agent)

    model.clearQueueChat(ticketID: "ECC-101")
    // One mock serves every provider here, so each provider's reset lands on it.
    try await eventually { await agent.resetSessionNames.count == AgentProvider.allCases.count }

    #expect(Set(await agent.resetSessionNames) == ["ecc-focus-queue-task-ecc-101"])
    #expect(model.chatMessages(ticketID: "ECC-101").isEmpty)
    #expect(model.loadError == nil)
  }

  @Test("Clearing chat resets every provider's session, not only the active one")
  func clearQueueChatResetsEveryProvider() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let agents = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0, ControlledQueueAgent()) })
    let model = await fixture.model(agent: agents[.codex]!, queueAgentFactory: { agents[$0]! })
    model.setDefaultAgentProvider(.kimi)

    model.clearQueueChat(ticketID: nil)
    for provider in AgentProvider.allCases {
      let agent = agents[provider]!
      try await eventually { await !agent.resetSessionNames.isEmpty }
      let executable = try #require(await agent.resetExecutables.first)
      #expect(executable == model.config.chatExecutable(for: provider))
    }
    #expect(model.loadError == nil)
  }

  @Test("Production Queue chat rows render a continuous formatted exchange headlessly")
  func queueChatTranscriptRenders() throws {
    let user = QueueChatMessage(role: .user, text: "Show the code change")
    let agent = QueueChatMessage(role: .agent,
      text: "**Done** with the update.\n\n```swift\nlet ready = true\n```")
    for scheme in [ColorScheme.light, .dark] {
      let view = VStack(spacing: 0) {
        QueueChatMessageRow(message: user, agentLabel: "QCHAT")
        QueueChatMessageRow(message: agent, agentLabel: "QCHAT")
      }
      .frame(width: 420, height: 480, alignment: .top)
      .background(QueueChatMessageRow.surface(for: .agent, colorScheme: scheme))
      .environment(\.colorScheme, scheme)
      let renderer = ImageRenderer(content: view)
      renderer.proposedSize = ProposedViewSize(width: 420, height: 480)
      let image = try #require(renderer.cgImage)
      #expect(image.width >= 420 && image.height >= 480)
      if let base = ProcessInfo.processInfo.environment["FOC_CHAT_SNAPSHOT"] {
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: base + (scheme == .light ? "-light.png" : "-dark.png")))
      }
    }
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
    // The all-projects scope is the default and merges every dashboard.
    #expect(model.showsAllProjects)
    #expect(model.projectScopeName == "All")
    #expect(Set(model.openTickets.map(\.id)) == ["ECC-101", "ECC-102", "APP-001", "APP-002"])
    #expect(await model.selectProject(id: "ecc"))
    #expect(!model.showsAllProjects)
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

  @Test("All scope merges every project dashboard and follows per-task projects")
  func allProjectsScope() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let appWorkspace = fixture.root.appendingPathComponent("app-project")
    let appDashboard = appWorkspace.appendingPathComponent("dashboard.json")
    try FileManager.default.createDirectory(at: appWorkspace, withIntermediateDirectories: true)
    let appTicket = DashboardTicket(
      id: "APP-001", title: "App task", projectID: "app", category: "App",
      status: "open", summary: "Lives in the App dashboard")
    try JSONEncoder().encode(DashboardDocument(tickets: [appTicket])).write(to: appDashboard)
    var config = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    config.projects.append(ProjectConfiguration(
      id: "app", name: "App", dashboardPath: appDashboard.path,
      workspacePath: appWorkspace.path))
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(config)
    let model = await fixture.model(agent: ControlledQueueAgent())

    #expect(model.showsAllProjects)
    #expect(model.projectScopeName == "All")
    #expect(Set(model.openTickets.map(\.id)) == ["ECC-101", "ECC-102", "APP-001"])
    #expect(model.project(for: appTicket)?.id == "app")
    #expect(model.dashboardPath(for: appTicket) == appDashboard.path)

    // A rename in the merged scope writes the owning dashboard and keeps the merge.
    #expect(await model.renameTask(appTicket, to: "Renamed app task"))
    #expect(model.dashboard.tickets.first { $0.id == "APP-001" }?.title == "Renamed app task")
    #expect(model.openTickets.map(\.id).contains("ECC-101"))

    // A single-project scope narrows the view; All restores the merge.
    #expect(await model.selectProject(id: "app"))
    #expect(!model.showsAllProjects)
    #expect(model.openTickets.map(\.id) == ["APP-001"])
    await model.selectAllProjects()
    #expect(model.showsAllProjects)
    #expect(Set(model.openTickets.map(\.id)) == ["ECC-101", "ECC-102", "APP-001"])

    let saved = try JSONDecoder().decode(
      DashboardDocument.self, from: Data(contentsOf: appDashboard))
    #expect(saved.tickets.first?.title == "Renamed app task")
  }

  @Test("The QChat hotkey expands the panel and opens QChat beside the queue")
  func qchatHotkeyFocusRequest() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())

    model.setPanelMode(.collapsed)
    model.requestQueueChatFocus()
    #expect(model.panelMode == .expanded)
    #expect(model.isQueueChatInspectorPresented)
    #expect(model.queueChatFocusRequest == 1)

    // A second press keeps the side chat open rather than toggling it closed.
    model.requestQueueChatFocus()
    #expect(model.isQueueChatInspectorPresented)
    #expect(model.queueChatFocusRequest == 2)
  }

  @Test("A Right Command + Shift tap opens the new task sheet and the next tap cancels it")
  func newTaskHotkeyTogglesSheet() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let monitor = NewTaskHotkeyMonitor()
    monitor.onTrigger = { model.toggleNewTaskRequest() }
    func send(_ type: NSEvent.EventType, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) {
      let characters = type == .keyDown ? "A" : ""
      monitor.handle(try! #require(NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode)))
    }
    func commandShiftTap(commandKeyUpArrives: Bool = true) {
      send(.flagsChanged, 54, [.command])
      send(.flagsChanged, 56, [.command, .shift])
      send(.flagsChanged, 56, [.command])
      if commandKeyUpArrives { send(.flagsChanged, 54, []) }
    }

    // The opening tap activates the app on its Shift release, and the Command
    // key-up that follows can go missing; the cancel tap must still work.
    commandShiftTap(commandKeyUpArrives: false)
    #expect(model.newTaskRequest?.autofocusPrompt == true)
    // Typing a capital letter in the prompt between taps must not block the cancel.
    send(.flagsChanged, 56, [.shift])
    send(.keyDown, 0, [.shift])
    send(.flagsChanged, 56, [])
    commandShiftTap()
    #expect(model.newTaskRequest == nil)

    // And the next open/cancel pair works from the healed state.
    commandShiftTap()
    #expect(model.newTaskRequest != nil)
    commandShiftTap()
    #expect(model.newTaskRequest == nil)
  }

  @Test("A QChat focus request puts the cursor in the composer, again after focus moves away")
  func qchatFocusRequestFocusesComposer() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    // Offscreen and never ordered front, so the test cannot take keyboard focus.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
      styleMask: [.titled], backing: .buffered, defer: true)
    func chat(_ request: Int) -> some View {
      QueueAgentChatView(model: model, draft: .constant(""), focusRequest: request)
        .frame(width: 480, height: 640)
    }
    let host = NSHostingView(rootView: AnyView(chat(1)))
    window.contentView = host
    func settle() async {
      for _ in 0..<10 {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    await settle()
    #expect(window.firstResponder is QueueChatComposerNSTextView)

    window.makeFirstResponder(nil)
    await settle()
    #expect(!(window.firstResponder is QueueChatComposerNSTextView))
    host.rootView = AnyView(chat(2))
    await settle()
    #expect(window.firstResponder is QueueChatComposerNSTextView)
  }

  @Test("An agent's canvas open expands the panel and requests its tab; other support dirs are ignored")
  func uiCanvasOpenRouting() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let ticket = try #require(model.openTickets.first)
    let mockup = fixture.root.appendingPathComponent("card.html")
    try Data("<!doctype html><body><p id=\"x\">Hi</p></body>".utf8).write(to: mockup)
    guard case .opened(let session) = try model.uiCanvasStore.open(
      file: mockup.path, taskID: ticket.id, title: "Card", viewport: nil, reopen: false, agentName: "Codex")
    else { Issue.record("open refused"); return }

    model.setPanelMode(.collapsed)
    model.handleUICanvasChange(ticketID: ticket.id, key: session.key, event: "open", root: "/tmp/another-clone")
    #expect(model.presentedPlanTicketID == nil)
    #expect(model.requestedUICanvas == nil)

    model.handleUICanvasChange(ticketID: ticket.id.lowercased(), key: session.key, event: "open", root: fixture.root.path)
    #expect(model.panelMode == .expanded)
    #expect(model.presentedPlanTicketID == ticket.id)
    #expect(model.requestedUICanvas?.key == session.key)
    #expect(model.visibleUICanvases(ticketID: ticket.id).map(\.key) == [session.key])

    model.dismissUICanvas(ticketID: ticket.id, key: session.key)
    #expect(model.visibleUICanvases(ticketID: ticket.id).isEmpty)
    model.handleUICanvasChange(ticketID: ticket.id, key: session.key, event: "change", root: nil)
    #expect(model.visibleUICanvases(ticketID: ticket.id).isEmpty, "Only a fresh open brings a closed tab back")
    let canvas = model.uiCanvasModel(ticketID: ticket.id, key: session.key)
    #expect(canvas === model.uiCanvasModel(ticketID: ticket.id, key: session.key))
    #expect(canvas.title == "Card")
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

  @Test("Priority changes persist to disk and update the in-memory dashboard")
  func setTaskPriority() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let ticket = try #require(model.openTickets.first)

    #expect(await model.setTaskPriority(ticket, to: "CRITICAL"))
    #expect(model.openTickets.first { $0.id == ticket.id }?.priority == "critical")
    #expect(model.actionMessages[ticket.id] == "Priority updated.")
    let saved = try JSONDecoder().decode(
      DashboardDocument.self,
      from: Data(contentsOf: URL(fileURLWithPath: model.config.dashboardPath)))
    #expect(saved.tickets.first { $0.id == ticket.id }?.priority == "critical")

    // Re-applying the current priority is a no-op that still succeeds.
    #expect(await model.setTaskPriority(ticket, to: "critical"))
    #expect(model.actionMessages[ticket.id] == "Priority updated.")
  }

  @Test("Status changes persist to disk and refuse closed statuses")
  func setTaskStatus() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let ticket = try #require(model.openTickets.first)

    #expect(await model.setTaskStatus(ticket, to: " QA "))
    #expect(model.openTickets.first { $0.id == ticket.id }?.status == "qa")
    #expect(model.actionMessages[ticket.id] == "Status updated.")
    let saved = try JSONDecoder().decode(
      DashboardDocument.self,
      from: Data(contentsOf: URL(fileURLWithPath: model.config.dashboardPath)))
    #expect(saved.tickets.first { $0.id == ticket.id }?.status == "qa")

    // Closing goes through completion review or archive, never the status menu.
    #expect(!(await model.setTaskStatus(ticket, to: "resolved")))
    #expect(model.openTickets.first { $0.id == ticket.id }?.status == "qa")
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

  @Test("Minimization hotkey toggles each preferred view back to the full queue")
  func minimizationHotkeyWorkflow() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    var dockMinimizations = 0
    var appliedModes: [QueuePanelMode] = []
    model.minimizeHandler = { dockMinimizations += 1 }
    model.panelModeHandler = { appliedModes.append($0) }

    for preference in [QueueMinimizationPreference.fq, .topTask, .dock] {
      model.setPanelMode(.expanded)
      model.minimize(using: preference)
      model.toggleMinimization(isMiniaturized: preference == .dock)
      #expect(model.panelMode == .expanded)
      let previousDockMinimizations = dockMinimizations
      model.toggleMinimization()
      switch preference {
      case .fq: #expect(model.panelMode == .collapsed)
      case .topTask: #expect(model.panelMode == .topTask)
      case .dock: #expect(dockMinimizations == previousDockMinimizations + 1)
      }
      model.toggleMinimization(isMiniaturized: preference == .dock)
      #expect(model.panelMode == .expanded)
      #expect(model.minimizationPreference == preference)
    }
    #expect(appliedModes.contains(.collapsed))
    #expect(appliedModes.contains(.topTask))
    #expect(appliedModes.last == .expanded)
  }

  @Test("Minimization shortcut settings persist, rebind, disable, and reset to Command comma")
  func minimizationHotkeySettings() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let defaults = UserDefaults.standard
    let keys = ["toggleMinimizationHotkeyEnabled", HotkeyAction.toggleMinimization.shortcutDefaultsKey]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
      }
    }
    for key in keys { defaults.removeObject(forKey: key) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.isHotkeyEnabled(.toggleMinimization))
    #expect(model.hotkeyShortcut(for: .toggleMinimization)?.displayString == "⌘,")
    let custom = HotkeyShortcut(keyCode: 40, modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "K")
    var configurationChanges = 0
    model.hotkeyConfigurationHandler = { configurationChanges += 1 }
    model.setHotkeyShortcut(custom, for: .toggleMinimization)
    model.setToggleMinimizationHotkeyEnabled(false)
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(!restarted.isHotkeyEnabled(.toggleMinimization))
    #expect(restarted.hotkeyShortcut(for: .toggleMinimization) == custom)
    model.setHotkeyShortcut(nil, for: .toggleMinimization)
    model.setToggleMinimizationHotkeyEnabled(true)
    #expect(model.hotkeyShortcut(for: .toggleMinimization) == HotkeyAction.toggleMinimization.defaultShortcut)
    #expect(configurationChanges == 4)
    #expect(defaults.data(forKey: HotkeyAction.toggleMinimization.shortcutDefaultsKey) == nil)
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

  @Test("Disabling automatic reports persists")
  func disabledAutomaticReports() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    var reportedEnabledValue: Bool?
    model.dailyReportsEnabledHandler = { reportedEnabledValue = $0 }

    model.setDailyReportsEnabled(false)
    #expect(!model.config.dailyReport.enabled)
    #expect(reportedEnabledValue == false)
    try await eventually {
      let saved = try JSONDecoder().decode(
        AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
      return !saved.dailyReport.enabled
    }
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(!restarted.config.dailyReport.enabled)
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
      root: fixture.root, projectID: ProjectCatalog.allProjectsScopeID)
    try external.move("ECC-101", to: .top, tickets: fixture.tickets, fallbackIDs: [])
    model.setPanelCollapsed(true)
    await model.refresh()
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
    #expect(!model.moveTicket("missing", to: .top))
    #expect(model.openTickets.first?.id == "ECC-101")
    model.resetQueueOrder()
    #expect(try external.load() == [])
  }

  @Test("Temporary moves preserve recency mode until the automatic baseline changes")
  func temporaryMoveTracksDisplayedRecencyOrder() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let third = DashboardTicket(
      id: "ECC-103", title: "Task ECC-103", status: "open",
      summary: "Most recently active task")
    let tickets = fixture.tickets + [third]
    try JSONEncoder().encode(DashboardDocument(tickets: tickets)).write(
      to: fixture.root.appendingPathComponent("dashboard.json"))
    let orderStore = QueueOrderStore(
      root: fixture.root, projectID: ProjectCatalog.allProjectsScopeID)
    try orderStore.setOrder(tickets.map(\.id), tickets: tickets, fallbackIDs: [])
    let contexts = TaskContextStore(root: fixture.root)
    _ = try await contexts.ensureContext(ticket: third)
    _ = try await contexts.recordPrompt(ticketID: third.id)

    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.queueActivitySortMode == .recentActivity)
    #expect(model.openTickets.map(\.id) == ["ECC-103", "ECC-101", "ECC-102"])

    #expect(model.moveTicket("ECC-101", to: .after("ECC-102")))
    #expect(model.queueActivitySortMode == .recentActivity)
    #expect(model.openTickets.map(\.id) == ["ECC-103", "ECC-102", "ECC-101"])
    let saved = try #require(try orderStore.loadOverride())
    #expect(saved.automaticBaselineIDs == ["ECC-103", "ECC-101", "ECC-102"])
    #expect(saved.orderedIDs == ["ECC-103", "ECC-102", "ECC-101"])

    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.openTickets.map(\.id) == ["ECC-103", "ECC-102", "ECC-101"])
    _ = try await contexts.ensureContext(ticket: fixture.tickets[1])
    _ = try await contexts.recordPrompt(
      ticketID: fixture.tickets[1].id, at: Date().addingTimeInterval(60))
    let changed = await fixture.model(agent: ControlledQueueAgent())
    #expect(changed.openTickets.map(\.id) == ["ECC-102", "ECC-103", "ECC-101"])
    #expect(try orderStore.loadOverride() == nil)
  }

  @Test("Moving up uses the task immediately above in the displayed recency order")
  func manualMoveUpUsesDisplayedRecencyOrder() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let third = DashboardTicket(
      id: "ECC-103", title: "Task ECC-103", status: "open",
      summary: "Most recently active task")
    let tickets = fixture.tickets + [third]
    try JSONEncoder().encode(DashboardDocument(tickets: tickets)).write(
      to: fixture.root.appendingPathComponent("dashboard.json"))
    let orderStore = QueueOrderStore(
      root: fixture.root, projectID: ProjectCatalog.allProjectsScopeID)
    try orderStore.setOrder(tickets.map(\.id), tickets: tickets, fallbackIDs: [])
    let contexts = TaskContextStore(root: fixture.root)
    _ = try await contexts.ensureContext(ticket: third)
    _ = try await contexts.recordPrompt(ticketID: third.id)

    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.openTickets.map(\.id) == ["ECC-103", "ECC-101", "ECC-102"])

    #expect(model.moveTicket("ECC-102", to: .before("ECC-101")))
    #expect(model.queueActivitySortMode == .recentActivity)
    #expect(model.openTickets.map(\.id) == ["ECC-103", "ECC-102", "ECC-101"])
    #expect(try orderStore.load() == ["ECC-103", "ECC-102", "ECC-101"])
  }

  @Test("Moving to bottom uses the displayed recency order as its baseline")
  func manualMoveToBottomUsesDisplayedRecencyOrder() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let third = DashboardTicket(
      id: "ECC-103", title: "Task ECC-103", status: "open",
      summary: "Most recently active task")
    let tickets = fixture.tickets + [third]
    try JSONEncoder().encode(DashboardDocument(tickets: tickets)).write(
      to: fixture.root.appendingPathComponent("dashboard.json"))
    let orderStore = QueueOrderStore(
      root: fixture.root, projectID: ProjectCatalog.allProjectsScopeID)
    try orderStore.setOrder(tickets.map(\.id), tickets: tickets, fallbackIDs: [])
    let contexts = TaskContextStore(root: fixture.root)
    _ = try await contexts.ensureContext(ticket: fixture.tickets[1])
    _ = try await contexts.recordPrompt(
      ticketID: fixture.tickets[1].id, at: Date().addingTimeInterval(-60))
    _ = try await contexts.ensureContext(ticket: third)
    _ = try await contexts.recordPrompt(ticketID: third.id)

    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.openTickets.map(\.id) == ["ECC-103", "ECC-102", "ECC-101"])

    #expect(model.moveTicket("ECC-102", to: .bottom))
    #expect(model.queueActivitySortMode == .recentActivity)
    #expect(model.openTickets.map(\.id) == ["ECC-103", "ECC-101", "ECC-102"])
    #expect(try orderStore.load() == ["ECC-103", "ECC-101", "ECC-102"])
  }

  @Test("Pinned tasks form a newest-first tier and unpin returns to recency")
  func pinningOverridesRecencyAcrossScopes() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let contexts = TaskContextStore(root: fixture.root)
    for ticket in fixture.tickets { _ = try await contexts.ensureContext(ticket: ticket) }
    _ = try await contexts.recordPrompt(ticketID: "ECC-101", at: Date())
    _ = try await contexts.setPinned(
      ticketID: "ECC-101", at: Date(timeIntervalSinceReferenceDate: 100))
    _ = try await contexts.setPinned(
      ticketID: "ECC-102", at: Date(timeIntervalSinceReferenceDate: 200))

    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.openTickets.map(\.id) == ["ECC-102", "ECC-101"])
    #expect(model.isTicketPinned("ECC-102"))
    let projectID = try #require(model.config.selectedProjectID)
    #expect(await model.selectProject(id: projectID))
    #expect(model.openTickets.map(\.id) == ["ECC-102", "ECC-101"])
    #expect(await model.setTicketPinned(fixture.tickets[1], pinned: false))
    #expect(!model.isTicketPinned("ECC-102"))
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
  }

  @Test("Temporary moves cannot displace the pinned tier or reorder pinned tasks")
  func temporaryMovesStayBelowPinnedTier() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let contexts = TaskContextStore(root: fixture.root)
    for ticket in fixture.tickets { _ = try await contexts.ensureContext(ticket: ticket) }
    _ = try await contexts.setPinned(
      ticketID: "ECC-101", at: Date(timeIntervalSinceReferenceDate: 200))

    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
    #expect(model.moveTicket("ECC-102", to: .top))
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
    #expect(model.moveTicket("ECC-101", to: .bottom))
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
  }

  @Test("Viewed tasks and activity sort preference survive restart")
  func viewedTasksAndSortPreference() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(!model.isNewTicket("ECC-101"))
    #expect(model.isNewTicket("FOC-NEW"))

    model.markTicketViewed("FOC-NEW")
    model.setQueueActivitySortMode(.recentOutput)
    #expect(!model.isNewTicket("FOC-NEW"))
    #expect(model.queueActivitySortMode == .recentOutput)
    try await eventually {
      try await JSONLocalStateStore(url: fixture.paths.stateFile).load().queueActivitySortMode == .recentOutput
    }

    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(!restarted.isNewTicket("FOC-NEW"))
    #expect(restarted.queueActivitySortMode == .recentOutput)
  }

  @Test("NEW seeds each dashboard once and migrates a baseline from one earlier scope")
  func viewedTasksSeedPerDashboard() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    // Earlier builds seeded only the scope open at the time, so this dashboard
    // has no viewed task and must not show its existing tasks as NEW.
    try await JSONLocalStateStore(url: fixture.paths.stateFile).save(
      LocalState(viewedTicketIDs: ["FOC-001"]))
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(!model.isNewTicket("ECC-101"))
    #expect(!model.isNewTicket("ECC-102"))
    let dashboardPath = URL(fileURLWithPath: model.config.dashboardPath).standardizedFileURL.path
    try await eventually {
      try await JSONLocalStateStore(url: fixture.paths.stateFile).load()
        .viewedTicketSources?.contains(dashboardPath) == true
    }

    let added = DashboardTicket(id: "ECC-103", title: "Added later", status: "open", summary: "New work")
    try JSONEncoder().encode(DashboardDocument(tickets: fixture.tickets + [added]))
      .write(to: URL(fileURLWithPath: model.config.dashboardPath), options: .atomic)
    await model.refresh(userInitiated: true)
    #expect(model.dashboard.tickets.contains { $0.id == "ECC-103" })
    #expect(model.isNewTicket("ECC-103"))
    #expect(!model.isNewTicket("ECC-101"))

    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.isNewTicket("ECC-103"))
    #expect(!restarted.isNewTicket("ECC-102"))
  }

  @Test("A migrated dashboard that already had viewed tasks keeps later tasks NEW")
  func viewedTasksMigrationPreservesUnviewed() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await JSONLocalStateStore(url: fixture.paths.stateFile).save(
      LocalState(viewedTicketIDs: ["ECC-101"]))
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(!model.isNewTicket("ECC-101"))
    #expect(model.isNewTicket("ECC-102"))
    model.markTicketViewed("ECC-102")
    #expect(!model.isNewTicket("ECC-102"))
  }

  @Test("Hard due dates update and clear through the view model")
  func hardDeadlineActions() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let dueDate = try #require(TaskTriagePolicy.date(from: "2026-10-24"))

    #expect(await model.setTaskHardDeadline(fixture.tickets[0], to: dueDate))
    var ticket = try #require(model.dashboard.tickets.first { $0.id == "ECC-101" })
    #expect(ticket.dueDate == "2026-10-24")
    #expect(ticket.dueDateSource == "User specified")

    #expect(await model.setTaskHardDeadline(ticket, to: nil))
    ticket = try #require(model.dashboard.tickets.first { $0.id == "ECC-101" })
    #expect(ticket.dueDate == nil)
    #expect(ticket.dueDateSource == nil)

    #expect(await model.createTask(
      title: "Dated new task", summary: "Verify hard due dates.", doneWhen: "",
      priority: "medium", dueDate: dueDate))
    let created = try #require(model.dashboard.tickets.first { $0.title == "Dated new task" })
    #expect(created.createdAt != nil)
    #expect(created.dueDate == "2026-10-24")
    #expect(created.dueDateSource == "User specified")
    #expect(model.isNewTicket(created.id))
  }

  @Test("Task details popover lays out dates, agents, and deadline controls")
  func taskDetailsPresentation() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    let dueDate = try #require(TaskTriagePolicy.date(from: "2026-10-24"))
    #expect(await model.setTaskHardDeadline(fixture.tickets[0], to: dueDate))
    let ticket = try #require(model.dashboard.tickets.first { $0.id == "ECC-101" })
    let host = NSHostingView(rootView: TaskDetailsView(ticket: ticket, model: model, onClose: {}))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize == CGSize(width: 400, height: 560))
  }

  @Test("A chat reply shows the agent's saved order even while a refresh is still running")
  func chatReorderIsVisibleDuringSlowRefresh() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let agent = ControlledQueueAgent()
    let dashboards = HeldDashboardRepository()
    let model = await fixture.model(agent: agent, dashboardRepository: dashboards)
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])

    #expect(model.sendQueueAgentMessage("Put ECC-102 first"))
    try await eventually { await agent.hasPendingReply }
    // The periodic refresh is still reading dashboards when the reply lands,
    // which made the reply's own refresh a no-op.
    await dashboards.hold()
    let slowRefresh = Task { await model.refresh(userInitiated: true) }
    try await eventually { await dashboards.heldLoads > 0 }
    // The agent saves through focus-queue-session, which writes this store.
    try QueueOrderStore(root: fixture.root, projectID: ProjectCatalog.allProjectsScopeID)
      .setOrder(["ECC-102"], tickets: fixture.tickets, fallbackIDs: [],
        currentIDs: ["ECC-101", "ECC-102"],
        automaticBaselineIDs: ["ECC-101", "ECC-102"], sortMode: .recentActivity)
    await agent.reply("ECC-102 is now first.")

    try await eventually { !model.isQueueAgentResponding }
    #expect(model.openTickets.map(\.id) == ["ECC-102", "ECC-101"])

    // The skipped refresh runs once the slow one finishes.
    let loadsBeforeRelease = await dashboards.completedLoads
    await dashboards.release()
    await slowRefresh.value
    try await eventually { await dashboards.completedLoads >= loadsBeforeRelease + 2 }
  }

  @Test("A queue change signal reloads the saved order without a full refresh")
  func queueOrderSignalReloadsOrder() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])

    try QueueOrderStore(root: fixture.root, projectID: ProjectCatalog.allProjectsScopeID)
      .move("ECC-102", to: .top, tickets: fixture.tickets, fallbackIDs: [],
        currentIDs: ["ECC-101", "ECC-102"],
        automaticBaselineIDs: ["ECC-101", "ECC-102"], sortMode: .recentActivity)
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
    model.reloadQueueOrder()
    #expect(model.openTickets.map(\.id) == ["ECC-102", "ECC-101"])

    // A missing order file restores priority order rather than keeping a stale one.
    try FileManager.default.removeItem(at: QueueOrderStore(
      root: fixture.root, projectID: ProjectCatalog.allProjectsScopeID).storageURL)
    model.reloadQueueOrder()
    #expect(model.savedQueueOrder == nil)
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
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
    // Launched without a prompt, the agent waits for input until its transcript shows one.
    #expect(assignment.status == .idle)
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
    #expect(subtask.status == .idle)
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
    try await eventually(maxAttempts: 1_000) { model.launchingTaskIDs.isEmpty }

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
    try await eventually(maxAttempts: 1_000) { model.launchingTaskIDs.isEmpty }

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
    let launchID = try #require(agent.launchConfiguration?.launchID, "App launches get a placement capsule")
    #expect(launchCommands.contains { $0.hasSuffix("tracking/placements/\(launchID).json") })
    #expect(model.taskCreatorLaunchDefaults == AgentLaunchPreset(
      provider: .claude, model: "sonnet", effort: "low",
      workspacePolicy: .isolatedCommittedSnapshot, useTmux: true),
      "A quick launch becomes the task creator's default")
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

  @Test("New Agent runs directly in a folder without a Git repository")
  func launchRunsInPlaceForPlainDirectory() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let plain = externalWorkspace(for: fixture.root, suffix: "plain")
    defer { try? FileManager.default.removeItem(at: plain) }
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    let launcher = DirectCreationRunner()
    let recorder = DirectViewRecorder(root: fixture.root, failReveal: false)
    let model = await fixture.model(agent: ControlledQueueAgent(), terminalController: recorder,
      taskAgentLauncher: TaskAgentLauncher(runner: launcher, candidateSockets: []))
    model.launchAgent(for: fixture.tickets[0], title: "Plain folder", provider: .codex,
      repositoryPath: plain.path, includePrompt: false, useTmux: false)
    try await eventually { model.launchingTaskIDs.isEmpty }
    // Git is suggested, not required: no worktree, no branch, same folder.
    #expect(await recorder.opened == true)
    #expect(await launcher.spawnCount == 1)
    let subtask = try #require(model.subtasks(for: "ECC-101").first)
    #expect(subtask.workspace?.path == plain.path)
    #expect(subtask.workspace?.repositoryPath == plain.path)
    #expect(subtask.workspace?.managed == false)
    #expect(subtask.workspace?.branch == nil)
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

  @Test("Token analytics occupies the side inspector and closes with the panel")
  func tokenAnalyticsSideInspector() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    var visibility: [Bool] = []
    model.reportVisibilityHandler = { visibility.append($0) }

    model.setTokenAnalyticsPresented(true)
    #expect(model.isTokenAnalyticsPresented)
    #expect(model.isInspectorPresented)
    #expect(visibility.last == true)

    model.setQueueChatInspectorPresented(true)
    #expect(!model.isTokenAnalyticsPresented)
    #expect(model.isQueueChatInspectorPresented)

    model.setTokenAnalyticsPresented(true)
    #expect(!model.isQueueChatInspectorPresented)
    model.setPanelCollapsed(true)
    #expect(!model.isTokenAnalyticsPresented)
    #expect(!model.isInspectorPresented)
    #expect(visibility.last == false)
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

  @Test("A seen report failure stays cleared while a newer report badges the header")
  func reportNotificationDismissal() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.setDailyReportRunState(isRunning: true, message: "Reading configured platforms")
    model.setDailyReportRunState(isRunning: false, message: "Mail reader timed out", isError: true)
    try await eventually { model.relevantFailedReportRun != nil }
    let notificationID = model.reportNotificationID
    #expect(model.dailyReportHeaderIndicator == .needsAttention)

    model.dismissReportNotification()
    #expect(model.dailyReportHeaderIndicator == .none)
    try await eventually {
      try await JSONLocalStateStore(url: fixture.paths.stateFile).load()
        .dismissedNotificationIDs.contains(notificationID)
    }
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.dailyReportHeaderIndicator == .none)

    let newer = fixture.report(
      "newer-report",
      finishedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
    )
    try fixture.archive(newer)
    try JSONEncoder().encode(newer).write(to: fixture.paths.latestDailyReportFile)
    await restarted.reloadDailyReport()
    #expect(restarted.dailyReportHeaderIndicator != .none)
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

  @Test("The real connector checker reports all six platforms on a new install and finds override credentials")
  func connectorDiagnosticsRunTheShippedChecker() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let script = fixture.paths.connectorDiagnosticsScript
    try FileManager.default.createDirectory(
      at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Scripts/focus_queue_connectors.py")
    try FileManager.default.copyItem(at: source, to: script)
    let model = await fixture.model(agent: ControlledQueueAgent())

    await model.diagnoseConnectors()

    #expect(model.connectorDiagnosticsError == nil)
    let fresh = try #require(model.connectorDiagnostics)
    #expect(fresh.configurationPresent == false)
    #expect(Set(fresh.connectors.map(\.id)) == Set(DailyReportPlatform.allCases.map(\.rawValue)))
    for platform in DailyReportPlatform.allCases {
      #expect(fresh.diagnostic(for: platform)?.statusLabel == "Setup required")
    }

    // Credentials beside an overridden support folder's ingestion.json count.
    try Data("{}".utf8).write(to: fixture.paths.ingestionConfigurationFile)
    try Data(#"{"slackToken":"xoxb-fixture"}"#.utf8).write(
      to: fixture.paths.supportDirectory.appendingPathComponent("credentials.json"))
    await model.diagnoseConnectors()

    let configured = try #require(model.connectorDiagnostics)
    #expect(configured.configurationPresent == true)
    #expect(configured.diagnostic(for: .slack)?.statusLabel == "Configured, not verified")
    #expect(configured.diagnostic(for: .discord)?.statusLabel == "Setup required")
  }

  @Test("The starter ingestion.json leaves each source on its own setup step, and is never rewritten")
  func starterIngestionConfiguration() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let script = fixture.paths.connectorDiagnosticsScript
    try FileManager.default.createDirectory(
      at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Scripts/focus_queue_connectors.py")
    try FileManager.default.copyItem(at: source, to: script)
    let model = await fixture.model(agent: ControlledQueueAgent())

    #expect(model.createStarterIngestionConfiguration())
    await model.diagnoseConnectors()

    #expect(model.connectorDiagnosticsError == nil)
    let snapshot = try #require(model.connectorDiagnostics)
    #expect(snapshot.configurationPresent == true)
    for platform in DailyReportPlatform.allCases {
      let diagnostic = try #require(snapshot.diagnostic(for: platform))
      #expect(diagnostic.statusLabel == "Setup required", "\(platform) should still need setup")
      #expect(!diagnostic.nextStep.isEmpty)
    }
    let url = fixture.paths.ingestionConfigurationFile
    let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(saved["dashboardPath"] as? String == model.config.dashboardPath)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    try Data(#"{"discordGuildId":"123"}"#.utf8).write(to: url)
    #expect(!model.createStarterIngestionConfiguration())
    #expect(try String(contentsOf: url, encoding: .utf8) == #"{"discordGuildId":"123"}"#)
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

  @Test("Marking a completed task incomplete returns it to Focus and resets its checkbox")
  func markCompletedTaskIncomplete() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let completed = DashboardTicket(
      id: "ECC-101", title: "Task ECC-101", status: "resolved",
      summary: "Implement and verify ECC-101", updatedAt: "2026-10-18T14:00:00Z",
      completedAt: "2026-10-18T14:00:00Z",
      completion: DashboardCompletion(
        outcome: "completed", reason: "Verified", evidence: ["test.log"],
        completedBy: "completion-review"))
    try JSONEncoder().encode(DashboardDocument(tickets: [completed, fixture.tickets[1]]))
      .write(to: fixture.root.appendingPathComponent("dashboard.json"))
    let contexts = TaskContextStore(root: fixture.paths.supportDirectory)
    _ = try await contexts.ensureContext(ticket: fixture.tickets[0])
    _ = try await contexts.setPinned(ticketID: completed.id, at: Date())
    let model = await fixture.model(agent: ControlledQueueAgent())
    let displayed = try #require(model.completedTickets.first { $0.id == completed.id })

    let reopened = await model.markTaskIncomplete(displayed)

    #expect(reopened)
    let focused = try #require(model.openTickets.first { $0.id == completed.id })
    #expect(focused.status == "open")
    #expect(focused.completedAt == nil)
    #expect(focused.completion == nil)
    #expect(!model.completedTickets.contains { $0.id == completed.id })
    #expect(focused.isOpen)
    let object = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: fixture.root.appendingPathComponent("dashboard.json")))
        as? [String: Any])
    let saved = try #require((object["tickets"] as? [[String: Any]])?.first {
      $0["id"] as? String == completed.id
    })
    let history = try #require(saved["completionHistory"] as? [[String: Any]])
    #expect(history.count == 1)
    #expect(try await contexts.load(ticketID: completed.id)?.pinnedAt == nil)
  }

  @Test("A completed task whose cleanup needs attention stays in Completed, and old completions are not swept")
  func completedTaskWithCleanupProblemStaysVisible() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let tickets = fixture.tickets.map {
      DashboardTicket(id: $0.id, title: $0.title, status: "resolved", summary: $0.summary,
        updatedAt: "2026-10-18T14:00:00Z", completedAt: "2026-10-18T14:00:00Z")
    }
    try JSONEncoder().encode(DashboardDocument(tickets: tickets))
      .write(to: fixture.root.appendingPathComponent("dashboard.json"))
    let store = TaskContextStore(root: fixture.root)
    for ticket in tickets { _ = try await store.ensureContext(ticket: ticket) }
    var report = TaskCleanupReport(ticketID: "ECC-101", dryRun: false, finishedAt: Date())
    report.problems = ["Worktree /tmp/example: identity changed"]
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(report).write(to: fixture.root
      .appendingPathComponent("tasks/ECC-101/\(TaskCompletionCleanup.reportName)"))

    let model = await fixture.model(agent: ControlledQueueAgent())
    await model.refresh()

    try await eventually { model.closureMessages["ECC-101"] != nil }
    #expect(model.closureMessages["ECC-101"]?.contains("Needs attention") == true)
    #expect(model.completedTickets.map(\.id).contains("ECC-101"))
    #expect(!model.openTickets.map(\.id).contains("ECC-101"))
    #expect(model.completedTickets.map(\.id).contains("ECC-102"))
    // ECC-102 completed days ago: only the reviewed CLI sweep may clean it.
    #expect(TaskCompletionCleanup.savedReport(ticketID: "ECC-102", root: fixture.root) == nil)
  }

  @Test("Archiving an open task does not record successful completion")
  func archiveTaskWithoutCompletion() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let contexts = TaskContextStore(root: fixture.paths.supportDirectory)
    _ = try await contexts.ensureContext(ticket: fixture.tickets[0])
    _ = try await contexts.setPinned(ticketID: fixture.tickets[0].id, at: Date())
    let model = await fixture.model(agent: ControlledQueueAgent())

    let archived = await model.archiveWithoutCompletion(fixture.tickets[0])

    #expect(archived)
    let ticket = try #require(model.dashboard.tickets.first { $0.id == "ECC-101" })
    #expect(ticket.status == "cancelled")
    #expect(ticket.completion == nil)
    #expect(ticket.completedAt == nil)
    #expect(!model.openTickets.contains { $0.id == ticket.id })
    #expect(model.completedTickets.contains { $0.id == ticket.id })
    #expect(try await contexts.load(ticketID: ticket.id)?.pinnedAt == nil)
  }

  @Test("Marking a task complete closes its open work items and resolves it as the user")
  func markTaskCompleteClosesWorkItems() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.paths.supportDirectory)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    _ = try await store.upsertSubtask(ticketID: "ECC-101",
      subtask: TaskSubtask(id: "unfinished", title: "Unfinished work", status: .working))
    let model = await fixture.model(agent: ControlledQueueAgent())

    model.requestCompletion(for: fixture.tickets[0])
    try await eventually {
      model.dashboard.tickets.first(where: { $0.id == "ECC-101" })?.isCompleted == true
    }

    let completed = try #require(model.dashboard.tickets.first { $0.id == "ECC-101" })
    #expect(completed.completion?.completedBy == "user")
    #expect(model.subtasks(for: "ECC-101").first?.status == .completed)
    #expect(model.subtasks(for: "ECC-101").first?.completionOverrideAt != nil)
  }

  @Test("Awaited completion reports whether the task left the queue so the card can restore itself")
  func awaitedCompletionReportsOutcome() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())

    #expect(await model.completeTicket(fixture.tickets[0]))
    #expect(!model.openTickets.contains { $0.id == "ECC-101" })

    let completed = try #require(model.dashboard.tickets.first { $0.id == "ECC-101" })
    #expect(!(await model.completeTicket(completed)))
    let missing = DashboardTicket(id: "ECC-404", title: "Missing", status: "open", summary: "Gone")
    #expect(!(await model.completeTicket(missing)))
    #expect(model.actionMessages["ECC-404"]?.hasPrefix("Could not mark complete") == true)
  }

  @Test("Restart keeps a completed task with unfinished subtasks in Completed with its records")
  func completedTaskWithOpenSubtasksStaysCompleted() async throws {
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
      // Completion is final; it no longer bounces back into the queue.
      #expect(!restarted.openTickets.map(\.id).contains("ECC-101"))
      #expect(restarted.completedTickets.map(\.id).contains("ECC-101"))
      #expect(restarted.subtasks(for: "ECC-101").first?.status == .working)
      #expect(restarted.taskContexts["ECC-999"] == nil)
      #expect(restarted.completedTickets.map(\.id).contains("ECC-999"))
    }
    #expect(try await store.load(ticketID: "ECC-999") == nil)
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

  @Test("The header report button spins while a report runs and badges it until it is opened")
  func dailyReportHeaderIndicator() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.dailyReportHeaderIndicator == .none)

    model.setDailyReportRunState(isRunning: true, message: "Reading platforms")
    #expect(model.dailyReportHeaderIndicator == .running)

    let finished = fixture.report("finished-report", finishedAt: "2026-10-15T15:00:00Z")
    try fixture.archive(finished)
    model.setDailyReportRunState(isRunning: false, message: "Report finished", reportID: finished.runID)
    await model.reloadDailyReport()
    try await eventually { model.dailyReportHeaderIndicator == .ready }

    model.openDailyReportFromHeader()
    #expect(model.isDailyReportPresented)
    #expect(model.dailyReport?.runID == finished.runID)
    try await eventually { model.dailyReportHeaderIndicator == .none }
    model.openDailyReportFromHeader()
    #expect(!model.isDailyReportPresented)

    var partial = fixture.report("partial-report", finishedAt: "2026-10-15T16:00:00Z")
    partial = DailyReportDocument(runID: partial.runID, trigger: .manual, mode: .unseenOnly,
      startedAt: partial.startedAt, finishedAt: partial.finishedAt, status: .partial,
      summary: "Could not read Discord", tokenBudget: 1000, usage: nil, platforms: [],
      errors: ["discord: Missing Access"])
    try fixture.archive(partial)
    await model.reloadDailyReport()
    try await eventually { model.dailyReportHeaderIndicator == .needsAttention }
    model.openDailyReportFromHeader()
    try await eventually { model.dailyReportHeaderIndicator == .none }
    model.openDailyReportFromHeader()

    model.setDailyReportRunState(isRunning: true, message: "Reading platforms")
    model.setDailyReportRunState(isRunning: false, message: "Worker failed", isError: true)
    try await eventually { model.reportHistory.runs.first?.phase == .failed }
    #expect(model.dailyReportHeaderIndicator == .needsAttention)
    model.openDailyReportFromHeader()
    #expect(model.isDailyReportPresented)
    #expect(model.dailyReportHeaderIndicator == .none)
  }

  @Test("An agent update opens its own inspector and closes on collapse")
  func agentUpdateNavigation() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.openPlan(for: fixture.tickets[0])
    try await eventually { !model.presentedPlanMarkdown.isEmpty }
    let update = QueueAgentUpdate(id: "subtask-ECC-101-implementation", ticketID: "ECC-101",
      title: "Implementation · New result", summary: "Finished the implementation")
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

  @Test("Override completes only the selected subtask and keeps its agent and parent task open")
  func manualOverride() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let subtask = TaskSubtask(id: "accidental", title: "Undone assignment", status: .blocked)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    let model = await fixture.model(agent: ControlledQueueAgent())
    model.overrideCompletion(subtask, for: fixture.tickets[0])
    try await eventually { model.subtasks(for: "ECC-101").first?.status == .completed }
    #expect(model.subtasks(for: "ECC-101").first?.agentRemovedAt == nil)
    #expect(model.visibleAgents(for: "ECC-101").isEmpty)
    #expect(model.dashboard.tickets[0].isOpen)
    try await Task.sleep(for: .milliseconds(2100))
    await model.refresh()
    #expect(model.dashboard.tickets[0].isOpen)
  }

  @Test("Completed agents are never archived while blank agents never drive parent completion")
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
    #expect(model.subtasks(for: "ECC-101").first?.agentRemovedAt == nil)
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

  @Test("A launch-keyed placeholder folds into the agent row its placement names")
  func placeholderMergesIntoCapsuleAgentRow() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let agentID = "63B453D1-F943-4ADE-A8BE-998AE089D2F2"
    let launchID = UUID().uuidString.lowercased()
    var real = TaskSubtask(id: agentID, title: "Integrate and install arrow fix",
      assignmentDescription: "Real work", provider: .codex, status: .working,
      includeInitializationPrompt: false)
    real.tracksCompletion = true
    real.lastHeartbeatAt = Date()
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: real)
    var placeholder = TaskSubtask(id: launchID, title: "Codex agent",
      assignmentDescription: "Tracked launch", provider: .codex, status: .working,
      includeInitializationPrompt: false)
    placeholder.tracksCompletion = false
    placeholder.lastHeartbeatAt = Date()
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: placeholder)
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.visibleAgents(for: "ECC-101").count == 2)
    let intake = try JSONDecoder().decode(AgentIntakeReceipt.self,
      from: JSONSerialization.data(withJSONObject: [
        "launchID": launchID, "taskID": "ECC-101", "agentID": agentID,
        "cwd": fixture.root.path, "phase": "ready", "title": "Codex agent",
      ]))

    try await model.importProvisionalAgentIntakes([intake])

    let context = try #require(try await store.load(ticketID: "ECC-101"))
    #expect(context.subtasks.count == 2)
    let merged = try #require(context.subtasks.first { $0.id == launchID })
    #expect(merged.mergedIntoSubtaskID == agentID)
    #expect(merged.agentRemovedAt != nil)
    #expect(context.hasDismissedLaunch(launchID))
    #expect(model.visibleAgents(for: "ECC-101").map(\.id) == [agentID])
    // A repeated import can neither revive the placeholder nor disturb the row.
    try await model.importProvisionalAgentIntakes([intake])
    let again = try #require(try await store.load(ticketID: "ECC-101"))
    #expect(again.subtasks.count == 2)
    #expect(again.subtasks.first { $0.id == launchID }?.agentRemovedAt != nil)
    #expect(again.subtasks.first { $0.id == agentID }?.status == .working)
  }

  @Test("A placeholder created before its agent row merges when the row arrives")
  func placeholderCreatedBeforeAgentRowMergesLater() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let agentID = "B41E285C-F638-4484-BA07-91FD720185AD"
    let launchID = UUID().uuidString.lowercased()
    let model = await fixture.model(agent: ControlledQueueAgent())
    let intake = try JSONDecoder().decode(AgentIntakeReceipt.self,
      from: JSONSerialization.data(withJSONObject: [
        "launchID": launchID, "taskID": "ECC-101", "agentID": agentID,
        "cwd": fixture.root.path, "phase": "ready", "title": "Codex agent",
      ]))

    try await model.importProvisionalAgentIntakes([intake])
    #expect(model.visibleAgents(for: "ECC-101").map(\.id) == [launchID])

    // The launch's real agent row arrives after the placeholder was shown.
    var real = TaskSubtask(id: agentID, title: "Remove duplicate agent arrow",
      assignmentDescription: "Real work", provider: .codex, status: .working,
      includeInitializationPrompt: false)
    real.tracksCompletion = true
    real.lastHeartbeatAt = Date()
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: real)
    try await model.importProvisionalAgentIntakes([intake])

    let context = try #require(try await store.load(ticketID: "ECC-101"))
    #expect(context.subtasks.count == 2)
    #expect(model.visibleAgents(for: "ECC-101").map(\.id) == [agentID])
    let merged = try #require(context.subtasks.first { $0.id == launchID })
    #expect(merged.mergedIntoSubtaskID == agentID)
    #expect(merged.agentRemovedAt != nil)
    // Completion of the real row leaves no phantom working placeholder behind.
    _ = try await store.updateProgress(ticketID: "ECC-101", subtaskID: agentID,
      status: .completed, summary: "done")
    try await model.importProvisionalAgentIntakes([intake])
    let finished = try #require(try await store.load(ticketID: "ECC-101"))
    #expect(finished.subtasks.count == 2)
    #expect(finished.subtasks.first { $0.id == launchID }?.agentRemovedAt != nil)
    #expect(finished.subtasks.first { $0.id == agentID }?.status == .completed)
    #expect(finished.subtasks.filter { $0.hasAgent && $0.isAgentVisible }.isEmpty)
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

  @Test("Archiving an app-launched Codex agent does not resurrect it from its launch receipt")
  func archivedAppLaunchStaysArchived() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.root)
    _ = try await store.ensureContext(ticket: fixture.tickets[0])
    let model = await fixture.model(agent: ControlledQueueAgent())
    let agentID = UUID().uuidString
    let launchID = UUID().uuidString.lowercased()
    var agent = TaskSubtask(id: agentID, title: "Codex agent", provider: .codex)
    agent.launchConfiguration = AgentLaunchConfiguration(launchID: launchID)
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: agent)
    let receipt = try JSONDecoder().decode(AgentIntakeReceipt.self,
      from: JSONSerialization.data(withJSONObject: [
        "launchID": launchID, "taskID": "ECC-101", "agentID": agentID,
        "cwd": fixture.root.path, "phase": "ready", "title": "Codex agent",
        "workspacePolicy": "assigned",
      ]))
    try await model.importProvisionalAgentIntakes([receipt])
    let launched = try #require(model.visibleAgents(for: "ECC-101").first { $0.id == agentID })
    #expect(model.visibleAgents(for: "ECC-101").count == 1)

    model.removeAgent(launched, from: fixture.tickets[0])
    try await eventually { model.visibleAgents(for: "ECC-101").isEmpty }
    try await model.importProvisionalAgentIntakes([receipt])
    #expect(model.visibleAgents(for: "ECC-101").isEmpty)
    let saved = try #require(try await store.load(ticketID: "ECC-101"))
    #expect(!saved.subtasks.contains { $0.id == launchID })
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

  @Test("New document readers use lightweight defaults instead of the full task-chat model")
  func documentReaderDefaults() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.defaultAgentProvider = .claude
    configuration.chatModels = [.claude: "opus"]
    configuration.chatEfforts = [.claude: "high"]
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let model = await fixture.model(agent: ControlledQueueAgent())
    let context = try #require(model.taskContexts["ECC-101"])
    let chat = try #require(model.documentConversation(for: URL(fileURLWithPath: context.planPath), ticketID: context.ticketID))
    #expect(chat.route.kind == .ephemeralReader)
    #expect(chat.route.provider == .claude && chat.route.model == "haiku" && chat.route.effort == "low")
    chat.setNewAgentProvider(.codex)
    #expect(chat.route.model == "gpt-6-luna" && chat.route.effort == "low")
    #expect(model.config.chatModel(for: .claude) == "opus")
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
    let model = await fixture.model(agent: ControlledQueueAgent())

    #expect(model.defaultAgentProvider == .claude)
    #expect(model.taskCreatorLaunchDefaults.provider == .claude,
      "With no launch yet, the task creator follows the Settings default")
  }

  @Test("The configured default provider and model drive quick actions and the task creator")
  func configuredDefaultProviderAndModel() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var configuration = try JSONDecoder().decode(
      AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
    configuration.projects[0].repositoryPath = fixture.root.path
    configuration.tmuxExecutable = "/usr/bin/true"
    configuration.defaultAgentProvider = .kimi
    configuration.defaultAgentModels = [.kimi: "kimi-code/k3"]
    try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
    let model = await fixture.model(agent: ControlledQueueAgent())

    #expect(model.defaultAgentProvider == .kimi)
    #expect(model.defaultAgentModel(for: .kimi) == "kimi-code/k3")
    #expect(model.defaultAgentModel(for: .codex) == nil)
    #expect(model.preferredNewAgentProvider(stored: nil) == .kimi)
    #expect(model.preferredNewAgentProvider(stored: .claude) == .claude)
    #expect(model.agentModelChoices(for: .kimi).map(\.label).first == "Default")

    #expect(model.taskCreatorLaunchDefaults == AgentLaunchPreset(
      provider: .kimi, model: "kimi-code/k3", effort: nil,
      workspacePolicy: .isolatedCommittedSnapshot, useTmux: true, includePrompt: true))

    model.setDefaultAgentProvider(.claude)
    #expect(model.defaultAgentProvider == .claude)
    model.setDefaultAgentModel("sonnet", for: .claude)
    #expect(model.defaultAgentModel(for: .claude) == "sonnet")
    model.setDefaultAgentModel("", for: .claude)
    #expect(model.defaultAgentModel(for: .claude) == nil)
    try await eventually {
      let saved = try JSONDecoder().decode(
        AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
      return saved.defaultAgentProvider == .claude
        && saved.defaultAgentModels == [.kimi: "kimi-code/k3"]
    }
  }

  @Test("Placement settings default per provider, persist edits, and clamp their ranges")
  func placementSettings() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())

    #expect(model.placementModelEnabled)
    #expect(model.placementConfidenceThreshold == 0.85)
    #expect(model.placementTimeoutSeconds == 20)
    #expect(model.placementModelChoices(for: .codex).contains { $0.model == "gpt-6-luna" })
    #expect(model.placementModelChoices(for: .claude).allSatisfy { $0.model?.isEmpty == false },
      "The provider-default entry is the picker's own Default row")

    model.setPlacementModelEnabled(false)
    model.setPlacementProvider(.claude)
    model.setPlacementModel("claude-haiku-4-5", for: .claude)
    model.setPlacementModel("custom-luna", for: .codex)
    model.setPlacementEffort("medium", for: .codex)
    model.setPlacementConfidenceThreshold(0.99)
    model.setPlacementTimeoutSeconds(2)
    #expect(model.placementModelChoices(for: .codex).contains { $0.label == "custom-luna" })
    #expect(model.placementConfidenceThreshold == 0.95)
    #expect(model.placementTimeoutSeconds == 5)
    model.setPlacementModel(" ", for: .claude)
    #expect(model.config.placementModels[.claude] == nil)

    try await eventually {
      let saved = try JSONDecoder().decode(
        AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
      return saved.placementModelEnabled == false && saved.placementProvider == .claude
        && saved.placementModels == [.codex: "custom-luna"]
        && saved.placementEfforts == [.codex: "medium"]
        && saved.placementConfidenceThreshold == 0.95 && saved.placementTimeoutSeconds == 5
    }
  }

  @Test("Agent settings for pane capacity, prompt data, and escalation launches persist where their readers look")
  func agentBehaviorSettings() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())

    #expect(model.agentsPerWindow == TmuxPaneLayout.defaultMaximumPanes)
    #expect(!model.dataPlacementEnabled)
    #expect(model.config.agentEscalationAutoLaunch)

    model.setAgentsPerWindow(40)
    #expect(model.agentsPerWindow == 12)
    model.setDataPlacementEnabled(true)
    model.setAgentEscalationAutoLaunch(false)
    try await eventually {
      TmuxPaneLayout.maximumPanes(supportDirectory: fixture.paths.supportDirectory) == 12
    }

    // Returning to the default must overwrite the saved value, not drop the key.
    model.setAgentsPerWindow(4)
    try await eventually {
      let saved = try JSONDecoder().decode(
        AppConfiguration.self, from: Data(contentsOf: fixture.paths.configurationFile))
      return TmuxPaneLayout.maximumPanes(supportDirectory: fixture.paths.supportDirectory) == 4
        && saved.dataPlacementEnabled == true && saved.agentEscalationAutoLaunch == false
    }
  }

  @Test("Recallable sessions list saved, non-running agents across open tasks, newest first")
  func recallableSessions() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = TaskContextStore(root: fixture.paths.supportDirectory)
    for ticket in fixture.tickets { _ = try await store.ensureContext(ticket: ticket) }
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(
      id: "older", title: "Older agent", sessionID: "11111111-1111-1111-1111-111111111111",
      status: .idle, lastHeartbeatAt: Date().addingTimeInterval(-3_600), runtimeMode: .terminal))
    _ = try await store.upsertSubtask(ticketID: "ECC-102", subtask: TaskSubtask(
      id: "newer", title: "Newer agent", provider: .claude, sessionID: "22222222-2222-2222-2222-222222222222",
      status: .completed, lastHeartbeatAt: Date().addingTimeInterval(-60), runtimeMode: .terminal))
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: TaskSubtask(
      id: "unsaved", title: "Never started", status: .queued))
    var assignment = TaskSubtask(id: "assignment", title: "Assignment only",
      sessionID: "33333333-3333-3333-3333-333333333333")
    assignment.isAssignmentOnly = true
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: assignment)
    let model = await fixture.model(agent: ControlledQueueAgent())
    await model.refresh()

    let recallable = model.recallableAgents()
    #expect(recallable.map(\.agent.id) == ["newer", "older"])
    #expect(recallable.map(\.ticket.id) == ["ECC-102", "ECC-101"])
  }

  @Test("Recorded hotkey shortcuts persist per action and reset to the default gesture")
  func hotkeyShortcutPersistence() async throws {
    let fixture = try await Fixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.root)
      for action in HotkeyAction.allCases { UserDefaults.standard.removeObject(forKey: action.shortcutDefaultsKey) }
    }
    let model = await fixture.model(agent: ControlledQueueAgent())
    var applied = 0
    model.hotkeyConfigurationHandler = { applied += 1 }
    let combo = HotkeyShortcut(keyCode: 45, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyLabel: "N")

    model.setHotkeyShortcut(combo, for: .newTask)
    #expect(model.hotkeyShortcut(for: .newTask) == combo)
    #expect(model.hotkeyShortcut(for: .qchat) == nil)
    let saved = try #require(UserDefaults.standard.data(forKey: HotkeyAction.newTask.shortcutDefaultsKey))
    #expect(try JSONDecoder().decode(HotkeyShortcut.self, from: saved) == combo)
    model.isRecordingHotkey = true
    model.isRecordingHotkey = false
    model.setHotkeyShortcut(nil, for: .newTask)
    #expect(model.hotkeyShortcut(for: .newTask) == nil)
    #expect(UserDefaults.standard.data(forKey: HotkeyAction.newTask.shortcutDefaultsKey) == nil)
    #expect(applied == 4, "Set, record start, record stop, and reset each re-apply hotkeys")
  }

  @Test("The task creator fills blanks from placement, keeps the description, and launches one placed agent")
  func taskCreatorCreatesAndLaunches() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = try await creatorRepository(for: fixture)
    defer { try? FileManager.default.removeItem(at: repository) }
    let suggester = RecordingPlacementSuggester(TaskPlacementSuggestion(
      status: "new-task", title: "Export reports to Obsidian",
      summary: "Send the daily report to Obsidian each evening.", priority: "high",
      confidence: 0, model: "claude/haiku"))
    let model = await fixture.model(
      agent: ControlledQueueAgent(),
      terminalController: DirectViewRecorder(root: fixture.root, failReveal: false),
      taskAgentLauncher: TaskAgentLauncher(runner: DirectCreationRunner(), candidateSockets: []),
      taskPlacementSuggester: suggester)
    let description = "Every evening, export the daily report as markdown into my Obsidian vault."
    let preset = AgentLaunchOptions.preset(
      selecting: .claude,
      from: AgentLaunchPreset(provider: .codex, workspacePolicy: .existingCheckout,
        useTmux: false, includePrompt: true),
      lastLaunch: AgentLaunchPreset(
        provider: .claude, model: "haiku", effort: "low", pluginOverrides: ["ecc@ecc": true]))

    let result = await model.submitTaskDraft(TaskDraft(description: description, agent: preset))
    guard case .created(let ticketID, true) = result else {
      Issue.record("Unexpected result \(result)")
      return
    }
    let ticket = try #require(model.projectTickets.first { $0.id == ticketID })
    #expect(ticket.title == "Export reports to Obsidian")
    #expect(ticket.summary == "Send the daily report to Obsidian each evening.")
    #expect(ticket.priority == "high")
    #expect(ticket.next == description, "The full description survives a shorter card summary")
    let queries = await suggester.queries
    #expect(queries == [TaskPlacementQuery(
      description: description, provider: .claude, cwd: repository.path,
      timeoutSeconds: AppConfiguration.defaultPlacementTimeoutSeconds)])

    try await eventually { model.launchingTaskIDs.isEmpty }
    let agent = try #require(model.subtasks(for: ticketID).first)
    #expect(agent.provider == .claude)
    #expect(agent.initialPrompt == description)
    #expect(agent.launchConfiguration?.model == "haiku")
    #expect(agent.launchConfiguration?.effort == "low")
    #expect(agent.launchConfiguration?.pluginOverrides == ["ecc@ecc": true])
    let launchID = try #require(agent.launchConfiguration?.launchID)
    let capsule = try #require(try AgentPlacementCapsuleStore(root: fixture.paths.supportDirectory)
      .load(launchID: launchID))
    #expect(capsule.status == .placed)
    #expect(capsule.taskID == ticketID)
    #expect(capsule.assignmentID == agent.id)
    #expect(model.taskCreatorLaunchDefaults == preset, "The creator remembers its own launch")
    #expect(model.lastAgentLaunch(for: .claude) == preset)
    #expect(model.lastAgentLaunch(for: .kimi).model == model.defaultAgentModel(for: .kimi),
      "A provider never launched falls back to its Settings defaults")
    model.rememberAgentLaunch(AgentLaunchPreset(provider: .kimi, model: "kimi-code/k3", effort: "high"))
    #expect(model.lastAgentLaunch(for: .claude) == preset, "Another provider's launch keeps this one")
    #expect(model.lastAgentLaunch(for: .kimi).effort == "high")
  }

  @Test("A placement match is offered before a duplicate; joining launches there and creating anyway reuses the suggestion")
  func taskCreatorOffersMatch() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = try await creatorRepository(for: fixture)
    defer { try? FileManager.default.removeItem(at: repository) }
    let suggester = RecordingPlacementSuggester(TaskPlacementSuggestion(
      status: "task", taskID: "ECC-101", title: "Implement ECC-101 follow-up",
      summary: "Follow up.", priority: "low", confidence: 0.93, model: "claude/haiku"))
    let model = await fixture.model(
      agent: ControlledQueueAgent(),
      terminalController: DirectViewRecorder(root: fixture.root, failReveal: false),
      taskAgentLauncher: TaskAgentLauncher(runner: DirectCreationRunner(), candidateSockets: []),
      taskPlacementSuggester: suggester)
    var draft = TaskDraft(
      description: "Keep going on ECC-101 and verify the edge cases.", priority: "medium",
      agent: AgentLaunchPreset(provider: .codex, workspacePolicy: .existingCheckout, useTmux: false))
    let ticketCount = model.projectTickets.count

    let offered = await model.submitTaskDraft(draft)
    guard case .matched(let match, let suggestion) = offered else {
      Issue.record("Unexpected result \(offered)")
      return
    }
    #expect(match.id == "ECC-101")
    #expect(model.projectTickets.count == ticketCount, "Nothing is created while the match is pending")

    let joined = await model.submitTaskDraft(draft, choice: .join("ECC-101"), suggestion: suggestion)
    #expect(joined == .joined(ticketID: "ECC-101", launchedAgent: true))
    try await eventually { model.launchingTaskIDs.isEmpty }
    #expect(model.subtasks(for: "ECC-101").contains { $0.initialPrompt == draft.description })
    #expect(model.projectTickets.count == ticketCount)

    draft.launchesAgent = false
    let created = await model.submitTaskDraft(draft, choice: .createNew, suggestion: suggestion)
    guard case .created(let newID, false) = created else {
      Issue.record("Unexpected result \(created)")
      return
    }
    #expect(newID != "ECC-101")
    #expect(model.projectTickets.first { $0.id == newID }?.priority == "medium", "The user's priority wins")
    #expect(model.subtasks(for: newID).isEmpty)
    #expect(await suggester.queries.count == 1, "Creating anyway reuses the first suggestion")
  }

  @Test("Without a prompted agent the creator always creates a task and saves the prompt for the first agent")
  func taskCreatorWithoutAgentSavesPrompt() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = try await creatorRepository(for: fixture)
    defer { try? FileManager.default.removeItem(at: repository) }
    // The model names an open task; without a launch to redirect, it must not stop creation.
    let suggester = RecordingPlacementSuggester(TaskPlacementSuggestion(
      status: "task", taskID: "ECC-101", title: "Plan the export",
      summary: "Plan the Obsidian export.", priority: "low", confidence: 0.97, model: "claude/haiku"))
    let model = await fixture.model(
      agent: ControlledQueueAgent(),
      terminalController: DirectViewRecorder(root: fixture.root, failReveal: false),
      taskAgentLauncher: TaskAgentLauncher(runner: DirectCreationRunner(), candidateSockets: []),
      taskPlacementSuggester: suggester)
    let unprompted = AgentLaunchPreset(provider: .claude, workspacePolicy: .existingCheckout,
      useTmux: false, includePrompt: false)
    let drafts = [
      TaskDraft(description: "  Plan the Obsidian export.\nKeep it markdown.  ", agent: unprompted),
      TaskDraft(description: "Sketch the export settings pane.", launchesAgent: false,
        agent: AgentLaunchPreset(provider: .claude)),
    ]
    let ticketCount = model.projectTickets.count

    for draft in drafts {
      let result = await model.submitTaskDraft(draft)
      guard case .created(let ticketID, false) = result else {
        Issue.record("Unexpected result \(result)")
        continue
      }
      #expect(ticketID != "ECC-101")
      let ticket = try #require(model.projectTickets.first { $0.id == ticketID })
      #expect(ticket.title == "Plan the export")
      #expect(model.subtasks(for: ticketID).isEmpty, "No agent starts")
      let prompt = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(model.savedInitialPrompt(for: ticket) == prompt)
      let loaded = try await TaskContextStore(root: fixture.paths.supportDirectory).load(ticketID: ticketID)
      let context = try #require(loaded)
      let plan = try String(contentsOf: URL(fileURLWithPath: context.planPath), encoding: .utf8)
      #expect(plan.contains("- [Task data](data.md): durable task facts and test data.\n- [Initial prompt](initial-prompt.md)"))
    }
    #expect(model.projectTickets.count == ticketCount + 2)
    #expect(model.subtasks(for: "ECC-101").isEmpty, "The matched task gains no agent")

    let ticket = try #require(model.projectTickets.first { $0.summary == "Plan the Obsidian export." })
    let saved = try #require(model.savedInitialPrompt(for: ticket))
    model.launchPromptedAgent(for: ticket, prompt: saved,
      preset: AgentLaunchPreset(provider: .claude, workspacePolicy: .existingCheckout, useTmux: false))
    try await eventually { model.launchingTaskIDs.isEmpty }
    #expect(model.subtasks(for: ticket.id).first?.initialPrompt == saved)
    #expect(model.savedInitialPrompt(for: ticket) == nil, "Only the first agent is offered the saved prompt")
  }

  @Test("The card's New Agent sheet adds a prompted agent to its task without placement")
  func cardAgentSheetLaunchesPromptedAgent() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = try await creatorRepository(for: fixture)
    defer { try? FileManager.default.removeItem(at: repository) }
    let suggester = RecordingPlacementSuggester(.unavailable("not used"))
    let model = await fixture.model(
      agent: ControlledQueueAgent(),
      terminalController: DirectViewRecorder(root: fixture.root, failReveal: false),
      taskAgentLauncher: TaskAgentLauncher(runner: DirectCreationRunner(), candidateSockets: []),
      taskPlacementSuggester: suggester)
    let ticket = try #require(model.projectTickets.first { $0.id == "ECC-101" })
    let preset = AgentLaunchOptions.preset(
      selecting: .kimi,
      from: AgentLaunchPreset(provider: .codex, workspacePolicy: .existingCheckout,
        useTmux: false, includePrompt: true),
      lastLaunch: AgentLaunchPreset(provider: .kimi, model: "kimi-code/k3", effort: "high"))
    let ticketCount = model.projectTickets.count

    model.launchPromptedAgent(for: ticket, prompt: "  Audit the card spacing.\nThen report.  ", preset: preset)
    try await eventually { model.launchingTaskIDs.isEmpty }
    model.launchPromptedAgent(for: ticket, prompt: "Port the drawer", title: "Context drawer", preset: preset)
    try await eventually { model.launchingTaskIDs.isEmpty }
    model.launchPromptedAgent(for: ticket, prompt: "   ", preset: preset)

    let agents = model.subtasks(for: "ECC-101")
    let derived = try #require(agents.first { $0.initialPrompt == "Audit the card spacing.\nThen report." })
    #expect(derived.title == TaskSubtask.agentName(prompt: "Audit the card spacing.", provider: .kimi))
    #expect(derived.provider == .kimi)
    #expect(derived.launchConfiguration?.model == "kimi-code/k3")
    #expect(derived.launchConfiguration?.effort == "high")
    #expect(agents.contains { $0.title == "Context drawer" && $0.initialPrompt == "Port the drawer" })
    #expect(agents.count == 2, "A blank prompt launches nothing")
    #expect(model.projectTickets.count == ticketCount, "The sheet never creates a task")
    #expect(await suggester.queries.isEmpty, "The task is already known, so placement is skipped")
    #expect(model.taskCreatorLaunchDefaults == preset)
  }

  @Test("Without a model suggestion the creator defaults the priority to medium")
  func taskCreatorDefaultsPriorityWithoutModel() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let suggester = RecordingPlacementSuggester(.unavailable("the claude CLI is not on PATH"))
    let model = await fixture.model(agent: ControlledQueueAgent(), taskPlacementSuggester: suggester)
    let description = "Add a keyboard shortcut that jumps to the next blocked agent."
    let draft = TaskDraft(description: description, launchesAgent: false,
      agent: AgentLaunchPreset(provider: .claude))

    let created = await model.submitTaskDraft(draft)
    guard case .created(let ticketID, false) = created else {
      Issue.record("Unexpected result \(created)")
      return
    }
    let ticket = try #require(model.projectTickets.first { $0.id == ticketID })
    #expect(ticket.title == TaskSubtask.agentName(prompt: description, provider: .claude))
    #expect(ticket.summary == description)
    #expect(ticket.priority == "medium")
    #expect(await suggester.queries.count == 1)

    model.setPlacementModelEnabled(false)
    let offline = await model.submitTaskDraft(TaskDraft(
      description: "Write the release notes for 2.3.", priority: "low", launchesAgent: false,
      agent: AgentLaunchPreset(provider: .claude)))
    guard case .created = offline else {
      Issue.record("Unexpected result \(offline)")
      return
    }
    #expect(await suggester.queries.count == 1, "Placement off in Settings never calls the model")
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
    #expect(QueueViewModel.escalationProvider(requested: "bogus", fallbackOrder: [.codex, .claude],
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
    let terminal = ManagedResumeRecorder()
    let model = await fixture.model(agent: ControlledQueueAgent(),
      terminalController: terminal,
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
    // Unattended escalations run in tmux without opening a terminal window,
    // so a report that escalates several tasks never takes focus.
    #expect(await terminal.opened.isEmpty)
    #expect(model.subtasks(for: "ECC-101").first?.tmux != nil)
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

  @Test("The program log mirror skips registration status noise and stays quiet after a clear")
  func programLogMirrorFilterAndClearPersistence() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = ProgramLogStore()
    let model = await fixture.model(agent: ControlledQueueAgent(), programLog: store)

    let registrationStatus =
      "Codex is running and registered in tmux. Click Build thing to open its exact terminal session."
    let recoveryError =
      "The provider process is running and registered in tmux session ecc-focus-queue-task-ecc-101, but WezTerm did not open its view. Click the subtask to retry."
    #expect(QueueViewModel.programLogSkips(registrationStatus))
    #expect(!QueueViewModel.programLogSkips(recoveryError))

    store.clear()
    model.recordProgramLogChange(registrationStatus, level: .info, category: "Task ECC-101")
    #expect(store.entries.isEmpty)

    model.recordProgramLogChange(recoveryError, level: .error, category: "Task ECC-101")
    #expect(store.entries.map(\.message) == [recoveryError])

    store.clear()
    model.recordProgramLogChange(recoveryError, level: .error, category: "Task ECC-101")
    #expect(store.entries.isEmpty)

    model.recordProgramLogChange(
      "WezTerm opened the recovered session view.", level: .info, category: "Task ECC-101")
    #expect(store.entries.map(\.message) == ["WezTerm opened the recovered session view."])
  }

  private func eventually(
    maxAttempts: Int = 200,
    _ condition: @MainActor () async throws -> Bool
  ) async throws {
    for _ in 0..<maxAttempts {
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

  func resolveTicket(
    id: String, reason: String, evidence: [String], completedBy: String,
    in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.resolveTicket(id: id, reason: reason, evidence: evidence,
      completedBy: completedBy, in: url, expectedRevision: expectedRevision)
  }

  func reopenTicket(
    id: String, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.reopenTicket(id: id, in: url, expectedRevision: expectedRevision)
  }

  func setTicketPriority(
    id: String, to priority: String, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.setTicketPriority(id: id, to: priority, in: url, expectedRevision: expectedRevision)
  }

  func setTicketStatus(
    id: String, to status: String, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.setTicketStatus(id: id, to: status, in: url, expectedRevision: expectedRevision)
  }
  func setTicketDueDate(
    id: String, to dueDate: String?, source: String?, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.setTicketDueDate(
      id: id, to: dueDate, source: source, in: url, expectedRevision: expectedRevision)
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

/// A committed Git repository configured as the fixture project's checkout.
@MainActor
private func creatorRepository(for fixture: Fixture) async throws -> URL {
  let repository = externalWorkspace(for: fixture.root, suffix: "creator-repo")
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
  try await JSONConfigurationRepository(url: fixture.paths.configurationFile).save(configuration)
  return repository
}

/// Returns one fixed suggestion and records every query.
private actor RecordingPlacementSuggester: TaskPlacementSuggesting {
  private let suggestion: TaskPlacementSuggestion
  private(set) var queries: [TaskPlacementQuery] = []

  init(_ suggestion: TaskPlacementSuggestion) { self.suggestion = suggestion }

  func suggest(_ query: TaskPlacementQuery) async -> TaskPlacementSuggestion {
    queries.append(query)
    return suggestion
  }
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
    // Scheduled reports default to off; these fixtures model a user who opted in.
    config.dailyReport.enabled = true
    try await JSONConfigurationRepository(url: paths.configurationFile).save(config)
  }

  func model(agent: ControlledQueueAgent, programLog: ProgramLogStore = ProgramLogStore(),
             terminalController: (any WezTermControlling)? = nil,
             dashboardRepository: any DashboardManaging = JSONDashboardRepository(),
             taskAgentLauncher: TaskAgentLauncher = TaskAgentLauncher(),
             taskPlacementSuggester: (any TaskPlacementSuggesting)? = nil,
             connectorDiagnosticsRunner: any ProcessRunning = FoundationProcessRunner(),
             agentActivityObserver: AgentActivityObserver = AgentActivityObserver(),
             discoverExternalAgents: @escaping @Sendable () async throws -> [KnownProviderProcess] = { [] },
             labelTmuxPane: @escaping @Sendable (TmuxSessionReference, String) async -> Void = { _, _ in },
             identifyManagedAgent: (@Sendable (TaskSubtask, WezTermConfiguration) async throws -> String?)? = nil,
             providerExecutableAvailable: (@Sendable (AgentProvider) -> Bool)? = nil,
             queueAgentFactory: (@Sendable (AgentProvider) -> any QueueAgentChatting)? = nil,
             locateExistingAgent: @escaping @Sendable (AgentProvider, String) async throws -> KnownProviderProcess? = { _, _ in nil }) async -> QueueViewModel {
    let boundary = ForbiddenExternalActions()
    let model = QueueViewModel(paths: paths, programLog: programLog,
      dashboardRepository: dashboardRepository,
      terminalController: terminalController ?? boundary,
      queueAgent: agent,
      // Every provider must reach the mock: a real harness would reset the
      // user's live chat sessions and delete their transcripts.
      queueAgentFactory: queueAgentFactory ?? { _ in agent },
      pullRequestQueueLoader: boundary,
      taskAgentLauncher: taskAgentLauncher,
      taskPlacementSuggester: taskPlacementSuggester,
      connectorDiagnosticsRunner: connectorDiagnosticsRunner,
      agentActivityObserver: agentActivityObserver,
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

/// Suspends dashboard reads while held, standing in for a slow periodic refresh.
private actor HeldDashboardRepository: DashboardManaging {
  private let base = JSONDashboardRepository()
  private var holding = false
  private var held: [CheckedContinuation<Void, Never>] = []
  private(set) var completedLoads = 0
  var heldLoads: Int { held.count }

  func hold() { holding = true }
  func release() {
    holding = false
    let waiting = held
    held.removeAll()
    for continuation in waiting { continuation.resume() }
  }

  func load(from url: URL) async throws -> DashboardDocument {
    if holding { await withCheckedContinuation { held.append($0) } }
    defer { completedLoads += 1 }
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
  func resolveTicket(
    id: String, reason: String, evidence: [String], completedBy: String,
    in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.resolveTicket(id: id, reason: reason, evidence: evidence,
      completedBy: completedBy, in: url, expectedRevision: expectedRevision)
  }

  func reopenTicket(
    id: String, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.reopenTicket(id: id, in: url, expectedRevision: expectedRevision)
  }
  func setTicketPriority(
    id: String, to priority: String, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.setTicketPriority(id: id, to: priority, in: url, expectedRevision: expectedRevision)
  }
  func setTicketStatus(
    id: String, to status: String, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.setTicketStatus(id: id, to: status, in: url, expectedRevision: expectedRevision)
  }
  func setTicketDueDate(
    id: String, to dueDate: String?, source: String?, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.setTicketDueDate(
      id: id, to: dueDate, source: source, in: url, expectedRevision: expectedRevision)
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
  func resolveTicket(
    id: String, reason: String, evidence: [String], completedBy: String,
    in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.resolveTicket(id: id, reason: reason, evidence: evidence,
      completedBy: completedBy, in: url, expectedRevision: expectedRevision)
  }

  func reopenTicket(
    id: String, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.reopenTicket(id: id, in: url, expectedRevision: expectedRevision)
  }
  func setTicketPriority(
    id: String, to priority: String, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.setTicketPriority(id: id, to: priority, in: url, expectedRevision: expectedRevision)
  }
  func setTicketStatus(
    id: String, to status: String, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.setTicketStatus(id: id, to: status, in: url, expectedRevision: expectedRevision)
  }
  func setTicketDueDate(
    id: String, to dueDate: String?, source: String?, in url: URL, expectedRevision: DashboardRevision
  ) async throws -> DashboardSnapshot {
    try await base.setTicketDueDate(
      id: id, to: dueDate, source: source, in: url, expectedRevision: expectedRevision)
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
  private(set) var sentModels: [String?] = []
  private(set) var sentEfforts: [String?] = []
  private(set) var sentExecutables: [String] = []
  private(set) var sentWorkspaces: [String] = []
  private(set) var resetSessionNames: [String] = []
  private(set) var resetExecutables: [String] = []
  private var pending: CheckedContinuation<QueueAgentReply, any Error>?
  var hasPendingReply: Bool { pending != nil }

  func send(message: String, dashboardPath: String, workspace: String, visibleOrder: [String],
    deferredTicketIDs: [String], configuration: VerifierConfiguration,
    model: String?, effort: String?) async throws -> QueueAgentReply {
    messages.append(message)
    projectScopes.append(configuration.projectScopeID)
    sentModels.append(model)
    sentEfforts.append(effort)
    sentExecutables.append(configuration.executable)
    sentWorkspaces.append(workspace)
    return try await withCheckedThrowingContinuation { pending = $0 }
  }

  func reset(configuration: VerifierConfiguration) async throws {
    resetSessionNames.append(configuration.sessionName)
    resetExecutables.append(configuration.executable)
  }

  func reply(_ message: String) {
    pending?.resume(returning: QueueAgentReply(message: message, log: "headless test"))
    pending = nil
  }

  func failPending(_ error: any Error = CancellationError()) {
    pending?.resume(throwing: error)
    pending = nil
  }
}

private struct ForbiddenExternalActions: WezTermControlling, PullRequestQueueLoading {
  private func forbidden<T>() throws -> T {
    Issue.record("State integration test attempted an external action")
    throw TestFailure.unexpectedExternalAction
  }
  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { try forbidden() }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { try forbidden() }
  func attach(paneID: Int, tabTitle: String, windowTitle: String, configuration: WezTermConfiguration) async throws { let _: Void = try forbidden() }
  func focusOrSpawn(directory: String, taskID: String, taskTitle: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult { try forbidden() }
  func focusOrResume(session: TaskAgentSession, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult { try forbidden() }
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
