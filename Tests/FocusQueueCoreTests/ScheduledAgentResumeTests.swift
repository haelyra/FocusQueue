import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Scheduled existing-agent resumes")
struct ScheduledAgentResumeTests {
  private func runtime() -> TmuxSessionReference {
    TmuxSessionReference(
      name: "fq-task-foc-157", serverPID: 41, createdAt: 42,
      paneID: "%7", panePID: 43, tty: "/dev/ttys007", executable: "/opt/homebrew/bin/tmux")
  }

  private func resume(
    id: String = UUID().uuidString,
    fireAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
    expiresAt: Date = Date(timeIntervalSinceReferenceDate: 1_600)
  ) -> ScheduledAgentResume {
    ScheduledAgentResume(
      id: id, createdAt: Date(timeIntervalSinceReferenceDate: 900),
      fireAt: fireAt, expiresAt: expiresAt,
      title: "Continue scheduler", prompt: "Continue the existing work.",
      target: ScheduledAgentResumeTarget(
        taskID: "FOC-157", agentID: "agent-1", provider: .codex,
        sessionID: "11111111-2222-4333-8444-555555555555",
        workspacePath: "/tmp/foc-157", runtime: runtime()))
  }

  private func claimedResume(expiresAt: Date = Date(timeIntervalSinceReferenceDate: 1_600)) -> ScheduledAgentResume {
    var action = resume(expiresAt: expiresAt)
    action.state = .claimed
    action.claimedAt = Date(timeIntervalSinceReferenceDate: 1_100)
    return action
  }

  @Test("Resume actions use a separate versioned file and round-trip pinned identity")
  func versionedRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScheduledAgentResumeStore(supportDirectory: root)
    let action = resume(id: "resume-1")
    try store.add(action)

    #expect(store.file.lastPathComponent == "scheduled-agent-resumes.json")
    #expect(try store.load() == [action])
    let data = try Data(contentsOf: store.file)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(LaunchScheduleStore(supportDirectory: root).load().isEmpty)
  }

  @Test("Locked concurrent additions retain every action")
  func concurrentAdditions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScheduledAgentResumeStore(supportDirectory: root)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<40 {
        group.addTask { try store.add(resume(id: "r-\(index)")) }
      }
      try await group.waitForAll()
    }
    #expect(Set(try store.load().map(\.id)) == Set((0..<40).map { "r-\($0)" }))
  }

  @Test("A due action has one claimant and the claim is durable before dispatch")
  func claimAtMostOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScheduledAgentResumeStore(supportDirectory: root)
    try store.add(resume(id: "once"))

    let claimed = try await withThrowingTaskGroup(of: ScheduledAgentResumeClaimBatch.self) { group in
      for _ in 0..<8 { group.addTask { try store.claimDue(now: Date(timeIntervalSinceReferenceDate: 1_100)) } }
      var batches: [ScheduledAgentResumeClaimBatch] = []
      for try await batch in group { batches.append(batch) }
      return batches
    }
    #expect(claimed.flatMap(\.claimed).map(\.id) == ["once"])
    #expect(try store.load().first?.state == .claimed)
    #expect(try store.claimDue(now: Date(timeIntervalSinceReferenceDate: 1_200)).claimed.isEmpty)
  }

  @Test("Expired actions become terminal without a dispatch claim")
  func expiry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScheduledAgentResumeStore(supportDirectory: root)
    try store.add(resume(id: "late", expiresAt: Date(timeIntervalSinceReferenceDate: 1_050)))
    let batch = try store.claimDue(now: Date(timeIntervalSinceReferenceDate: 1_100))
    #expect(batch.claimed.isEmpty)
    #expect(batch.expired.map(\.id) == ["late"])
    #expect(try store.load().first?.state == .expired)
  }

  @Test("Cancel and retime mutate only pending actions under the store lock")
  func cancelAndRetime() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScheduledAgentResumeStore(supportDirectory: root)
    try store.add(resume(id: "move"))
    let moved = Date(timeIntervalSinceReferenceDate: 1_200)
    #expect(try store.retime(id: "move", fireAt: moved)?.fireAt == moved)
    #expect(try store.cancel(id: "move")?.id == "move")
    #expect(try store.load().isEmpty)
  }

  @Test("Cancel racing a due claim yields either zero dispatches or one durable claim")
  func cancelClaimRace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScheduledAgentResumeStore(supportDirectory: root)
    try store.add(resume(id: "race"))
    async let claim: ScheduledAgentResumeClaimBatch = try store.claimDue(
      now: Date(timeIntervalSinceReferenceDate: 1_100))
    async let cancellation: Bool = {
      do { return try store.cancel(id: "race") != nil }
      catch ScheduledAgentResumeStoreError.notPending(_, _) { return false }
    }()
    let (batch, cancelled) = try await (claim, cancellation)
    #expect((cancelled && batch.claimed.isEmpty) || (!cancelled && batch.claimed.map(\.id) == ["race"]))
    let saved = try store.load()
    #expect(cancelled ? saved.isEmpty : saved.first?.state == .claimed)
  }

  @Test("Dispatcher requires the exact active owner and live provider session")
  func strictDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    _ = try await store.ensureContext(ticket: DashboardTicket(
      id: "FOC-157", title: "Native resume", status: "open", summary: ""))
    var agent = TaskSubtask(
      id: "agent-1", title: "Scheduler", provider: .codex,
      sessionID: "11111111-2222-4333-8444-555555555555", status: .idle)
    agent.workspace = AgentWorkspace(path: "/tmp/foc-157", repositoryPath: "/tmp/repository")
    agent.tmux = runtime()
    _ = try await store.upsertSubtask(ticketID: "FOC-157", subtask: agent)
    let sent = LockedBox<[String]>([])
    let dispatcher = ScheduledAgentResumeDispatcher(
      store: store,
      verifyRuntime: { reference in #expect(reference == runtime()); return reference },
      locateProvider: { provider, sessionID in
        KnownProviderProcess(
          provider: provider, sessionID: sessionID, processID: 99,
          tty: "/dev/ttys007", cwd: "/tmp/foc-157")
      },
      sendPrompt: { action in sent.withLock { $0.append(action.prompt) } },
      now: { Date(timeIntervalSinceReferenceDate: 1_500) })
    try await dispatcher.dispatch(claimedResume())
    #expect(sent.value == ["Continue the existing work."])
  }

  @Test("Dispatcher rejects changed, paused, and retired targets before sending")
  func rejectsIneligibleTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let contexts = TaskContextStore(root: root)
    _ = try await contexts.ensureContext(ticket: DashboardTicket(
      id: "FOC-157", title: "Native resume", status: "open", summary: ""))
    let sends = LockedBox(0)
    func dispatcher() -> ScheduledAgentResumeDispatcher {
      ScheduledAgentResumeDispatcher(
        store: contexts, verifyRuntime: { $0 },
        locateProvider: { provider, sessionID in
          KnownProviderProcess(provider: provider, sessionID: sessionID, processID: 99,
                               tty: "/dev/ttys007", cwd: "/tmp/foc-157")
        }, sendPrompt: { _ in sends.withLock { $0 += 1 } },
        now: { Date(timeIntervalSinceReferenceDate: 1_500) })
    }
    func save(_ edit: (inout TaskSubtask) -> Void) async throws {
      var agent = TaskSubtask(
        id: "agent-1", title: "Scheduler", provider: .codex,
        sessionID: "11111111-2222-4333-8444-555555555555", status: .idle)
      agent.workspace = AgentWorkspace(path: "/tmp/foc-157", repositoryPath: "/tmp/repository")
      agent.tmux = runtime()
      edit(&agent)
      _ = try await contexts.upsertSubtask(ticketID: "FOC-157", subtask: agent)
    }

    try await save { $0.sessionID = UUID().uuidString }
    do {
      try await dispatcher().dispatch(claimedResume())
      Issue.record("Changed session unexpectedly dispatched")
    } catch let error as ScheduledAgentResumeDispatchError {
      #expect(error == .targetChanged("session"))
    }
    try await save { $0.pausedAt = Date() }
    do {
      try await dispatcher().dispatch(claimedResume())
      Issue.record("Paused agent unexpectedly dispatched")
    } catch let error as ScheduledAgentResumeDispatchError {
      #expect(error == .ineligible("agent is paused"))
    }
    try await save { $0.agentRemovedAt = Date() }
    do {
      try await dispatcher().dispatch(claimedResume())
      Issue.record("Retired agent unexpectedly dispatched")
    } catch let error as ScheduledAgentResumeDispatchError {
      #expect(error == .ineligible("agent was retired, merged, or hidden"))
    }
    try await save { $0.mergedIntoSubtaskID = "replacement" }
    do {
      try await dispatcher().dispatch(claimedResume())
      Issue.record("Merged agent unexpectedly dispatched")
    } catch let error as ScheduledAgentResumeDispatchError {
      #expect(error == .ineligible("agent was retired, merged, or hidden"))
    }
    #expect(sends.value == 0)
  }

  @Test("Dispatcher fails closed for absent or mismatched live provider identity")
  func rejectsProviderIdentityMismatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let contexts = TaskContextStore(root: root)
    _ = try await contexts.ensureContext(ticket: DashboardTicket(
      id: "FOC-157", title: "Native resume", status: "open", summary: ""))
    var agent = TaskSubtask(
      id: "agent-1", title: "Scheduler", provider: .codex,
      sessionID: "11111111-2222-4333-8444-555555555555", status: .idle)
    agent.workspace = AgentWorkspace(path: "/tmp/foc-157", repositoryPath: "/tmp/repository")
    agent.tmux = runtime()
    _ = try await contexts.upsertSubtask(ticketID: "FOC-157", subtask: agent)
    let sends = LockedBox(0)
    let missing = ScheduledAgentResumeDispatcher(
      store: contexts, verifyRuntime: { $0 }, locateProvider: { _, _ in nil },
      sendPrompt: { _ in sends.withLock { $0 += 1 } },
      now: { Date(timeIntervalSinceReferenceDate: 1_500) })
    do {
      try await missing.dispatch(claimedResume())
      Issue.record("Missing provider unexpectedly dispatched")
    } catch let error as ScheduledAgentResumeDispatchError {
      #expect(error == .providerNotLive("11111111-2222-4333-8444-555555555555"))
    }
    for process in [
      KnownProviderProcess(provider: .codex,
        sessionID: "11111111-2222-4333-8444-555555555555", processID: 9,
        tty: "/dev/ttys999", cwd: "/tmp/foc-157"),
      KnownProviderProcess(provider: .codex,
        sessionID: "11111111-2222-4333-8444-555555555555", processID: 9,
        tty: "/dev/ttys007", cwd: "/tmp/other"),
      KnownProviderProcess(provider: .codex, sessionID: UUID().uuidString, processID: 9,
        tty: "/dev/ttys007", cwd: "/tmp/foc-157"),
    ] {
      let dispatcher = ScheduledAgentResumeDispatcher(
        store: contexts, verifyRuntime: { $0 }, locateProvider: { _, _ in process },
        sendPrompt: { _ in sends.withLock { $0 += 1 } },
        now: { Date(timeIntervalSinceReferenceDate: 1_500) })
      do {
        try await dispatcher.dispatch(claimedResume())
        Issue.record("Mismatched provider identity unexpectedly dispatched")
      } catch let error as ScheduledAgentResumeDispatchError {
        let expected: ScheduledAgentResumeDispatchError =
          process.cwd == "/tmp/other"
          ? .providerIdentityChanged("workspace")
          : .providerIdentityChanged("provider, session, or terminal")
        #expect(error == expected)
      }
    }
    #expect(sends.value == 0)
  }

  @Test("Final submission authorization rereads a pause written during provider probing")
  func finalCallbackMutationDuringProbe() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let contexts = TaskContextStore(root: root)
    _ = try await contexts.ensureContext(ticket: DashboardTicket(
      id: "FOC-157", title: "Native resume", status: "open", summary: ""))
    var agent = TaskSubtask(
      id: "agent-1", title: "Scheduler", provider: .codex,
      sessionID: "11111111-2222-4333-8444-555555555555", status: .idle)
    agent.workspace = AgentWorkspace(path: "/tmp/foc-157", repositoryPath: "/tmp/repository")
    agent.tmux = runtime()
    _ = try await contexts.upsertSubtask(ticketID: "FOC-157", subtask: agent)
    await #expect(throws: ScheduledAgentResumeDispatchError.self) {
      try await ScheduledAgentResumeDispatcher.authorizeFinalSubmission(
        claimedResume(), store: contexts, verifyRuntime: { $0 },
        locateProvider: { provider, sessionID in
        _ = try await contexts.setPaused(ticketID: "FOC-157", subtaskID: "agent-1", paused: true)
        return KnownProviderProcess(provider: provider, sessionID: sessionID, processID: 9,
                                    tty: "/dev/ttys007", cwd: "/tmp/foc-157")
        }, now: { Date(timeIntervalSinceReferenceDate: 1_500) })
    }
  }

  @Test("Expiry after claim and provider probing blocks the final send")
  func expiresDuringProbe() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let contexts = TaskContextStore(root: root)
    _ = try await contexts.ensureContext(ticket: DashboardTicket(
      id: "FOC-157", title: "Native resume", status: "open", summary: ""))
    var agent = TaskSubtask(
      id: "agent-1", title: "Scheduler", provider: .codex,
      sessionID: "11111111-2222-4333-8444-555555555555", status: .idle)
    agent.workspace = AgentWorkspace(path: "/tmp/foc-157", repositoryPath: "/tmp/repository")
    agent.tmux = runtime()
    _ = try await contexts.upsertSubtask(ticketID: "FOC-157", subtask: agent)
    let clock = LockedBox(Date(timeIntervalSinceReferenceDate: 1_500))
    let sends = LockedBox(0)
    let dispatcher = ScheduledAgentResumeDispatcher(
      store: contexts, verifyRuntime: { $0 },
      locateProvider: { provider, sessionID in
        clock.withLock { $0 = Date(timeIntervalSinceReferenceDate: 1_601) }
        return KnownProviderProcess(provider: provider, sessionID: sessionID, processID: 99,
                                    tty: "/dev/ttys007", cwd: "/tmp/foc-157")
      },
      sendPrompt: { _ in sends.withLock { $0 += 1 } },
      now: { clock.value })
    await #expect(throws: ScheduledAgentResumeDispatchError.self) {
      try await dispatcher.dispatch(claimedResume())
    }
    #expect(sends.value == 0)
  }

  @Test("A paste timeout is an unknown delivery outcome, not a definite non-send")
  func pasteTimeoutIsUnknown() async throws {
    let reference = runtime()
    let controller = TmuxController(runner: PasteTimeoutRunner(reference: reference))
    await #expect(throws: TmuxPromptDeliveryUnknown.self) {
      _ = try await controller.submitPrompt(
        "Continue.", to: reference, ready: { _ in true }, timeout: .seconds(1))
    }
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value
  init(_ value: Value) { storage = value }
  var value: Value { lock.withLock { storage } }
  func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&storage) } }
}

private actor PasteTimeoutRunner: ProcessRunning {
  let reference: TmuxSessionReference

  init(reference: TmuxSessionReference) { self.reference = reference }

  func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
    if specification.arguments.contains("display-message") {
      let fields = [
        reference.name, String(reference.serverPID), String(reference.createdAt),
        reference.paneID, String(reference.panePID), reference.tty, "0",
      ]
      return ProcessResult(
        exitCode: 0, standardOutput: fields.joined(separator: "|") + "\n",
        standardError: "", timedOut: false)
    }
    if specification.arguments.contains("capture-pane") {
      return ProcessResult(exitCode: 0, standardOutput: "ready", standardError: "", timedOut: false)
    }
    if specification.arguments.contains("paste-buffer") {
      return ProcessResult(
        exitCode: 1, standardOutput: "", standardError: "paste timed out", timedOut: true)
    }
    return ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
  }
}
