import Foundation

/// The starter `ingestion.json` written at first-run setup. It holds only what
/// a report run needs to start (dashboard and agent helper) and leaves every
/// platform setting blank, so connector diagnostics list each source's next
/// step instead of failing on a missing file.
public enum IngestionStarter {
  public static let fileName = "ingestion.json"

  public static func configuration(dashboardPath: String, homeDirectory: URL) -> [String: Any] {
    [
      "dashboardPath": dashboardPath,
      "dashboardDirectory": URL(fileURLWithPath: dashboardPath).deletingLastPathComponent().path,
      // Other report agents resolve as siblings, such as focus-queue-claude.
      "agentExecutable": homeDirectory.appendingPathComponent(".local/bin/focus-queue-codex").path,
      "emailProvider": "apple_mail",
      "emailAddress": "",
      "discordGuildId": "",
      "githubRepositories": [String](),
    ]
  }

  /// Writes the starter file owner-only unless one already exists. Returns
  /// true when it wrote the file; an existing file is never touched.
  @discardableResult
  public static func writeIfMissing(
    supportDirectory: URL, dashboardPath: String,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> Bool {
    let url = supportDirectory.appendingPathComponent(fileName)
    guard !FileManager.default.fileExists(atPath: url.path),
      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    else { return false }
    try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let data = try JSONSerialization.data(
      withJSONObject: configuration(dashboardPath: dashboardPath, homeDirectory: homeDirectory),
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    do {
      try data.write(to: url, options: .withoutOverwriting)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      return false
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return true
  }
}
