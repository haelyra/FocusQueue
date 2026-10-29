import Foundation

public enum ProjectGitHubError: Error, LocalizedError, Equatable, Sendable {
  case cliMissing, signInRequired, repositoryExists(String), checkFailed(String)

  public var errorDescription: String? {
    switch self {
    case .cliMissing: "Install GitHub CLI, then sign in with gh auth login --hostname github.com."
    case .signInRequired: "GitHub sign-in required. Run gh auth login --hostname github.com, then check again."
    case .repositoryExists(let name): "The GitHub repository \(name) already exists. Use its URL or choose another name."
    case .checkFailed(let reason): "Could not check GitHub: \(reason)"
    }
  }
}

public struct ProjectGitHubRepositoryCheck: Equatable, Sendable {
  public let fullName: String
  public let isAvailable: Bool
  public var url: String { "https://github.com/\(fullName)" }
}

public extension ProjectSetupService {
  /// Returns only the active login. The command never outputs the authentication token.
  func githubAccount(at directory: String) async throws -> String {
    guard let gh = githubExecutable else { throw ProjectGitHubError.cliMissing }
    let result = try await runner.run(.init(executable: gh,
      arguments: ["auth", "status", "--active", "--hostname", "github.com", "--json", "hosts", "--jq",
        "(.hosts[\"github.com\"] // []) | map(select(.active) | {login,state,error}) | .[0] // {}"],
      workingDirectory: directory, environment: ["GH_PROMPT_DISABLED": "1", "GH_HOST": "github.com"], timeoutSeconds: 15))
    if result.timedOut { throw ProjectGitHubError.checkFailed("The sign-in check timed out. Check your connection and retry.") }
    struct Account: Decodable { let login: String?; let state: String?; let error: String? }
    let account = try? JSONDecoder().decode(Account.self, from: Data(result.standardOutput.utf8))
    if result.succeeded, let account, account.state == "success", let login = account.login,
       login.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil { return login }
    let detail = account?.error ?? result.standardError
    if ["timeout", "timed out", "connect", "resolve", "network"].contains(where: { detail.localizedCaseInsensitiveContains($0) }) {
      throw ProjectGitHubError.checkFailed("The sign-in check could not reach GitHub. Check your connection and retry.")
    }
    throw ProjectGitHubError.signInRequired
  }

  /// A 404 is an availability hint. Other failures never count as an available name.
  /// GitHub remains authoritative if the name is claimed after this check.
  func checkGitHubRepository(_ input: String, account: String, at directory: String) async throws -> ProjectGitHubRepositoryCheck {
    guard let gh = githubExecutable else { throw ProjectGitHubError.cliMissing }
    guard let name = Self.githubRepositoryName(input),
      account.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil else {
      throw ProjectGitHubError.checkFailed("Enter a repository name, owner/name, or a GitHub repository URL.")
    }
    let fullName = name.contains("/") ? name : "\(account)/\(name)"
    let result = try await runner.run(.init(executable: gh,
      arguments: ["api", "--hostname", "github.com", "--method", "GET", "--include", "--silent", "repos/\(fullName)"],
      workingDirectory: directory, environment: ["GH_PROMPT_DISABLED": "1", "GH_HOST": "github.com"], timeoutSeconds: 15))
    if result.timedOut { throw ProjectGitHubError.checkFailed("The repository check timed out. Check your connection and retry.") }
    let status = result.standardOutput.split(whereSeparator: \.isNewline)
      .filter { $0.hasPrefix("HTTP/") }.last?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
    if result.succeeded, status == 200 {
      return .init(fullName: fullName, isAvailable: false)
    }
    if status == 404 { return .init(fullName: fullName, isAvailable: true) }
    if status == 401 || result.exitCode == 4 { throw ProjectGitHubError.signInRequired }
    if status == 403 || status == 429 {
      throw ProjectGitHubError.checkFailed("GitHub denied the check or rate-limited this account. Verify access and retry.")
    }
    throw ProjectGitHubError.checkFailed("GitHub did not return a usable repository status. Check your connection and retry.")
  }

  static func githubRepositoryName(_ input: String) -> String? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let name: String
    if value.contains(":") || value.contains("@") || value.lowercased().hasPrefix("github.com/") {
      guard let normalized = ProjectCatalog.normalizedRemote(value), normalized.hasPrefix("github.com/") else { return nil }
      name = String(normalized.dropFirst("github.com/".count))
    } else { name = value }
    let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard (1...2).contains(parts.count), let repository = parts.last,
      repository.range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil,
      repository.contains(where: { $0.isLetter || $0.isNumber }),
      parts.count == 1 || parts[0].range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil else { return nil }
    return name
  }

  static func githubSignInCommand(at directory: String) -> String {
    let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
    return "cd \(quoted) && gh auth login --hostname github.com"
  }
}
