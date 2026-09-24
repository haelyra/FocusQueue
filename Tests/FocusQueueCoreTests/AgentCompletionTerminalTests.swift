import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Agent completion terminal")
struct AgentCompletionTerminalTests {
  @Test("Auto-exit defaults on for old configuration and persists opt-out")
  func configurationMigration() throws {
    var config = AppConfiguration.eccDefault()
    #expect(config.autoExitCompletedAgents)
    #expect(config.agentUsageBarEnabled)
    var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    old.removeValue(forKey: "autoExitCompletedAgents")
    old.removeValue(forKey: "agentUsageBarEnabled")
    let migrated = try JSONDecoder().decode(
      AppConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(migrated.autoExitCompletedAgents)
    #expect(migrated.agentUsageBarEnabled)
    config.autoExitCompletedAgents = false
    config.agentUsageBarEnabled = false
    let saved = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
    #expect(!saved.autoExitCompletedAgents)
    #expect(!saved.agentUsageBarEnabled)
  }

  @Test("Resume commands preserve the exact provider UUID and safely quote workspaces")
  func resumeCommands() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("completion ' $(false) \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = context(root)
    for provider in AgentProvider.allCases {
      let agent = TaskSubtask(title: "Done", provider: provider, sessionID: UUID().uuidString, status: .completed)
      let message = try AgentCompletionMessage(context: context, subtask: agent, taskCompleted: false)
      #expect(message.text.contains("Agent exited. Subtask for ECC-TEST is complete."))
      let capture = "codex() { printf '%s\\n' \"$PWD\" \"$@\"; }; claude() { printf '%s\\n' \"$PWD\" \"$@\"; }; "
      let result = try await FoundationProcessRunner().run(.init(executable: "/bin/sh", arguments: ["-c", capture + message.resumeCommand]))
      #expect(result.succeeded)
      let captured = result.standardOutput.split(separator: "\n").map(String.init)
      let expected = [root.path] + provider.resumeArguments(sessionID: agent.sessionID!)
      #expect(captured == expected)
      #expect(try AgentCompletionMessage(context: context, subtask: agent, taskCompleted: true).text.contains("Task ECC-TEST is complete."))
    }
    #expect(throws: (any Error).self) {
      try AgentCompletionMessage(context: context, subtask: TaskSubtask(title: "Unknown"), taskCompleted: false)
    }
  }

  @Test("Real detached tmux completion keeps its pane and sibling alive with a resume message")
  func detachedCompletionWorkflow() async throws {
    let tmux = try #require(SetupEnvironment.executable("tmux"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("completion-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = "completion-test-\(UUID().uuidString.lowercased())"
    let runner = FoundationProcessRunner()
    let runtime = TmuxController(serverName: server, confirmationAttempts: 20, confirmationDelayMilliseconds: 20)
    let saved = try await runtime.start(name: "completion", directory: root.path,
      command: ["/bin/sleep", "120"], executable: tmux)
    do {
      let sibling = try await runner.run(.init(executable: tmux,
        arguments: ["-L", server, "split-window", "-d", "-P", "-F", "#{pane_id}", "-t", saved.paneID, "/bin/sleep", "120"]))
      #expect(sibling.succeeded)
      var agent = TaskSubtask(title: "Done", sessionID: UUID().uuidString, status: .completed)
      agent.tmux = saved
      let result = try await TaskAgentLauncher(tmuxServerName: server).finishRuntime(
        context: context(root), subtask: agent, taskCompleted: false, configuration: .init(executable: "/unused"))
      guard case .managed(let completed) = result else { Issue.record("No completion terminal"); return }
      #expect(completed.paneID == saved.paneID)
      #expect(completed.panePID != saved.panePID)
      _ = try await runtime.verify(completed)
      var output = ""
      for _ in 0..<30 {
        let capture = try await runner.run(.init(executable: tmux,
          arguments: ["-L", server, "capture-pane", "-p", "-J", "-t", saved.paneID]))
        output = capture.standardOutput
        if output.contains(agent.sessionID!) { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      #expect(output.contains("Agent exited."))
      #expect(output.contains("Subtask for ECC-TEST is complete."))
      #expect(output.contains(agent.sessionID!))
      let panes = try await runner.run(.init(executable: tmux,
        arguments: ["-L", server, "list-panes", "-t", "completion", "-F", "#{pane_id}:#{pane_dead}"]))
      #expect(panes.standardOutput.contains(saved.paneID + ":0"))
      #expect(panes.standardOutput.contains(sibling.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) + ":0"))
    } catch {
      _ = try? await runner.run(.init(executable: tmux, arguments: ["-L", server, "kill-server"]))
      throw error
    }
    _ = try await runner.run(.init(executable: tmux, arguments: ["-L", server, "kill-server"]))
  }

  @Test("Retained completion terminals protect workspaces from cleanup")
  func retainsWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("retained-\(UUID().uuidString)")
    var agent = TaskSubtask(title: "Done", status: .completed)
    agent.completionTerminalRetained = true
    let maintenance = TaskMaintenance(root: root, inspect: { _ in false })
    await #expect(throws: (any Error).self) { try await maintenance.requireInactive(agent) }
    let result = try await TaskWorktreeManager().cleanupAgent(ticketID: "ECC-TEST", subtask: agent, store: TaskContextStore(root: root))
    #expect(!result.removed)
    #expect(result.message.contains("resume command"))
  }

  private func context(_ root: URL) -> TaskContext {
    TaskContext(ticketID: "ECC-TEST", title: "Completion", summary: "", successCriteria: "",
      planPath: root.appendingPathComponent("plan.md").path, worktreePath: root.path, updatedAt: Date())
  }
}
