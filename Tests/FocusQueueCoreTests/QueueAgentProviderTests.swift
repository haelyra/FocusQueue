import Foundation
import Testing

@testable import FocusQueueCore

private actor QueueAgentRecordingRunner: ProcessRunning {
  private var results: [ProcessResult]
  private(set) var specifications: [ProcessSpecification] = []

  init(results: [ProcessResult] = []) {
    self.results = results
  }

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    specifications.append(specification)
    guard !results.isEmpty else {
      return ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "", timedOut: false)
    }
    return results.removeFirst()
  }
}

private func chatConfiguration(executable: String) -> VerifierConfiguration {
  VerifierConfiguration(
    enabled: true,
    executable: executable,
    sessionName: "unused",
    timeoutSeconds: 60,
    maxTurns: 12
  )
}

@Test("Queue agent prompt differs between providers only in its identity line")
func queueAgentPromptNeutrality() {
  func lines(for provider: AgentProvider) -> [String] {
    QueueAgentPrompt.build(
      provider: provider,
      message: "Why is ECC-002 second?",
      dashboardPath: "/tmp/dashboard.json",
      workspace: "/tmp/workspace",
      visibleOrder: ["ECC-001", "ECC-002"],
      deferredTicketIDs: ["ECC-009"]
    ).components(separatedBy: "\n")
  }

  let codex = lines(for: .codex)
  let claude = lines(for: .claude)
  let kimi = lines(for: .kimi)

  #expect(codex.first == "You are the Codex Queue agent for Focus Queue.")
  #expect(claude.first == "You are the Claude Queue agent for Focus Queue.")
  #expect(kimi.first == "You are the Kimi Queue agent for Focus Queue.")
  #expect(Array(codex.dropFirst()) == Array(claude.dropFirst()))
  #expect(Array(codex.dropFirst()) == Array(kimi.dropFirst()))
}

@Test("Codex queue agent forwards model and effort flags to its harness")
func codexQueueAgentModelEffortFlags() async throws {
  let runner = QueueAgentRecordingRunner()
  let agent = CodexQueueAgent(runner: runner)

  _ = try await agent.send(
    message: "Why is ECC-002 second?",
    dashboardPath: "/tmp/dashboard.json",
    workspace: "/tmp",
    visibleOrder: [],
    deferredTicketIDs: [],
    configuration: chatConfiguration(executable: "/mock/focus-queue-codex"),
    model: "gpt-5.5",
    effort: "high"
  )

  let invocation = try #require(await runner.specifications.first)
  #expect(invocation.executable == "/mock/focus-queue-codex")
  #expect(invocation.arguments.contains("--model"))
  #expect(invocation.arguments.contains("gpt-5.5"))
  #expect(invocation.arguments.contains("--effort"))
  #expect(invocation.arguments.contains("high"))
}

@Test("Queue agents omit model and effort flags for empty settings")
func queueAgentOmitsEmptyModelEffort() async throws {
  let runner = QueueAgentRecordingRunner()
  let agent = CodexQueueAgent(runner: runner)

  _ = try await agent.send(
    message: "Why is ECC-002 second?",
    dashboardPath: "/tmp/dashboard.json",
    workspace: "/tmp",
    visibleOrder: [],
    deferredTicketIDs: [],
    configuration: chatConfiguration(executable: "/mock/focus-queue-codex"),
    model: "  ",
    effort: ""
  )

  let invocation = try #require(await runner.specifications.first)
  #expect(!invocation.arguments.contains("--model"))
  #expect(!invocation.arguments.contains("--effort"))
}

@Test("Claude and Kimi queue agents share the codex harness argument structure")
func claudeKimiQueueAgentArguments() async throws {
  let cases: [(String, String)] = [
    ("/mock/focus-queue-claude", ClaudeQueueAgent.sessionName),
    ("/mock/focus-queue-kimi", KimiQueueAgent.sessionName),
  ]
  for (executable, sessionName) in cases {
    let runner = QueueAgentRecordingRunner()
    let agent: any QueueAgentChatting = executable.contains("claude")
      ? ClaudeQueueAgent(runner: runner)
      : KimiQueueAgent(runner: runner)
    _ = try await agent.send(
      message: "Why is ECC-002 second?",
      dashboardPath: "/tmp/dashboard.json",
      workspace: "/tmp",
      visibleOrder: [],
      deferredTicketIDs: [],
      configuration: chatConfiguration(executable: executable),
      model: "some-model",
      effort: "low"
    )
    let invocation = try #require(await runner.specifications.first)
    #expect(invocation.executable == executable)
    #expect(invocation.arguments.contains("chat"))
    #expect(invocation.arguments.contains("--session"))
    #expect(invocation.arguments.contains(sessionName))
    #expect(invocation.arguments.contains("--workspace"))
    #expect(invocation.arguments.contains("--prompt-file"))
    #expect(invocation.arguments.contains("--timeout"))
    #expect(invocation.arguments.contains("--model"))
    #expect(invocation.arguments.contains("--effort"))
    #expect(sessionName.hasPrefix("ecc-focus-queue-"))
  }
}

@Test("Queue agent reset invokes the harness reset subcommand for the provider session")
func queueAgentResetArguments() async throws {
  let runner = QueueAgentRecordingRunner()
  let agent = ClaudeQueueAgent(runner: runner)

  try await agent.reset(configuration: chatConfiguration(executable: "/mock/focus-queue-claude"))

  let invocation = try #require(await runner.specifications.first)
  #expect(invocation.executable == "/mock/focus-queue-claude")
  #expect(invocation.arguments == ["reset", "--session", "ecc-focus-queue-claude-v1"])
}

@Test("Queue agent reset keeps task-scoped session names")
func queueAgentResetTaskSession() async throws {
  let runner = QueueAgentRecordingRunner()
  let agent = CodexQueueAgent(runner: runner)
  var configuration = chatConfiguration(executable: "/mock/focus-queue-codex")
  configuration.sessionName = "ecc-focus-queue-task-ecc-101"

  try await agent.reset(configuration: configuration)

  let invocation = try #require(await runner.specifications.first)
  #expect(invocation.arguments == ["reset", "--session", "ecc-focus-queue-task-ecc-101"])
}

@Test("Daily report automation appends the selected agent flags")
func dailyReportAutomationAgentArguments() {
  let request = DailyReportRunRequest(
    trigger: .scheduled,
    platforms: [.email],
    comprehensive: true,
    recheck: false
  )
  let base = DailyReportAutomation.arguments(
    scriptPath: "/support/focus_queue_morning.py",
    configurationPath: "/support/ingestion.json",
    runtimePath: "/support/ingestion",
    request: request
  )
  #expect(!base.contains("--agent-provider"))
  #expect(!base.contains("--agent-model"))
  #expect(!base.contains("--agent-effort"))

  let selected = DailyReportAutomation.arguments(
    scriptPath: "/support/focus_queue_morning.py",
    configurationPath: "/support/ingestion.json",
    runtimePath: "/support/ingestion",
    request: request,
    agentProvider: .claude,
    agentModel: "claude-sonnet-5",
    agentEffort: "high"
  )
  func flagValue(_ flag: String, in arguments: [String]) -> String? {
    arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
  }
  #expect(flagValue("--agent-provider", in: selected) == "claude")
  #expect(flagValue("--agent-model", in: selected) == "claude-sonnet-5")
  #expect(flagValue("--agent-effort", in: selected) == "high")
}

@Test("Daily report configuration decodes agent selection with nil defaults")
func dailyReportConfigurationAgentDefaults() throws {
  let decoded = try JSONDecoder().decode(DailyReportConfiguration.self, from: Data("{}".utf8))
  #expect(decoded.agentProvider == nil)
  #expect(decoded.agentModel == nil)
  #expect(decoded.agentEffort == nil)

  let pinned = try JSONDecoder().decode(
    DailyReportConfiguration.self,
    from: Data(#"{"agentProvider":"CLAUDE","agentModel":"claude-sonnet-5","agentEffort":"high"}"#.utf8)
  )
  #expect(pinned.agentProvider == .claude)
  #expect(pinned.agentModel == "claude-sonnet-5")
  #expect(pinned.agentEffort == "high")

  let unknown = try JSONDecoder().decode(
    DailyReportConfiguration.self,
    from: Data(#"{"agentProvider":"future-provider"}"#.utf8)
  )
  #expect(unknown.agentProvider == nil)

  let roundTrip = try JSONDecoder().decode(
    DailyReportConfiguration.self,
    from: JSONEncoder().encode(pinned)
  )
  #expect(roundTrip == pinned)
}

@Test("Chat harness executables default to the managed launchers per provider")
func chatExecutableDefaults() {
  var config = AppConfiguration.eccDefault()
  config.verifier.executable = "/mock/focus-queue-codex"

  #expect(config.chatExecutable(for: .codex) == "/mock/focus-queue-codex")
  #expect(config.chatExecutable(for: .claude).hasSuffix("/.local/bin/focus-queue-claude"))
  #expect(config.chatExecutable(for: .kimi).hasSuffix("/.local/bin/focus-queue-kimi"))

  config.claudeChatExecutable = "/custom/focus-queue-claude"
  config.kimiChatExecutable = "/custom/focus-queue-kimi"
  #expect(config.chatExecutable(for: .claude) == "/custom/focus-queue-claude")
  #expect(config.chatExecutable(for: .kimi) == "/custom/focus-queue-kimi")
}
