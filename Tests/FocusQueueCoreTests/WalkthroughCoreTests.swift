import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Walkthrough steps")
struct WalkthroughCoreTests {
  @Test("Setup cards come first and every step has copy")
  func stepsHaveCopy() {
    let steps = WalkthroughStep.allCases
    #expect(Array(steps.prefix(4)) == [.welcome, .terminal, .agents, .signIn])
    #expect(steps.last == .help)
    for step in steps {
      #expect(!step.kicker.isEmpty && !step.title.isEmpty && !step.message.isEmpty, "\(step)")
    }
    #expect(steps.filter { $0.presentation == .card }.count == 4)
    #expect(steps.filter { $0.screen == .settings } == [.project])
    // Plan and context come right after the first agent launches.
    let launch = steps.firstIndex(of: .launchAgent)!
    #expect(steps[launch + 1] == .planAndContext)
    #expect(steps[launch + 2] == .uiCanvas)
  }

  @Test("A goal is met only by progress made after its step began")
  func goals() {
    var progress = WalkthroughProgress(step: .project, baseline: .init(projectCount: 1))
    #expect(!progress.isGoalMet(.init(projectCount: 1)))
    #expect(progress.isGoalMet(.init(projectCount: 2)))
    let advanced = progress.next(.init(projectCount: 2, agentCount: 3))
    #expect(advanced)
    #expect(progress.step == .launchAgent)
    #expect(!progress.isGoalMet(.init(projectCount: 2, agentCount: 3)))
    #expect(progress.isGoalMet(.init(projectCount: 2, agentCount: 4)))
    let informational = WalkthroughProgress(step: .qchat)
    #expect(!informational.isGoalMet(.init(projectCount: 9, agentCount: 9, panelRestoreCount: 9)))
  }

  @Test("Back stops at the first step and Next refuses past the last")
  func bounds() {
    var progress = WalkthroughProgress()
    progress.back(.init())
    #expect(progress.isFirst && progress.position == 1)
    var last = WalkthroughProgress(step: .help)
    #expect(last.isLast && last.position == last.count)
    let advanced = last.next(.init())
    #expect(!advanced)
    #expect(last.step == .help)
  }

  @Test("Local state keeps the walkthrough completion and older state still loads")
  func localStateRoundTrip() throws {
    var state = LocalState()
    state.walkthroughCompletedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let data = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(LocalState.self, from: data).walkthroughCompletedAt == state.walkthroughCompletedAt)
    let legacy = try JSONDecoder().decode(LocalState.self, from: Data(#"{"routineDate":""}"#.utf8))
    #expect(legacy.walkthroughCompletedAt == nil)
  }

  @Test("The UI Canvas demo installs once and opens as a canvas session")
  func canvasDemo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-demo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try UICanvasDemo.install(supportDirectory: root, taskID: "foc-1")
    #expect(file.path.hasSuffix("tasks/FOC-1/walkthrough/ui-canvas-demo.html"))
    try Data("edited".utf8).write(to: file)
    _ = try UICanvasDemo.install(supportDirectory: root, taskID: "FOC-1")
    #expect(try String(contentsOf: file, encoding: .utf8) == "edited")
    try FileManager.default.removeItem(at: file)
    let fresh = try UICanvasDemo.install(supportDirectory: root, taskID: "FOC-1")
    let store = UICanvasStore(root: root)
    guard case .opened(let session) = try store.open(
      file: fresh.path, taskID: "FOC-1", title: UICanvasDemo.title, viewport: "desktop",
      reopen: true, agentName: "Demo") else {
      Issue.record("Demo canvas did not open"); return
    }
    #expect(session.title == UICanvasDemo.title)
    #expect(session.viewport == "desktop")
    #expect(store.sessions(taskID: "FOC-1").count == 1)
  }
}

@Suite("Provider accounts")
struct ProviderAccountsTests {
  private func result(_ code: Int32, _ out: String = "", _ err: String = "") -> ProcessResult {
    ProcessResult(exitCode: code, standardOutput: out, standardError: err, timedOut: false)
  }

  @Test("Status checks bypass shell wrappers and report a missing CLI")
  func scripts() {
    for provider in AgentProvider.allCases {
      let script = ProviderAccounts.statusScript(for: provider)
      #expect(script.hasPrefix("command -v \(provider.executableName) "))
      #expect(script.contains("|| exit 127; command \(provider.executableName) "))
      #expect(ProviderAccounts.loginScript(for: provider).hasPrefix("command \(provider.executableName) "))
      #expect(ProviderAccounts.state(for: provider, result: result(127)) == .notInstalled)
    }
    #expect(ProviderAccounts.loginScript(for: .claude).hasPrefix("command claude auth login;"))
    #expect(ProviderAccounts.loginScript(for: .codex).hasPrefix("command codex login;"))
  }

  @Test("Claude reads loggedIn from auth status even with profile noise")
  func claude() {
    let noise = "Welcome back!\n"
    #expect(ProviderAccounts.state(for: .claude, result: result(0, noise + #"{"loggedIn": true, "authMethod": "claude.ai"}"#)) == .signedIn)
    #expect(ProviderAccounts.state(for: .claude, result: result(1, #"{"loggedIn":false}"#)) == .signedOut)
  }

  @Test("Codex uses the login status exit code")
  func codex() {
    #expect(ProviderAccounts.state(for: .codex, result: result(0, "", "Logged in using ChatGPT")) == .signedIn)
    #expect(ProviderAccounts.state(for: .codex, result: result(1, "", "Not logged in")) == .signedOut)
  }

  @Test("Kimi counts a configured Kimi provider as signed in")
  func kimi() {
    let listed = "managed:kimi-code  type=kimi  models=6  source=oauth\n\nDefault model: kimi-code/kimi-for-coding"
    #expect(ProviderAccounts.state(for: .kimi, result: result(0, listed)) == .signedIn)
    #expect(ProviderAccounts.state(for: .kimi, result: result(0, "No providers configured.")) == .signedOut)
  }

  @Test("A timeout is reported as a failed check")
  func timeout() {
    let timedOut = ProcessResult(exitCode: 15, standardOutput: "", standardError: "", timedOut: true)
    #expect(ProviderAccounts.state(for: .claude, result: timedOut) == .failed("The status check timed out."))
  }
}

private actor RecordingRunner: ProcessRunning {
  private(set) var calls: [ProcessSpecification] = []
  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    calls.append(specification)
    return ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
  }
}

@Suite("Managed terminals")
struct ManagedTerminalAppTests {
  @Test("Names map to terminals, and unknown names keep the WezTerm path")
  func names() {
    #expect(ManagedTerminalApp(applicationName: "ghostty") == .ghostty)
    #expect(ManagedTerminalApp(applicationName: "Terminal") == .terminal)
    #expect(ManagedTerminalApp(applicationName: "Something") == .wezTerm)
    #expect(!ManagedTerminalApp.wezTerm.requiresTmux)
    #expect(ManagedTerminalApp.ghostty.requiresTmux && ManagedTerminalApp.terminal.requiresTmux)
  }

  @Test("Ghostty runs the command with -e in a new instance that quits with its window")
  func ghosttyArguments() async throws {
    let runner = RecordingRunner()
    try await TerminalCommandLauncher.open(
      ["/bin/zsh", "-lic", "command claude auth login"],
      configuration: .init(executable: "/mock/wezterm", applicationName: "Ghostty"), runner: runner)
    let call = try #require(await runner.calls.first)
    #expect(call.executable == "/usr/bin/open")
    #expect(call.arguments == ["-na", "Ghostty", "--args", "--quit-after-last-window-closed=true", "-e",
      "/bin/zsh", "-lic", "command claude auth login"])
  }

  @Test("WezTerm starts a fresh process running the command")
  func wezTermArguments() async throws {
    let runner = RecordingRunner()
    try await TerminalCommandLauncher.open(
      ["/bin/echo", "hi"], configuration: .init(executable: "/mock/wezterm"), runner: runner)
    let call = try #require(await runner.calls.first)
    #expect(call.arguments == ["-na", "WezTerm", "--args", "--skip-config", "start", "--always-new-process", "--",
      "/bin/echo", "hi"])
  }
}
