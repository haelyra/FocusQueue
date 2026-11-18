import Foundation
import Testing
@testable import FocusQueueCore

/// FOC-142: registration and open-failure logs explain why an agent could
/// not be opened, instead of leaving only an alert that was dismissed.
@Suite("Agent event logs")
struct AgentEventLogTests {
  private func lines(_ url: URL) throws -> [[String: Any]] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }

  private func store() async throws -> (TaskContextStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("fq-event-log-\(UUID().uuidString)", isDirectory: true)
    let store = TaskContextStore(root: root)
    _ = try await store.ensureContext(
      ticket: DashboardTicket(id: "ECC-900", title: "Task", status: "open", summary: ""))
    return (store, root)
  }

  @Test("An identity failure logs the step, reason, and colliding processes, and the alert ends with the log path")
  func identityFailureEntry() throws {
    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent("fq-open-log-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: support) }
    let session = "11111111-1111-4111-8111-111111111111"
    let error = ProviderIdentityError(provider: .claude, sessionID: session, blockers: [
      .init(provider: .claude, processID: 40, tty: "/dev/ttys040", cwd: "/tmp/repo"),
      .init(provider: .claude, processID: 41, tty: "/dev/ttys041", cwd: "/tmp/repo"),
    ], candidates: [.init(provider: .claude, sessionID: "22222222-2222-4222-8222-222222222222",
      processID: 42, tty: "/dev/ttys042", cwd: "/tmp/other")])

    let path = AgentEventLog.record(AgentEventLog.openFailure(
      source: "app", task: "ECC-900", subtask: "agent", provider: .claude, session: session,
      step: "locate-running", error: error), supportDirectory: support)

    #expect(path == support.appendingPathComponent("logs/agent-open.jsonl").path)
    let entry = try #require(try lines(URL(fileURLWithPath: path)).first)
    #expect(entry["task"] as? String == "ECC-900")
    #expect(entry["subtask"] as? String == "agent")
    #expect(entry["session"] as? String == session)
    #expect(entry["step"] as? String == "identity")
    #expect(entry["reason"] as? String
      == "2 Claude processes share /tmp/repo (pids 40, 41); cannot tell which owns \(session).")
    let unresolved = try #require(entry["unresolved"] as? [[String: Any]])
    #expect(unresolved.map { $0["pid"] as? Int } == [40, 41])
    #expect(unresolved.first?["cwd"] as? String == "/tmp/repo")
    #expect(unresolved.first?["tty"] as? String == "/dev/ttys040")
    let candidates = try #require(entry["candidates"] as? [[String: Any]])
    #expect(candidates.first?["pid"] as? Int == 42)
    #expect(AgentEventLog.message(error.localizedDescription, logPath: path)
      .hasSuffix("Details: \(path)"))
  }

  @Test("A non-identity failure keeps its step and reason")
  func plainFailureEntry() {
    let entry = AgentEventLog.openFailure(source: "app", task: "ECC-900", subtask: "a",
      provider: .codex, session: nil, step: "open-view",
      error: WezTermError.actionFailed("WezTerm could not attach"))
    #expect(entry.step == "open-view")
    #expect(entry.reason.contains("WezTerm could not attach"))
    #expect(entry.unresolved.isEmpty)
  }

  @Test("A startup-shaped identity failure says so; a shared directory does not")
  func identityMessages() {
    let session = "11111111-1111-4111-8111-111111111111"
    let starting = ProviderIdentityError(provider: .codex, sessionID: session,
      blockers: [.init(provider: .codex, processID: 7, tty: nil, cwd: nil)])
    #expect(starting.localizedDescription
      == "Codex process 7 has no readable working directory yet (it may still be starting); cannot tell which owns \(session).")
    let lone = ProviderIdentityError(provider: .claude, sessionID: session,
      blockers: [.init(provider: .claude, processID: 8, tty: nil, cwd: "/tmp/repo")])
    #expect(lone.localizedDescription
      == "Claude process 8 in /tmp/repo has no registered or open session; cannot tell which owns \(session).")
  }

  @Test("A fresh association beside a finished record logs a duplicate")
  func duplicateCreatedIsLogged() async throws {
    let (store, root) = try await store()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID().uuidString.lowercased()
    func register() async throws -> TaskContext {
      try await store.registerExternalSession(
        ticketID: "ECC-900", provider: .claude, sessionID: session, title: "Worker",
        cwd: "/tmp/repo", preferredSubtaskID: nil, allowFreshAssociation: true,
        tmux: nil, paneID: nil, socketPath: nil, eventName: "SessionStart")
    }
    let first = try await register()
    let original = try #require(first.subtasks.first?.id)
    _ = try await store.overrideCompletion(ticketID: "ECC-900", subtaskID: original)
    let second = try await register()
    #expect(second.subtasks.count == 2)

    let entries = try lines(AgentEventLog.registrationURL(supportDirectory: root))
      .filter { $0["event"] as? String == "duplicate-created" }
    #expect(entries.count == 1)
    #expect(entries.first?["session"] as? String == session)
    #expect(entries.first?["cwd"] as? String == "/tmp/repo")
    #expect((entries.first?["details"] as? [String: String])?["existingSubtasks"] == original)
  }

  @Test("A duplicate merge logs whether tmux and workspace carried over")
  func duplicateMergeIsLogged() async throws {
    let (store, root) = try await store()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID().uuidString.lowercased()
    let kept = TaskSubtask(id: "kept", title: "Kept", provider: .claude, sessionID: session)
    var merged = TaskSubtask(id: "merged", title: "Merged", provider: .claude, sessionID: session)
    merged.tmux = TmuxSessionReference(name: "fq-task-ecc-900", serverPID: 1, createdAt: 1,
      paneID: "%3", panePID: 2, tty: "/dev/ttys003", executable: "/mock/tmux")
    merged.workspace = AgentWorkspace(path: "/tmp/ws", repositoryPath: "/tmp/repo")
    for subtask in [kept, merged] { _ = try await store.upsertSubtask(ticketID: "ECC-900", subtask: subtask) }

    _ = try await store.reconcileSubtasks(ticketID: "ECC-900")
    _ = try await store.reconcileSubtasks(ticketID: "ECC-900")

    let entries = try lines(AgentEventLog.registrationURL(supportDirectory: root))
      .filter { $0["event"] as? String == "duplicate-merged" }
    #expect(entries.count == 1, "a repeated reconcile must not log the same merge again")
    let details = try #require(entries.first?["details"] as? [String: String])
    #expect(entries.first?["subtask"] as? String == "merged")
    #expect(details["into"] == "kept")
    #expect(details["tmux"] == "lost")
    #expect(details["workspace"] == "lost")
    #expect(entries.first?["pane"] as? String == "%3")
  }

  @Test("Workspace assignments log success and refusal")
  func workspaceAssignmentIsLogged() async throws {
    let (store, root) = try await store()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await store.upsertSubtask(ticketID: "ECC-900",
      subtask: TaskSubtask(id: "agent", title: "Agent", provider: .claude))
    _ = try await store.setAgentWorkspace(ticketID: "ECC-900", subtaskID: "agent",
      workspace: AgentWorkspace(path: "/tmp/one", repositoryPath: "/tmp/repo", branch: "one"))
    await #expect(throws: TaskContextError.self) {
      try await store.setAgentWorkspace(ticketID: "ECC-900", subtaskID: "agent",
        workspace: AgentWorkspace(path: "/tmp/two", repositoryPath: "/tmp/repo"))
    }
    let entries = try lines(AgentEventLog.registrationURL(supportDirectory: root))
      .filter { $0["event"] as? String == "workspace-assigned" }
    #expect(entries.map { $0["outcome"] as? String } == ["assigned", "failed"])
    #expect(entries.first?["cwd"] as? String == "/tmp/one")
    #expect(entries.last?["reason"] as? String != nil)
    #expect(entries.allSatisfy { $0["time"] is String })
  }
}
