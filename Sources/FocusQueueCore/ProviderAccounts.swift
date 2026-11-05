import Foundation

/// Whether a provider's own CLI is installed and signed in. Focus Queue never
/// holds provider credentials; agents run through these subscription CLIs.
public enum ProviderAccountState: Equatable, Sendable {
  case checking
  case signedIn
  case signedOut
  case notInstalled
  case failed(String)

  public var isSignedIn: Bool { self == .signedIn }

  public var label: String {
    switch self {
    case .checking: "Checking…"
    case .signedIn: "Signed in"
    case .signedOut: "Not signed in"
    case .notInstalled: "CLI not installed"
    case .failed: "Could not check"
    }
  }
}

public enum ProviderAccounts {
  /// `command` skips the user's aliases and shell functions, so wrappers that
  /// add launch flags (for example `--yolo`) never reach these subcommands.
  public static func statusScript(for provider: AgentProvider) -> String {
    let name = provider.executableName
    let check = switch provider {
    case .claude: "auth status"
    case .codex: "login status"
    case .kimi: "provider list"
    }
    return "command -v \(name) >/dev/null 2>&1 || exit 127; command \(name) \(check)"
  }

  /// Runs the provider's own sign-in. With an attempt, it records the exit
  /// status and a copy of the CLI's errors so the app can report a failure.
  /// A successful window closes by itself; a failed one stays open to read.
  public static func loginScript(for provider: AgentProvider, attempt: SignInAttempt? = nil) -> String {
    let name = provider.executableName
    let login = switch provider {
    case .claude: "auth login"
    case .codex, .kimi: "login"
    }
    let display = provider.displayName.replacingOccurrences(of: "'", with: "")
    let quote = TerminalCommandLauncher.shellQuote
    let errors = attempt.map { " 2> >(/usr/bin/tee \(quote($0.errorFile.path)) >&2)" } ?? ""
    let record = attempt.map { "printf '%s\\n' \"$fq_status\" > \(quote($0.statusFile.path)); " } ?? ""
    return "fq_status=0; if ! command -v \(name) >/dev/null 2>&1; then fq_status=127; "
      + "printf '\\nThe \(name) CLI is not installed. Install it, then click Sign in again in Focus Queue.\\n'; "
      + "else command \(name) \(login)\(errors); fq_status=$?; fi; "
      + record
      + "if [ \"$fq_status\" -eq 0 ]; then "
      + "printf '\\nSigned in to \(display). This window closes in a moment.\\n'; sleep 2; "
      + "else [ \"$fq_status\" -eq 127 ] || "
      + "printf '\\nSign-in to \(display) did not finish (exit %s). Focus Queue shows what went wrong.\\n' \"$fq_status\"; "
      + "printf 'Press Return to close this window.'; read _; fi"
  }

  /// Signs out through the provider's own CLI, so the sign-out applies to its
  /// terminals too. Kimi has no logout command, but its ACP server has a logout
  /// request; stdin stays open long enough for the server to finish it.
  public static func logoutScript(for provider: AgentProvider) -> String {
    let name = provider.executableName
    let logout = switch provider {
    case .claude: "command claude auth logout"
    case .codex: "command codex logout"
    case .kimi:
      "{ printf '%s\\n' "
        + "'{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{}}}' "
        + "'{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"logout\",\"params\":{}}'; "
        + "sleep 5; } | command kimi acp >/dev/null"
    }
    return "command -v \(name) >/dev/null 2>&1 || exit 127; \(logout)"
  }

  /// True once every provider's check has finished and none is signed in.
  /// No agent can run then, so the queue stays behind the sign-in screen.
  public static func signInRequired(_ states: [AgentProvider: ProviderAccountState]) -> Bool {
    AgentProvider.allCases.allSatisfy { provider in
      guard let state = states[provider] else { return false }
      return state != .checking && !state.isSignedIn
    }
  }

  /// A check that could not run (a slow shell profile, for example) proves
  /// nothing, so the user may continue past the gate on their own judgment.
  public static func canContinueUnverified(_ states: [AgentProvider: ProviderAccountState]) -> Bool {
    states.values.contains { if case .failed = $0 { true } else { false } }
  }

  public static func installURL(for provider: AgentProvider) -> URL? {
    switch provider {
    case .claude: URL(string: "https://code.claude.com/docs/en/setup")
    case .codex: URL(string: "https://github.com/openai/codex")
    case .kimi: URL(string: "https://github.com/MoonshotAI/kimi-cli")
    }
  }

  public static func subscriptionName(for provider: AgentProvider) -> String {
    switch provider {
    case .claude: "Claude Pro or Max"
    case .codex: "ChatGPT"
    case .kimi: "Kimi"
    }
  }

  /// Interpreted from the exit status first; output only refines a success.
  /// Interactive shells may print profile noise, so output is searched, not parsed whole.
  public static func state(for provider: AgentProvider, result: ProcessResult) -> ProviderAccountState {
    if result.timedOut { return .failed("The status check timed out.") }
    if result.exitCode == 127 { return .notInstalled }
    let output = result.standardOutput + "\n" + result.standardError
    switch provider {
    case .claude:
      if output.range(of: #""loggedIn"\s*:\s*true"#, options: .regularExpression) != nil { return .signedIn }
      if result.succeeded || output.range(of: #""loggedIn"\s*:\s*false"#, options: .regularExpression) != nil {
        return .signedOut
      }
    case .codex:
      if output.localizedCaseInsensitiveContains("not logged in") { return .signedOut }
      if result.succeeded { return .signedIn }
      if output.localizedCaseInsensitiveContains("logged in") == false { return .signedOut }
    case .kimi:
      if result.succeeded {
        let configured = output.split(separator: "\n").contains {
          $0.contains("source=oauth") || $0.contains("type=kimi")
        }
        return configured ? .signedIn : .signedOut
      }
    }
    return .failed(failureDetail(result))
  }

  /// Some CLIs report errors on stdout; the last line usually says what went wrong.
  private static func failureDetail(_ result: ProcessResult) -> String {
    let detail = [result.standardError, result.standardOutput].lazy
      .compactMap { $0.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
      .first.map { String($0.trimmingCharacters(in: .whitespaces).prefix(240)) }
    return detail.map { "\($0) (exit \(result.exitCode))" } ?? "Exit status \(result.exitCode)."
  }

  public static func check(
    _ provider: AgentProvider,
    runner: any ProcessRunning = FoundationProcessRunner(),
    shell: String = InteractiveAgentShell.executable()
  ) async -> ProviderAccountState {
    do {
      let result = try await runner.run(ProcessSpecification(
        executable: shell, arguments: ["-lic", statusScript(for: provider)], timeoutSeconds: 20))
      return state(for: provider, result: result)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// Returns nil when the CLI finished the sign-out, otherwise what went wrong.
  public static func signOut(
    _ provider: AgentProvider,
    runner: any ProcessRunning = FoundationProcessRunner(),
    shell: String = InteractiveAgentShell.executable()
  ) async -> String? {
    do {
      let result = try await runner.run(ProcessSpecification(
        executable: shell, arguments: ["-lic", logoutScript(for: provider)], timeoutSeconds: 30))
      return result.succeeded ? nil : failureDetail(result)
    } catch {
      return error.localizedDescription
    }
  }

  /// Opens the configured terminal on the provider's own interactive sign-in.
  public static func openSignIn(
    _ provider: AgentProvider,
    attempt: SignInAttempt? = nil,
    configuration: WezTermConfiguration,
    runner: any ProcessRunning = FoundationProcessRunner(),
    shell: String = InteractiveAgentShell.executable()
  ) async throws {
    try await TerminalCommandLauncher.open(
      [shell, "-lic", loginScript(for: provider, attempt: attempt)], configuration: configuration, runner: runner)
  }
}
