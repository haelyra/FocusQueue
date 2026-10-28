import Foundation
import Testing
@testable import FocusQueueCore

@testable import ECCFocusQueue

@Suite("Durable history integration")
@MainActor
struct DurableHistoryIntegrationTests {
  @Test("Skipped registrations remain pending while the saved assignment remains durable")
  func unmanagedRegistrationIsIgnored() async throws {
    let fixture = try await DurableFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let nativeID = UUID().uuidString
    let original = TaskAgentSession(ticketID: "ECC-301", provider: .codex,
      sessionID: nativeID, tabTitle: "Old assignment", workingDirectory: fixture.root.path)
    let registration = TaskAgentSession(ticketID: "ECC-302", provider: .codex,
      sessionID: nativeID, tabTitle: "New assignment", workingDirectory: fixture.root.path)
    try await JSONLocalStateStore(url: fixture.paths.stateFile).save(LocalState(agentSessions: [original]))
    try await AgentRegistrationInbox(directory: fixture.paths.agentRegistrationsDirectory).submit(registration)
    let model = await fixture.model()
    #expect(model.localState.agentSessions.map(\.ticketID) == ["ECC-301"])
    let library = try await DurableLibraryStore(root: fixture.root).snapshot()
    let taskIDs = Set(library.assignments.map(\.taskID))
    #expect(Set(library.tasks.filter { taskIDs.contains($0.id) }.map(\.ticketID)) == ["ECC-301"])
    #expect(library.sessions.filter { $0.nativeSessionID == nativeID }.count == 1)
    #expect(try await AgentRegistrationInbox(
      directory: fixture.paths.agentRegistrationsDirectory).pending() == [registration])
  }

  @Test("Conversation cache truncation and restart keep every archived message")
  func conversationRetainsMoreThanPresentationLimit() async throws {
    let fixture = try await DurableFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = QueueConversationStore(root: fixture.root)
    let original = (0..<510).map { QueueChatMessage(role: .user, text: "Message \($0)") }
    try await store.save(original, ticketID: "ECC-301")
    let cached = try #require(await store.load(ticketID: "ECC-301"))
    #expect(cached.count == 500)
    let reopened = QueueConversationStore(root: fixture.root)
    try await reopened.save(cached + [QueueChatMessage(role: .agent, text: "A later reply")], ticketID: "ECC-301")
    let archive = DurableLibraryStore(root: fixture.root)
    let snapshot = try await archive.snapshot()
    let document = try #require(snapshot.documents.first { $0.kind == "conversation" })
    let revision = try #require(document.revisions.last)
    let retained = try JSONDecoder().decode([QueueChatMessage].self,
      from: Data(contentsOf: archive.directory.appendingPathComponent(revision.blobPath)))
    #expect(retained.count == 511)
    #expect(retained.contains { $0.id == original[0].id && $0.text == "Message 0" })
  }

  @Test("Archive failure preserves the untruncated canonical conversation")
  func archiveFailurePreservesCanonicalMessages() async throws {
    let fixture = try await DurableFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("Unrelated existing item".utf8).write(to: fixture.root.appendingPathComponent("library"))
    let store = QueueConversationStore(root: fixture.root)
    let messages = (0..<505).map { QueueChatMessage(role: .user, text: "Message \($0)") }
    await #expect(throws: ConversationArchiveError.self) {
      try await store.save(messages, ticketID: "ECC-301")
    }
    #expect(try await store.load(ticketID: "ECC-301")?.count == 505)
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("library"), encoding: .utf8) == "Unrelated existing item")
  }

  @Test("Migration failure stays visible across a successful queue refresh")
  func migrationFailureDoesNotBlockOrDisappear() async throws {
    let fixture = try await DurableFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("Keep this file".utf8).write(to: fixture.root.appendingPathComponent("library"))
    let model = await fixture.model()
    #expect(model.dashboard.tickets.count == 2)
    #expect(model.loadError == nil)
    #expect(model.durableHistoryError != nil)
    await model.refresh()
    #expect(model.loadError == nil)
    #expect(model.durableHistoryError != nil)
  }

  @Test("An unchanged poll does not write another durable revision")
  func unchangedPollLeavesManifestUntouched() async throws {
    let fixture = try await DurableFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model()
    let store = DurableLibraryStore(root: fixture.root)
    let before = try await store.summary()
    let manifest = store.directory.appendingPathComponent("manifest.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: manifest.path)
    try await Task.sleep(for: .milliseconds(2100))
    await model.refresh()
    let after = try await store.summary()
    let updated = try FileManager.default.attributesOfItem(atPath: manifest.path)
    #expect(before.revision == after.revision)
    #expect(attributes[.modificationDate] as? Date == updated[.modificationDate] as? Date)
  }

  @Test("Heartbeat-only context changes wait for a meaningful change before reaching history")
  func heartbeatOnlyChangeLeavesManifestUntouched() async throws {
    let fixture = try await DurableFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let contexts = TaskContextStore(root: fixture.root)
    var agent = TaskSubtask(id: "agent-one", title: "Agent", sessionID: UUID().uuidString,
      status: .working, lastHeartbeatAt: Date())
    let model = await fixture.model()
    try await contexts.upsertSubtask(ticketID: "ECC-301", subtask: agent)
    try await Task.sleep(for: .milliseconds(2100))
    await model.refresh()
    let store = DurableLibraryStore(root: fixture.root)
    let captured = try await store.summary()

    // Agents heartbeat constantly. Each one used to rewrite the whole manifest.
    agent.lastHeartbeatAt = Date().addingTimeInterval(5)
    try await contexts.upsertSubtask(ticketID: "ECC-301", subtask: agent)
    try await Task.sleep(for: .milliseconds(2100))
    await model.refresh()
    #expect(model.subtasks(for: "ECC-301").first?.lastHeartbeatAt == agent.lastHeartbeatAt)
    #expect(try await store.summary().revision == captured.revision)

    agent.status = .blocked
    try await contexts.upsertSubtask(ticketID: "ECC-301", subtask: agent)
    try await Task.sleep(for: .milliseconds(2100))
    await model.refresh()
    #expect(try await store.summary().revision > captured.revision)
  }

  @Test("A bare updatedAt bump never reaches history, even at the periodic flush")
  func updatedAtOnlyChangeIsNeverCaptured() {
    var recorded = TaskContext(ticketID: "ECC-301", title: "Task", summary: "", successCriteria: "",
      planPath: "/tmp/tasks/ECC-301/plan.md", updatedAt: Date(timeIntervalSince1970: 1_000))
    recorded.subtasks = [TaskSubtask(id: "agent-one", title: "Agent", sessionID: "session-one",
      status: .working, lastHeartbeatAt: Date(timeIntervalSince1970: 1_000))]
    var resaved = recorded
    resaved.updatedAt = Date(timeIntervalSince1970: 2_000)
    var heartbeat = resaved
    heartbeat.subtasks[0].lastHeartbeatAt = Date(timeIntervalSince1970: 2_000)
    var blocked = resaved
    blocked.subtasks[0].status = .blocked

    #expect(QueueViewModel.needsDurableCapture(recorded, recorded: nil, flushVolatile: false))
    #expect(!QueueViewModel.needsDurableCapture(recorded, recorded: recorded, flushVolatile: true))
    #expect(!QueueViewModel.needsDurableCapture(resaved, recorded: recorded, flushVolatile: false))
    #expect(!QueueViewModel.needsDurableCapture(resaved, recorded: recorded, flushVolatile: true))
    #expect(!QueueViewModel.needsDurableCapture(heartbeat, recorded: recorded, flushVolatile: false))
    #expect(QueueViewModel.needsDurableCapture(heartbeat, recorded: recorded, flushVolatile: true))
    #expect(QueueViewModel.needsDurableCapture(blocked, recorded: recorded, flushVolatile: false))
  }

  @Test("Reports created after bootstrap enter history without a full migration")
  func newReportIsCapturedIncrementally() async throws {
    let fixture = try await DurableFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = await fixture.model()
    let report = DailyReportDocument(runID: "later-report", trigger: .manual, mode: .unseenOnly,
      startedAt: "2026-09-13T12:00:00Z", finishedAt: "2026-09-13T12:01:00Z", status: .success,
      summary: "Retained after bootstrap", tokenBudget: 0, usage: nil, platforms: [], errors: [])
    try JSONEncoder().encode(report).write(to: fixture.paths.latestDailyReportFile)
    await model.reloadReportHistory()
    let store = DurableLibraryStore(root: fixture.root)
    let snapshot = try await store.snapshot()
    let doc = try #require(snapshot.documents.first { $0.kind == "daily-report" })
    let revision = try #require(doc.revisions.last)
    let retained = try JSONDecoder().decode(DailyReportDocument.self,
      from: Data(contentsOf: store.directory.appendingPathComponent(revision.blobPath)))
    #expect(retained.runID == "later-report")
  }
}

private struct DurableFixture {
  let root: URL
  let paths: AppPaths
  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("fq-durable-integration-\(UUID().uuidString)")
    paths = AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path])
    try FileManager.default.createDirectory(at: paths.ingestionRuntimeDirectory, withIntermediateDirectories: true)
    let dashboard = DashboardDocument(tickets: ["ECC-301", "ECC-302"].map {
      DashboardTicket(id: $0, title: "Task \($0)", status: "open", summary: "Retain history")
    })
    let source = root.appendingPathComponent("dashboard.json")
    try JSONEncoder().encode(dashboard).write(to: source)
    var config = AppConfiguration.eccDefault()
    config.dashboardPath = source.path
    config.workspacePath = root.path
    config.refreshIntervalSeconds = 300
    config.dailyRoutines = []
    config.verifier.enabled = false
    try await JSONConfigurationRepository(url: paths.configurationFile).save(config)
  }

  @MainActor func model() async -> QueueViewModel {
    let boundary = DurableForbiddenActions()
    let model = QueueViewModel(paths: paths, terminalController: boundary,
      queueAgent: boundary, pullRequestQueueLoader: boundary,
      discoverExternalAgents: { [] }, locateExistingAgent: { _, _ in nil })
    await model.bootstrap()
    await model.bootstrapTail?.value
    return model
  }
}

private struct DurableForbiddenActions: WezTermControlling, QueueAgentChatting, PullRequestQueueLoading {
  private func denied<T>() throws -> T {
    Issue.record("Durable-history test attempted an external action")
    throw CocoaError(.featureUnsupported)
  }
  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { try denied() }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { try denied() }
  func attach(paneID: Int, tabTitle: String, windowTitle: String, configuration: WezTermConfiguration) async throws { let _: Void = try denied() }
  func focusOrSpawn(directory: String, taskID: String, taskTitle: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult { try denied() }
  func focusOrResume(session: TaskAgentSession, taskID: String, configuration: WezTermConfiguration) async throws -> TerminalActionResult { try denied() }
  func load(repository: String, closedSince: String) async throws -> PullRequestQueueSnapshot { try denied() }
  func send(message: String, dashboardPath: String, workspace: String, visibleOrder: [String], deferredTicketIDs: [String], configuration: VerifierConfiguration, model: String?, effort: String?) async throws -> QueueAgentReply { try denied() }
  func reset(configuration: VerifierConfiguration) async throws { let _: Void = try denied() }
}
