import Foundation

/// One sign-in window. The login script writes the CLI's exit status and a
/// copy of its errors here, so a failure can be reported with its cause.
public struct SignInAttempt: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case succeeded
    case failed(status: Int32, errors: String)
  }

  public let provider: AgentProvider
  public let statusFile: URL
  public let errorFile: URL

  public init(provider: AgentProvider, root: URL, id: UUID = UUID()) throws {
    let directory = root.appendingPathComponent("sign-in-results", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let stem = "\(provider.rawValue)-\(id.uuidString.lowercased())"
    self.provider = provider
    statusFile = directory.appendingPathComponent(stem + ".status")
    errorFile = directory.appendingPathComponent(stem + ".errors")
  }

  /// Nil while the window is still open. Errors keep their last 40 lines.
  public func outcome() -> Outcome? {
    guard let text = try? String(contentsOf: statusFile, encoding: .utf8),
          let status = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    guard status != 0 else { return .succeeded }
    let errors = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
    let tail = errors.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
    return .failed(status: status, errors: tail.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  public func remove() {
    try? FileManager.default.removeItem(at: statusFile)
    try? FileManager.default.removeItem(at: errorFile)
  }
}

/// A sign-in failure written up for the beta issue tracker. The repository is
/// public, so the text names no home folder, account, email, or token.
public struct SignInFailureReport: Equatable, Sendable {
  public let title: String
  public let body: String

  public init(provider: AgentProvider, exitStatus: Int32?, errors: String, accountState: String,
              cliPath: String?, cliVersion: String?, terminal: String, environment: String,
              home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
    let clean = { (text: String) in Self.redacted(text, home: home) }
    title = "Sign-in failed: \(provider.displayName)" + (exitStatus.map { " (exit \($0))" } ?? "")
    body = """
      Reported automatically by Focus Queue after a failed sign-in (beta diagnostics).

      - Provider: \(provider.displayName)
      - Exit status: \(exitStatus.map(String.init) ?? "n/a (the sign-in finished but the status check still fails)")
      - Status check: \(clean(accountState))
      - CLI: \(clean(cliPath ?? "not found")) \(clean(cliVersion ?? ""))
      - Terminal: \(terminal)
      - Environment: \(environment)

      Errors from the CLI (last 40 lines):
      ```
      \(clean(errors.isEmpty ? "(none)" : errors))
      ```
      """
  }

  /// Hides the home folder (and with it the account name), email addresses,
  /// and long token-like strings.
  public static func redacted(_ text: String, home: String) -> String {
    var output = home.isEmpty ? text : text.replacingOccurrences(of: home, with: "~")
    let user = URL(fileURLWithPath: home).lastPathComponent
    if user.count >= 3 { output = output.replacingOccurrences(of: user, with: "[user]") }
    for (pattern, replacement) in [
      (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
      (#"[A-Za-z0-9_\-]{32,}"#, "[redacted]"),
    ] {
      output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    return output
  }
}

/// Files a sign-in failure on the beta issue tracker: through the tester's
/// signed-in GitHub CLI when there is one, else as a prefilled issue page.
/// No token ships with the app.
public enum SignInFailureReporter {
  public static let repository = "haelyra/FocusQueue"

  public enum Delivery: Equatable, Sendable {
    case filed(URL)
    case openInBrowser(URL)
  }

  public static func submit(_ report: SignInFailureReport, gh: String?,
                            runner: any ProcessRunning = FoundationProcessRunner()) async -> Delivery {
    if let gh, let status = try? await runner.run(ProcessSpecification(
         executable: gh, arguments: ["auth", "status", "--hostname", "github.com"], timeoutSeconds: 10)),
       status.succeeded,
       let created = try? await runner.run(ProcessSpecification(
         executable: gh, arguments: ["issue", "create", "--repo", repository,
                                     "--title", report.title, "--body", report.body], timeoutSeconds: 30)),
       created.succeeded,
       let url = created.standardOutput.split(separator: "\n").last
         .flatMap({ URL(string: String($0).trimmingCharacters(in: .whitespaces)) }),
       url.scheme == "https" {
      return .filed(url)
    }
    return .openInBrowser(issuePage(report))
  }

  /// GitHub rejects very long URLs, so the body is cut to fit.
  public static func issuePage(_ report: SignInFailureReport) -> URL {
    var components = URLComponents(string: "https://github.com/\(repository)/issues/new")!
    let body = report.body.count > 6_000 ? String(report.body.prefix(6_000)) + "\n[shortened]" : report.body
    components.queryItems = [URLQueryItem(name: "title", value: report.title),
                             URLQueryItem(name: "body", value: body)]
    return components.url!
  }
}

/// What the app knows about a failed sign-in when it files the report.
public struct SignInFailureContext: Equatable, Sendable {
  public var provider: AgentProvider
  public var exitStatus: Int32?
  public var errors: String
  public var accountState: String
  public var terminal: String
  public var environment: String

  public init(provider: AgentProvider, exitStatus: Int32?, errors: String, accountState: String,
              terminal: String, environment: String) {
    self.provider = provider
    self.exitStatus = exitStatus
    self.errors = errors
    self.accountState = accountState
    self.terminal = terminal
    self.environment = environment
  }
}

extension SignInFailureReporter {
  /// Adds the CLI's path and version from the user's login shell, then submits.
  public static func file(_ context: SignInFailureContext,
                          runner: any ProcessRunning = FoundationProcessRunner(),
                          shell: String = InteractiveAgentShell.executable()) async -> Delivery {
    let name = context.provider.executableName
    let probe = try? await runner.run(ProcessSpecification(
      executable: shell, arguments: ["-lic", "command -v \(name); command \(name) --version"], timeoutSeconds: 10))
    let lines = (probe?.standardOutput ?? "").split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    let path = lines.first { $0.hasPrefix("/") }
    let version = lines.last { $0 != path }
    let report = SignInFailureReport(
      provider: context.provider, exitStatus: context.exitStatus, errors: context.errors,
      accountState: context.accountState, cliPath: path, cliVersion: version,
      terminal: context.terminal, environment: context.environment)
    return await submit(report, gh: SetupEnvironment.executable("gh"), runner: runner)
  }
}
