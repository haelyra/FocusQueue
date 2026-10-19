import Foundation

/// One plugin installed for a provider CLI, with its saved enablement.
public struct ProviderPlugin: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var enabled: Bool

  public init(id: String, name: String, enabled: Bool) {
    self.id = id
    self.name = name
    self.enabled = enabled
  }

  /// The ECC plugin leads the list because the task creator offers it first.
  public var isECC: Bool { name.caseInsensitiveCompare("ecc") == .orderedSame }
}

/// Reads installed plugins from each provider's own files. It never runs the
/// provider and never writes its settings; launches toggle plugins per agent
/// through `AgentProvider.pluginArguments(overrides:)`.
public enum ProviderPluginCatalog {
  public static func installed(
    for provider: AgentProvider,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [ProviderPlugin] {
    let plugins: [ProviderPlugin]
    switch provider {
    case .claude: plugins = claudePlugins(home: home)
    case .codex: plugins = codexPlugins(home: home)
    case .kimi: plugins = []
    }
    return plugins.sorted {
      $0.isECC != $1.isECC ? $0.isECC : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  /// `installed_plugins.json` lists installs; `settings.json` `enabledPlugins`
  /// holds the user's saved choice, and an unlisted install is off.
  static func claudePlugins(home: URL) -> [ProviderPlugin] {
    let directory = home.appendingPathComponent(".claude")
    guard let installed = jsonObject(directory.appendingPathComponent("plugins/installed_plugins.json")),
          let ids = (installed["plugins"] as? [String: Any])?.keys else { return [] }
    let enabled = jsonObject(directory.appendingPathComponent("settings.json"))?["enabledPlugins"]
      as? [String: Bool] ?? [:]
    return ids.map { ProviderPlugin(id: $0, name: displayName($0), enabled: enabled[$0] ?? false) }
  }

  /// Codex keeps each install as a `[plugins."id"]` table whose `enabled`
  /// defaults to true.
  static func codexPlugins(home: URL) -> [ProviderPlugin] {
    guard let text = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
    else { return [] }
    var plugins: [ProviderPlugin] = []
    var current: String?
    var currentEnabled = true
    func flush() {
      if let current { plugins.append(ProviderPlugin(id: current, name: displayName(current), enabled: currentEnabled)) }
    }
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        flush()
        current = codexPluginID(header: line)
        currentEnabled = true
      } else if current != nil, line.hasPrefix("enabled") {
        let value = line.split(separator: "=", maxSplits: 1).last?
          .trimmingCharacters(in: .whitespaces).split(separator: "#").first?
          .trimmingCharacters(in: .whitespaces)
        currentEnabled = value != "false"
      }
    }
    flush()
    return plugins
  }

  private static func codexPluginID(header: String) -> String? {
    guard header.hasPrefix("[plugins."), header.hasSuffix("]"), !header.hasPrefix("[[") else { return nil }
    var id = String(header.dropFirst("[plugins.".count).dropLast())
    if id.hasPrefix("\""), id.hasSuffix("\""), id.count >= 2 { id = String(id.dropFirst().dropLast()) }
    return id.isEmpty || id.contains(".") ? nil : id
  }

  /// `ecc@ecc` reads as `ecc`; the marketplace stays in the ID.
  private static func displayName(_ id: String) -> String {
    String(id.split(separator: "@", maxSplits: 1).first ?? Substring(id))
  }

  private static func jsonObject(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url), data.count <= 4_194_304 else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
