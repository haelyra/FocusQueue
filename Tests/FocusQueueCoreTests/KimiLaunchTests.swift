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

  @Test("Every provider's new-task brief contains the central artifact route", arguments: AgentProvider.allCases)
  func artifactBrief(provider: AgentProvider) throws {
    let brief = try #require(TaskAgentLauncher.initialPrompt(
      context: context, subtask: TaskSubtask(title: "Agent", provider: provider), includePrompt: true))
    #expect(brief.contains("/tmp/support/tasks/ECC-1/evidence"))
    #expect(brief.contains("not the worktree Docs folder"))
    #expect(brief.contains("the task card announces each new file"))
  }

  @Test("Kimi receives the actual Documents instructions in its first prompt")
  func kimiDocumentsInstructions() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("fq-kimi-home-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let documents = home.appendingPathComponent("Documents")
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try Data("# Current output contract\nUse the central task evidence folder.\n".utf8)
      .write(to: documents.appendingPathComponent("AGENTS.md"))
    let loaded = try #require(TaskAgentLauncher.kimiDocumentsInstructions(
      workspace: documents.appendingPathComponent("project/.worktrees/agent").path, home: home))
    #expect(loaded.path == documents.appendingPathComponent("AGENTS.md").path)
    #expect(loaded.text.contains("Current output contract"))
    #expect(TaskAgentLauncher.kimiDocumentsInstructions(workspace: "/tmp/other", home: home) == nil)
    let task = TaskContext(ticketID: "FOC-901", title: "Task", summary: "", successCriteria: "Done",
      planPath: "/tmp/support/tasks/FOC-901/plan.md", worktreePath: documents.path + "/project/agent",
      updatedAt: Date())
    let prompt = try #require(TaskAgentLauncher.initialPrompt(
      context: task, subtask: TaskSubtask(title: "Kimi", provider: .kimi), includePrompt: true,
      home: home))
    #expect(prompt.contains("Developer instructions from \(loaded.path):"))
    #expect(prompt.contains("Current output contract"))
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

    // State saved before per-provider memory still answers for its one provider,
    // and keeps it when another provider launches first after the upgrade.
    var legacy = LocalState(routineDate: "2026-10-20", lastAgentLaunch: kimi)
    #expect(legacy.lastAgentLaunch(for: .kimi) == kimi)
    #expect(legacy.lastAgentLaunch(for: .claude) == nil)
    legacy.rememberAgentLaunch(claude)
    let upgraded = try JSONDecoder().decode(LocalState.self, from: JSONEncoder().encode(legacy))
    #expect(upgraded.lastAgentLaunch == claude)
    #expect(upgraded.lastAgentLaunch(for: .kimi) == kimi)
    #expect(upgraded.lastAgentLaunch(for: .claude) == claude)

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
    let script = "sleep 1; stty -icanon -echo min 1 time 0; printf '│ >\\n'; head -n 2 > \"$1\"; sleep 30"
    let controller = TmuxController(serverName: serverName)
    let reference = try await controller.start(
      name: "fq-kimi-paste", directory: root.path,
      command: ["/bin/sh", "-c", script, "fake-kimi", output.path], executable: executable)
    let prompt = "first line; $(not run)" + String(repeating: "x", count: 15_000) + "\nsecond line"
    let submitted = try await controller.submitPrompt(
      prompt, to: reference,
      ready: TaskAgentLauncher.kimiInputIsReady, timeout: .seconds(10))
    #expect(submitted)
    for _ in 0..<40 where (try? String(contentsOf: output, encoding: .utf8))?.hasSuffix("\n") != true {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(try String(contentsOf: output, encoding: .utf8) == prompt + "\n")
  }

  @Test("A transient tmux inspection failure does not drop Kimi's initial prompt",
    .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func submitPromptRetriesTransientInspection() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fq-kimi-paste-retry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let serverName = "fq-kimi-retry-\(UUID().uuidString.prefix(8))"
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
    let script = "stty -icanon -echo min 1 time 0; printf '│ >\\n'; head -n 1 > \"$1\"; sleep 30"
    let runner = TransientTmuxInspectionRunner()
    let controller = TmuxController(runner: runner, serverName: serverName)
    let reference = try await controller.start(
      name: "fq-kimi-retry", directory: root.path,
      command: ["/bin/sh", "-c", script, "fake-kimi", output.path], executable: executable)
    await runner.failNextInspection()

    #expect(try await controller.submitPrompt(
      "retry survived", to: reference,
      ready: TaskAgentLauncher.kimiInputIsReady, timeout: .seconds(10)))
    for _ in 0..<40 where (try? String(contentsOf: output, encoding: .utf8))?.hasSuffix("\n") != true {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(try String(contentsOf: output, encoding: .utf8) == "retry survived\n")
  }
}

private actor TransientTmuxInspectionRunner: ProcessRunning {
  private let base = FoundationProcessRunner()
  private var shouldFailInspection = false

  func failNextInspection() { shouldFailInspection = true }

  func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
    if shouldFailInspection, specification.arguments.contains("display-message") {
      shouldFailInspection = false
      return ProcessResult(
        exitCode: 1, standardOutput: "", standardError: "temporary tmux inspection failure",
        timedOut: false)
    }
    return try await base.run(specification)
  }
}
