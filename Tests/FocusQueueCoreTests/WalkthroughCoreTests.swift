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
      #expect(ProviderAccounts.loginScript(for: provider).contains("else command \(provider.executableName) "))
      #expect(ProviderAccounts.state(for: provider, result: result(127)) == .notInstalled)
    }
    #expect(ProviderAccounts.loginScript(for: .claude).contains("else command claude auth login; fq_status=$?"))
    #expect(ProviderAccounts.loginScript(for: .codex).contains("else command codex login; fq_status=$?"))
  }

  /// Runs the sign-in script against a stub CLI and returns what the window shows.
  private func runLogin(_ provider: AgentProvider, stub: String?,
                        attempt: SignInAttempt? = nil) async throws -> String {
    let bin = FileManager.default.temporaryDirectory.appendingPathComponent("login-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bin) }
    if let stub {
      let file = bin.appendingPathComponent(provider.executableName)
      try Data("#!/bin/sh\n\(stub)\n".utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    let script = "PATH=\(bin.path):/usr/bin:/bin; "
      + ProviderAccounts.loginScript(for: provider, attempt: attempt) + " </dev/null"
    let output = try await FoundationProcessRunner().run(.init(
      executable: "/bin/zsh", arguments: ["-fc", script], timeoutSeconds: 15))
    return output.standardOutput
  }

  @Test("The sign-in window reports success, failure, or a missing CLI instead of always saying finished")
  func loginOutcome() async throws {
    let succeeded = try await runLogin(.codex, stub: "exit 0")
    #expect(succeeded.contains("Signed in to Codex. This window closes in a moment."))
    #expect(!succeeded.contains("Press Return"), "A successful window closes by itself")
    let failed = try await runLogin(.codex, stub: "exit 3")
    #expect(failed.contains("did not finish (exit 3)"))
    #expect(failed.contains("Press Return"))
    #expect(!failed.contains("Signed in"))
    #expect(try await runLogin(.claude, stub: nil).contains("The claude CLI is not installed"))
  }

  @Test("A sign-in window records its exit status and the CLI's errors for the app")
  func loginRecordsOutcome() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("attempt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let failure = try SignInAttempt(provider: .codex, root: root)
    #expect(failure.outcome() == nil, "Still running")
    _ = try await runLogin(.codex, stub: "echo 'Error: token exchange failed' >&2; exit 4", attempt: failure)
    #expect(failure.outcome() == .failed(status: 4, errors: "Error: token exchange failed"))
    let success = try SignInAttempt(provider: .claude, root: root)
    _ = try await runLogin(.claude, stub: "exit 0", attempt: success)
    #expect(success.outcome() == .succeeded)
    success.remove()
    #expect(success.outcome() == nil)
  }

  @Test("Failure reports hide the home folder, account name, emails, and tokens")
  func reportRedaction() {
    let report = SignInFailureReport(
      provider: .codex, exitStatus: 1,
      errors: "open /Users/divi/.codex/auth.json failed for divi@example.com token=abcdefghijklmnopqrstuvwxyz0123456789ABCD",
      accountState: "Could not check: /Users/divi/.zshrc", cliPath: "/Users/divi/.npm/bin/codex",
      cliVersion: "codex-cli 0.145.0", terminal: "macOS Terminal", environment: "Focus Queue 0.3.2 · macOS 26.1.0",
      home: "/Users/divi")
    #expect(report.title == "Sign-in failed: Codex (exit 1)")
    #expect(!report.body.contains("/Users/divi"))
    #expect(!report.body.contains("divi@example.com"))
    #expect(!report.body.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
    #expect(report.body.contains("~/.codex/auth.json"))
    #expect(report.body.contains("codex-cli 0.145.0"))
  }

  @Test("Reports go through a signed-in GitHub CLI, else open a prefilled issue page")
  func reportDelivery() async throws {
    let report = SignInFailureReport(provider: .claude, exitStatus: 2, errors: "boom", accountState: "Not signed in",
      cliPath: nil, cliVersion: nil, terminal: "Ghostty", environment: "test", home: "/Users/x")
    let filed = await SignInFailureReporter.submit(report, gh: "/mock/gh", runner: ScriptedRunner([
      .init(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
      .init(exitCode: 0, standardOutput: "https://github.com/haelyra/FocusQueue/issues/12\n", standardError: "", timedOut: false),
    ]))
    #expect(filed == .filed(URL(string: "https://github.com/haelyra/FocusQueue/issues/12")!))
    let signedOut = await SignInFailureReporter.submit(report, gh: "/mock/gh", runner: ScriptedRunner([
      .init(exitCode: 1, standardOutput: "", standardError: "not logged in", timedOut: false),
    ]))
    guard case .openInBrowser(let page) = signedOut else { Issue.record("Expected a browser page"); return }
    #expect(page.absoluteString.hasPrefix("https://github.com/haelyra/FocusQueue/issues/new?"))
    #expect(page.absoluteString.contains("Sign-in%20failed:%20Claude"))
    #expect(await SignInFailureReporter.submit(report, gh: nil, runner: ScriptedRunner([])) == signedOut)
  }

  @Test("A failed check shows the CLI's own last line, from stdout when stderr is empty")
  func failureDetail() {
    #expect(ProviderAccounts.state(for: .kimi, result: result(2, "loading\nError: config unreadable\n"))
      == .failed("Error: config unreadable (exit 2)"))
    #expect(ProviderAccounts.state(for: .kimi, result: result(2)) == .failed("Exit status 2."))
  }

  @Test("The queue stays gated until one provider is signed in")
  func gate() {
    var states: [AgentProvider: ProviderAccountState] = [.claude: .signedOut, .codex: .notInstalled]
    #expect(!ProviderAccounts.signInRequired(states), "Kimi has not been checked yet")
    states[.kimi] = .checking
    #expect(!ProviderAccounts.signInRequired(states))
    states[.kimi] = .signedOut
    #expect(ProviderAccounts.signInRequired(states))
    #expect(!ProviderAccounts.canContinueUnverified(states))
    states[.kimi] = .failed("The status check timed out.")
    #expect(ProviderAccounts.signInRequired(states))
    #expect(ProviderAccounts.canContinueUnverified(states))
    states[.codex] = .signedIn
    #expect(!ProviderAccounts.signInRequired(states))
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

  @Test("WezTerm starts a fresh process with the managed config that loads the user's own")
  func wezTermArguments() async throws {
    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent("fq-terminal-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: support) }
    let runner = RecordingRunner()
    try await TerminalCommandLauncher.open(
      ["/bin/echo", "hi"], configuration: .init(executable: "/mock/wezterm"),
      supportDirectory: support, runner: runner)
    let call = try #require(await runner.calls.first)
    let configFile = WezTermManagedConfig.fileURL(supportDirectory: support)
    #expect(call.arguments == ["-na", "WezTerm", "--args", "--config-file", configFile.path,
      "start", "--always-new-process", "--", "/bin/echo", "hi"])
    let script = try String(contentsOf: configFile, encoding: .utf8)
    // The handler must be registered before the user's config loads and stop
    // later handlers, or a user gui-startup drops the attach command.
    let handler = try #require(script.range(of: "wezterm.on(\"gui-startup\""))
    let load = try #require(script.range(of: "pcall(dofile, path)"))
    #expect(handler.lowerBound < load.lowerBound)
    #expect(script.contains("wezterm.mux.spawn_window(cmd or {})"))
    #expect(script.contains("return false"))
    #expect(script.contains("os.getenv(\"FOCUS_QUEUE_WEZTERM_TAB_TITLE\")"))
  }
}

/// Returns canned results in order, so no real gh command runs.
private actor ScriptedRunner: ProcessRunning {
  private var results: [ProcessResult]
  init(_ results: [ProcessResult]) { self.results = results }
  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    results.isEmpty ? ProcessResult(exitCode: 1, standardOutput: "", standardError: "", timedOut: false)
      : results.removeFirst()
  }
}
