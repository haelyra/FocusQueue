import Foundation
import Observation
import Testing
import FocusQueueCore
import Darwin

@testable import ECCFocusQueue

@Suite("Queue app state integration")
@MainActor
struct QueueViewModelTests {
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
    let external = QueueOrderStore(root: fixture.root)
    try external.move("ECC-101", to: .top, tickets: fixture.tickets, fallbackIDs: [])
    model.setPanelCollapsed(true)
    await model.refresh()
    #expect(model.openTickets.map(\.id) == ["ECC-101", "ECC-102"])
    #expect(!model.moveTicket("missing", to: .top))
    #expect(model.openTickets.first?.id == "ECC-101")
    model.resetQueueOrder()
    #expect(try external.load() == [])
  }

  @Test("Subtasks can exist without agents and retain their own explanation")
  func standaloneSubtaskCreation() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model(agent: ControlledQueueAgent())

    model.createSubtask(
      for: fixture.tickets[0], title: "Review the session list",
      explanation: "Clarify which agents are active before assigning one.")

    try await eventually { model.focusSubtasks(for: "ECC-101").count == 1 }
    let subtask = try #require(model.focusSubtasks(for: "ECC-101").first)
    #expect(subtask.isAssignmentOnly)
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

  @Test("New subtask agents and additional agents preserve independent assignments and workspaces")
  func nestedAgentLaunch() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.root.appendingPathComponent("repo")
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
      initialPrompt: "Do the requested work", subtaskID: "first-agent", createAssignment: true)
    try await eventually { model.launchingTaskIDs.isEmpty }
    let assignment = try #require(model.focusSubtasks(for: "ECC-101").first)
    #expect(assignment.isAssignmentOnly)
    #expect(assignment.tracksCompletion)
    #expect(assignment.status == .working)
    #expect(assignment.workspace?.path == repository.path)
    #expect(model.agents(for: assignment, ticketID: "ECC-101").map(\.id) == ["first-agent"])
    model.launchAgent(for: fixture.tickets[0], title: "Second worker", provider: .claude,
      repositoryPath: repository.path, includePrompt: false, useTmux: false, createWorktree: false,
      subtaskID: "second-agent", parentSubtaskID: assignment.id)
    try await eventually { model.launchingTaskIDs.isEmpty }
    #expect(model.focusSubtasks(for: "ECC-101").count == 1)
    #expect(model.agents(for: assignment, ticketID: "ECC-101").count == 2)
    let first = try #require(model.subtasks(for: "ECC-101").first { $0.id == "first-agent" })
    model.removeAgent(first, from: fixture.tickets[0])
    try await eventually { model.subtasks(for: "ECC-101").first { $0.id == first.id }?.agentRemovedAt != nil }
    #expect(model.focusSubtasks(for: "ECC-101").count == 1)
    #expect(model.agents(for: assignment, ticketID: "ECC-101").map(\.id) == ["second-agent"])
  }

  @Test("Direct launch persists its pane before revealing it and keeps it on reveal failure", arguments: [false, true])
  func directLaunchRevealsSavedPane(failReveal: Bool) async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.root.appendingPathComponent("repo")
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
    #expect(message.contains(failReveal ? "Click the subtask to retry" : "Preparing task context"))
    model.openLaunchDiagnostics(for: subtask)
    #expect(model.launchDiagnostics?.text.contains(failReveal ? "view-failed" : "\"phase\":\"ready\"") == true)
  }

  @Test("A failed New Agent launch returns its error and retries its saved workspace and assignment")
  func launchRetryPreservesAssignment() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.root.appendingPathComponent("repo")
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
      repositoryPath: fixture.root.appendingPathComponent("missing").path) { started in
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
      lastHeartbeatAt: Date().addingTimeInterval(-298))
    _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: subtask)
    let model = await fixture.model(agent: ControlledQueueAgent())
    #expect(model.effectiveStatus(for: subtask) == .working)
    let activity = ObservationCounter()
    let contexts = ObservationCounter()
    withObservationTracking { _ = model.effectiveStatus(for: subtask) } onChange: { activity.record() }
    withObservationTracking { _ = model.taskContexts } onChange: { contexts.record() }
    try await Task.sleep(for: .milliseconds(3100))
    await model.refresh()
    #expect(model.effectiveStatus(for: subtask) == .idle)
    #expect(activity.count == 1)
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
    let model = await fixture.model(agent: ControlledQueueAgent(), terminalController: terminal)
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
    let model = await fixture.model(agent: ControlledQueueAgent(), terminalController: terminal)
    let first = try #require(model.subtasks(for: "ECC-101").first)
    let second = try #require(model.subtasks(for: "ECC-102").first)

    model.openSubtask(first, for: fixture.tickets[0])
    try await eventually { model.isOpening(first, ticketID: "ECC-101") }

    #expect(!model.isOpening(second, ticketID: "ECC-102"))
    await terminal.release()
    try await eventually { !model.isOpening(first, ticketID: "ECC-101") }
  }

  @Test("Removing one agent leaves other task agents intact")
  func removeAgentFromOneTask() async throws {
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

    model.removeAgent(first, from: fixture.tickets[0])
    try await eventually { model.visibleAgents(for: "ECC-101").isEmpty }

    #expect(model.agentSessions(for: "ECC-101").isEmpty)
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
    let repository = fixture.root.appendingPathComponent("repo")
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

  private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.conditionTimedOut
  }
}

private enum TestFailure: Error { case unexpectedExternalAction, conditionTimedOut }

private final class ObservationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func record() { lock.withLock { value += 1 } }
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

  func model(agent: ControlledQueueAgent, verifier: (any CompletionVerifying)? = nil,
             terminalController: (any WezTermControlling)? = nil,
             taskAgentLauncher: TaskAgentLauncher = TaskAgentLauncher(),
             connectorDiagnosticsRunner: any ProcessRunning = FoundationProcessRunner(),
             locateExistingAgent: @escaping @Sendable (AgentProvider, String) async throws -> KnownProviderProcess? = { _, _ in nil }) async -> QueueViewModel {
    let boundary = ForbiddenExternalActions()
    let model = QueueViewModel(paths: paths, terminalController: terminalController ?? boundary,
      verifier: verifier ?? boundary, queueAgent: agent, pullRequestQueueLoader: boundary,
      taskAgentLauncher: taskAgentLauncher,
      connectorDiagnosticsRunner: connectorDiagnosticsRunner, discoverExternalAgents: { [] },
      maintenanceEnabled: false,
      locateExistingAgent: locateExistingAgent)
    await model.bootstrap()
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
    provider: AgentProvider, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    let context = try await TaskContextStore(root: root).load(ticketID: taskID)
    let saved = context?.subtasks.first { $0.terminalPaneID == paneID && $0.provider == provider }
    #expect(saved?.terminalPaneID == paneID)
    #expect(saved?.runtimeMode == .terminal)
    opened = true
    if failReveal { throw WezTermError.actionFailed("Fixture window failure") }
    return .focused(paneID: paneID)
  }
  func focusOrSpawn(directory: String, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
}

private actor ControlledQueueAgent: QueueAgentChatting {
  private(set) var messages: [String] = []
  private var pending: CheckedContinuation<QueueAgentReply, any Error>?
  var hasPendingReply: Bool { pending != nil }

  func send(message: String, dashboardPath: String, workspace: String, visibleOrder: [String],
    deferredTicketIDs: [String], configuration: VerifierConfiguration) async throws -> QueueAgentReply {
    messages.append(message)
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
  func focusOrSpawn(directory: String, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult { try forbidden() }
  func focusOrResume(session: TaskAgentSession, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult { try forbidden() }
  func verify(ticketID: String, requestFile: URL, workspace: String, configuration: VerifierConfiguration) async throws -> VerificationRunResult { try forbidden() }
  func load(repository: String, closedSince: String) async throws -> PullRequestQueueSnapshot { try forbidden() }
}

private actor RecallRecorder: WezTermControlling {
  private(set) var sessions: [TaskAgentSession] = []
  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { [] }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { [] }
  func attach(paneID: Int, tabTitle: String, windowTitle: String, configuration: WezTermConfiguration) async throws {}
  func focusOrSpawn(directory: String, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
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
  func focusOrSpawn(directory: String, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
  func focusOrResume(session: TaskAgentSession, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    throw TestFailure.unexpectedExternalAction
  }
  func openDirectRuntime(paneID: Int, socketPath: String?, taskID: String, provider: AgentProvider,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult {
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
    configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    while !released { try await Task.sleep(for: .milliseconds(10)) }
    if fails { throw WezTermError.actionFailed("Fixture session failure") }
    return .focused(paneID: 42)
  }

  func release() { released = true }

  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { [] }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { [] }
  func attach(paneID: Int, tabTitle: String, windowTitle: String,
    configuration: WezTermConfiguration) async throws {}
  func focusOrSpawn(directory: String, taskID: String,
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
