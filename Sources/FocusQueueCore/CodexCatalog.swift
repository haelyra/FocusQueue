import Foundation

/// What the installed Codex CLI offers the signed-in account. Both parts vary
/// with the CLI version and the plan, so the built-in model list alone can offer
/// a model that then fails.
public struct CodexCatalog: Equatable, Sendable {
  /// Slugs Codex lists for this account. Empty means the list could not be read.
  public var models: [String]
  public var supportsNoDaemon: Bool

  /// The harness prints this line when Codex refuses the chosen model.
  public static let unavailableMarker = "focus-queue-model-unavailable:"
  static let helpMarker = "<<focus-queue-codex-help>>"
  private static let builtInModels = Set(
    AppConfiguration.defaultAgentModelChoices.filter { $0.provider == .codex }.compactMap(\.model))

  public init(models: [String], supportsNoDaemon: Bool = true) {
    self.models = models
    self.supportsNoDaemon = supportsNoDaemon
  }

  /// `command` skips aliases and functions; a wrapper's flags must not reach these.
  static let script = "command -v codex >/dev/null 2>&1 || exit 127; command codex debug models; "
    + "printf '\\n%s\\n' '\(helpMarker)'; command codex --help"

  public static func load(
    runner: any ProcessRunning = FoundationProcessRunner(),
    shell: String = InteractiveAgentShell.executable()
  ) async -> CodexCatalog? {
    // The catalog carries each model's full instructions, about 650 KB today.
    guard let result = try? await runner.run(ProcessSpecification(
      executable: shell, arguments: ["-lic", script], timeoutSeconds: 20,
      maximumOutputBytes: 8_000_000)), result.succeeded else { return nil }
    return parse(result.standardOutput)
  }

  /// Interactive shells may print profile noise, so the JSON is searched for.
  static func parse(_ output: String) -> CodexCatalog? {
    let parts = output.components(separatedBy: helpMarker)
    guard parts.count == 2, parts[1].contains("Usage") else { return nil }
    var models: [String] = []
    if let start = parts[0].range(of: "{\"models\""), let end = parts[0].range(of: "}", options: .backwards),
       start.lowerBound < end.upperBound,
       let document = try? JSONSerialization.jsonObject(with: Data(parts[0][start.lowerBound..<end.upperBound].utf8)),
       let entries = (document as? [String: Any])?["models"] as? [[String: Any]] {
      models = entries.compactMap { entry in
        (entry["visibility"] as? String ?? "list") == "list" ? entry["slug"] as? String : nil
      }
    }
    return CodexCatalog(models: models, supportsNoDaemon: parts[1].contains("--no-daemon"))
  }

  /// False only for a built-in choice this account does not list. A model the
  /// user added by hand stays, and the chat harness copes if Codex refuses it.
  public func offers(_ model: String) -> Bool {
    models.isEmpty || models.contains(model) || !Self.builtInModels.contains(model)
  }

  /// The picker's Codex entries: choices this account offers, then any model it
  /// lists that the built-in list has not caught up with.
  public func choices(from configured: [AgentModelChoice]) -> [AgentModelChoice] {
    let kept = configured.filter { $0.model.map(offers) ?? false }
    let known = Set(kept.compactMap(\.model))
    return kept + models.filter { !known.contains($0) }.map {
      AgentModelChoice(provider: .codex, label: $0, model: $0)
    }
  }

  public static func unavailableModel(in log: String) -> String? {
    log.split(whereSeparator: \.isNewline).last { $0.hasPrefix(unavailableMarker) }
      .map { $0.dropFirst(unavailableMarker.count).trimmingCharacters(in: .whitespaces) }
  }
}
