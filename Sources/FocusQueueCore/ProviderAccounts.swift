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

  public static func loginScript(for provider: AgentProvider) -> String {
    let name = provider.executableName
    let login = switch provider {
    case .claude: "auth login"
    case .codex, .kimi: "login"
    }
    return "command \(name) \(login); printf '\\nSign-in finished. Press Return to close this window.'; read _"
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
    let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    return .failed(detail.isEmpty ? "Exit status \(result.exitCode)." : String(detail.prefix(240)))
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

  /// Opens the configured terminal on the provider's own interactive sign-in.
  public static func openSignIn(
    _ provider: AgentProvider,
    configuration: WezTermConfiguration,
    runner: any ProcessRunning = FoundationProcessRunner(),
    shell: String = InteractiveAgentShell.executable()
  ) async throws {
    try await TerminalCommandLauncher.open(
      [shell, "-lic", loginScript(for: provider)], configuration: configuration, runner: runner)
  }
}
