import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Kimi launches and per-provider launch memory")
struct KimiLaunchTests {
  private let context = TaskContext(
    ticketID: "ECC-1", title: "Kimi", summary: "", successCriteria: "Checks pass",
    planPath: "/tmp/support/tasks/ECC-1/plan.md", worktreePath: "/tmp/worktree", updatedAt: Date())
  private let support = URL(fileURLWithPath: "/tmp/support")

  @Test("Kimi offers only the efforts its models support and receives them through the environment")
  func kimiEffort() {
    #expect(AppConfiguration.agentEffortLevels(for: .kimi) == ["low", "high", "max"])
    #expect(AppConfiguration.agentEffortLevels(for: .claude) == AppConfiguration.agentEffortLevels)
    #expect(AgentProvider.kimi.effortEnvironment(effort: "High") == ["KIMI_MODEL_THINKING_EFFORT=high"])
    #expect(AgentProvider.kimi.effortEnvironment(effort: "medium").isEmpty)
    #expect(AgentProvider.claude.effortEnvironment(effort: "high").isEmpty)
  }

  @Test("A Kimi launch carries model, effort, and workspace trust, and a pasted prompt stays out of argv")
  func kimiCommand() throws {
    var subtask = TaskSubtask(title: "Kimi agent", provider: .kimi)
    subtask.launchConfiguration = AgentLaunchConfiguration(model: "kimi-code/k3", effort: "max")
    let oneShot = try TaskAgentLauncher.command(context: context, subtask: subtask, supportDirectory: support)
    #expect(oneShot.contains("KIMI_MODEL_THINKING_EFFORT=max"))
    #expect(oneShot.contains("KIMI_CODE_TRUST_WORKSPACE=1"))
    let model = try #require(oneShot.firstIndex(of: "--model"))
    #expect(oneShot[model + 1] == "kimi-code/k3")
    #expect(oneShot.contains("--prompt"))

    let interactive = try TaskAgentLauncher.command(
      context: context, subtask: subtask, supportDirectory: support, pastesPrompt: true)
    #expect(!interactive.contains("--prompt"))
    #expect(interactive.contains("KIMI_MODEL_THINKING_EFFORT=max"))
    #expect(TaskAgentLauncher.initialPrompt(context: context, subtask: subtask, includePrompt: true)
      == context.agentPrompt(subtask: subtask))

    subtask.sessionID = "session_11111111-2222-4333-8444-555555555555"
    let resumed = try TaskAgentLauncher.command(context: context, subtask: subtask, supportDirectory: support)
    #expect(resumed.contains("KIMI_MODEL_THINKING_EFFORT=max"))
    #expect(TaskAgentLauncher.initialPrompt(context: context, subtask: subtask, includePrompt: true) == nil)

    var claude = TaskSubtask(title: "Claude agent", provider: .claude)
    claude.launchConfiguration = AgentLaunchConfiguration(effort: "high")
    let claudeLaunch = try TaskAgentLauncher.command(context: context, subtask: claude, supportDirectory: support)
    #expect(!claudeLaunch.contains { $0.hasPrefix("KIMI_") })
  }

  @Test("Kimi is ready for typed input only once its input box is on screen")
  func kimiReadiness() {
    #expect(!TaskAgentLauncher.kimiInputIsReady("  Trust this folder?\n   ❯ Trust and continue\n"))
    #expect(TaskAgentLauncher.kimiInputIsReady("""
       ╭──────╮
       │ >    │
       ╰──────╯
       K3 thinking: high
      """))
  }

  @Test("Each provider keeps its own last launch while the newest one stays the overall default")
  func perProviderMemory() throws {
    var state = LocalState(routineDate: "2026-10-20")
    let kimi = AgentLaunchPreset(provider: .kimi, model: "kimi-code/k3", effort: "high", useTmux: true)
    let claude = AgentLaunchPreset(provider: .claude, model: "claude-opus-5-5", effort: "max")
    let codex = AgentLaunchPreset(provider: .codex, model: "gpt-6-sol", effort: "low")
    state.rememberAgentLaunch(kimi)
    state.rememberAgentLaunch(claude)
    state.rememberAgentLaunch(codex)
    let newerClaude = AgentLaunchPreset(provider: .claude, model: "claude-sonnet-5-5", effort: "low")
    state.rememberAgentLaunch(newerClaude)

    #expect(state.lastAgentLaunch == newerClaude)
    #expect(state.lastAgentLaunch(for: .kimi) == kimi)
    #expect(state.lastAgentLaunch(for: .claude) == newerClaude)
    #expect(state.lastAgentLaunch(for: .codex) == codex)
    #expect(state.lastAgentLaunches?.count == 3)

    let decoded = try JSONDecoder().decode(LocalState.self, from: JSONEncoder().encode(state))
    #expect(decoded == state)

    // State saved before per-provider memory still answers for its one provider.
    let legacy = LocalState(routineDate: "2026-10-20", lastAgentLaunch: kimi)
    #expect(legacy.lastAgentLaunch(for: .kimi) == kimi)
    #expect(legacy.lastAgentLaunch(for: .claude) == nil)

    // An entry from a newer build drops alone instead of erasing the others.
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    var launches = try #require(object["lastAgentLaunches"] as? [[String: Any]])
    launches.append(["provider": "future-provider"])
    object["lastAgentLaunches"] = launches
    let tolerant = try JSONDecoder().decode(LocalState.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(tolerant.lastAgentLaunches == state.lastAgentLaunches)
  }

  @Test("A prompt is pasted as one message once the pane is ready",
    .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func submitPromptIntoLivePane() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fq-kimi-paste-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let serverName = "fq-kimi-paste-\(UUID().uuidString.prefix(8))"
    defer {
      let cleanup = Process()
      cleanup.executableURL = URL(fileURLWithPath: executable)
      cleanup.arguments = ["-L", serverName, "kill-server"]
      cleanup.environment = ["TMUX_TMPDIR": "/tmp", "PATH": "/usr/bin:/bin"]
      cleanup.standardError = FileHandle.nullDevice
      try? cleanup.run(); cleanup.waitUntilExit()
      try? FileManager.default.removeItem(at: root)
    }
    let output = root.appendingPathComponent("received.txt")
    // The fake TUI shows its input box after a delay, then records two lines.
    let script = "sleep 1; printf '│ >\\n'; head -n 2 > \"$1\"; sleep 30"
    let controller = TmuxController(serverName: serverName)
    let reference = try await controller.start(
      name: "fq-kimi-paste", directory: root.path,
      command: ["/bin/sh", "-c", script, "fake-kimi", output.path], executable: executable)
    let submitted = try await controller.submitPrompt(
      "first line; $(not run)\nsecond line", to: reference,
      ready: TaskAgentLauncher.kimiInputIsReady, timeout: .seconds(10))
    #expect(submitted)
    for _ in 0..<40 where (try? String(contentsOf: output, encoding: .utf8))?.hasSuffix("\n") != true {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(try String(contentsOf: output, encoding: .utf8) == "first line; $(not run)\nsecond line\n")
  }
}
