import Foundation
import Observation
import Testing
import FocusQueueCore

@testable import ECCFocusQueue

@Suite("Queue app state integration")
@MainActor
struct QueueViewModelTests {
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
      repositoryPath: repository.path, includePrompt: false, useTmux: false)
    try await eventually { model.launchingTaskIDs.isEmpty }
    #expect(await recorder.opened == true)
    #expect(await launcherRunner.spawnCount == 1)
    let subtask = try #require(model.subtasks(for: "ECC-101").first)
    #expect(subtask.terminalPaneID == 42)
    #expect(subtask.runtimeMode == .terminal)
    #expect(subtask.status == .working)
    let message = try #require(model.actionMessages["ECC-101"])
    #expect(message.contains(failReveal ? "Click the subtask to retry" : "Ready for your instructions"))
    model.openLaunchDiagnostics(for: subtask)
    #expect(model.launchDiagnostics?.text.contains(failReveal ? "view-failed" : "\"phase\":\"ready\"") == true)
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
    model.sendQueueAgentMessage("Change the queue")
    #expect(!model.isQueueAgentResponding)
    #expect(await agent.messages.isEmpty)
    model.setDailyReportRunState(isRunning: false, message: "Mail reader timed out", isError: true)
    try await eventually { model.reportHistory.runs.first?.phase == .failed }
    #expect(model.reportHistory.runs.count == 1)
    #expect(model.reportNeedsAttention)
    let restarted = await fixture.model(agent: ControlledQueueAgent())
    #expect(restarted.reportAttentionTitle == "Daily report failed")
    #expect(restarted.reportHistory.runs.first?.message == "Mail reader timed out")
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

  @Test("Completed subtasks trigger one parent review, preserve refusals, and respect human review", arguments: [false, true])
  func automaticParentReviewIsBounded(customerConcern: Bool) async throws {
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
    try await eventually { model.subtasks(for: "ECC-101").first?.sessionID == nil }
    #expect(model.session(for: subtask, ticketID: "ECC-101") == nil)
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
      sessionID: sessionID, status: .working, lastHeartbeatAt: Date()))
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
        status: .working, lastHeartbeatAt: Date()))
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

    model.removeSubtask(first, from: fixture.tickets[0])
    try await eventually { model.subtasks(for: "ECC-101").isEmpty }

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
    try await eventually { model.subtasks(for: "ECC-101").isEmpty }

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
             taskAgentLauncher: TaskAgentLauncher = TaskAgentLauncher()) async -> QueueViewModel {
    let boundary = ForbiddenExternalActions()
    let model = QueueViewModel(paths: paths, terminalController: terminalController ?? boundary,
      verifier: verifier ?? boundary, queueAgent: agent, pullRequestQueueLoader: boundary,
      taskAgentLauncher: taskAgentLauncher)
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
  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    if specification.arguments == ["cli", "list", "--format", "json"] {
      return .init(exitCode: 0, standardOutput: "[]", standardError: "", timedOut: false)
    }
    guard specification.arguments.starts(with: ["cli", "spawn"]) else {
      throw TestFailure.unexpectedExternalAction
    }
    spawnCount += 1
    return .init(exitCode: 0, standardOutput: "42\n", standardError: "", timedOut: false)
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
    #expect(context?.subtasks.first?.terminalPaneID == paneID)
    #expect(context?.subtasks.first?.runtimeMode == .terminal)
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

private actor HoldingRecallRecorder: WezTermControlling {
  let fails: Bool
  private var released = false

  init(fails: Bool) { self.fails = fails }

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
