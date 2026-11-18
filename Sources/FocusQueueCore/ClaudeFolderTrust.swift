import Foundation

/// Claude Code asks "Adding a new directory … one you trust?" for every
/// `--add-dir` folder outside a trusted tree. Each task folder under the
/// support directory is new, so every launch stopped on that prompt. Claude
/// treats a folder as trusted when it or any ancestor has
/// `hasTrustDialogAccepted` in its global config, so trusting the support
/// directory once covers every task folder. Focus Queue creates and owns that
/// directory, so the trust is the app's to grant.
public enum ClaudeFolderTrust {
  /// Claude's global config: `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`.
  public static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    if let directory = environment["CLAUDE_CONFIG_DIR"], directory.hasPrefix("/") {
      return URL(fileURLWithPath: directory).appendingPathComponent(".claude.json")
    }
    return home.appendingPathComponent(".claude.json")
  }

  /// Marks `directory` trusted unless it or an ancestor already is. Returns
  /// whether the config changed. A missing or unreadable config is left alone:
  /// Claude has not run yet, and its first-run onboarding owns that file.
  @discardableResult
  public static func ensureTrusted(_ directory: URL, configURL: URL = configURL()) throws -> Bool {
    let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
    guard path.hasPrefix("/"), let data = try? Data(contentsOf: configURL),
          var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    var projects = root["projects"] as? [String: Any] ?? [:]
    var candidate = path
    while true {
      if (projects[candidate] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true { return false }
      let parent = (candidate as NSString).deletingLastPathComponent
      if parent == candidate || parent.isEmpty { break }
      candidate = parent
    }
    var entry = projects[path] as? [String: Any] ?? [:]
    entry["hasTrustDialogAccepted"] = true
    projects[path] = entry
    root["projects"] = projects
    let output = try JSONSerialization.data(withJSONObject: root,
                                            options: [.prettyPrinted, .withoutEscapingSlashes])
    // Same-directory temp file and rename, as Claude itself writes this file,
    // so a reader never sees a partial config.
    let temporary = configURL.deletingLastPathComponent()
      .appendingPathComponent(".claude.json.focus-queue.\(UUID().uuidString)")
    try output.write(to: temporary)
    let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path)
    if let permissions = attributes?[.posixPermissions] {
      try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
    }
    guard rename(temporary.path, configURL.path) == 0 else {
      try? FileManager.default.removeItem(at: temporary)
      throw CocoaError(.fileWriteUnknown)
    }
    return true
  }
}
