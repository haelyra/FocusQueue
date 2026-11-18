import Foundation
import Testing
@testable import FocusQueueCore

private func temporaryConfig(_ object: [String: Any]) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("claude-trust-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent(".claude.json")
  try JSONSerialization.data(withJSONObject: object).write(to: url)
  return url
}

private func projects(_ url: URL) throws -> [String: [String: Any]] {
  let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  return root["projects"] as? [String: [String: Any]] ?? [:]
}

@Test("Trusting the support directory keeps every other config value")
func claudeTrustAddsSupportDirectory() throws {
  let config = try temporaryConfig([
    "numStartups": 7, "oauthAccount": ["emailAddress": "x"],
    "projects": ["/repo": ["hasTrustDialogAccepted": false, "allowedTools": ["Bash"]]]])
  let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support/ECC Focus Queue")
  #expect(try ClaudeFolderTrust.ensureTrusted(support, configURL: config))
  let saved = try projects(config)
  #expect(saved[support.path]?["hasTrustDialogAccepted"] as? Bool == true)
  #expect(saved["/repo"]?["allowedTools"] as? [String] == ["Bash"])
  let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
  #expect(root["numStartups"] as? Int == 7)
  #expect((root["oauthAccount"] as? [String: String])?["emailAddress"] == "x")
  #expect(try !ClaudeFolderTrust.ensureTrusted(support, configURL: config), "A second launch writes nothing")
}

@Test("A trusted ancestor already covers the support directory")
func claudeTrustSkipsTrustedAncestor() throws {
  let config = try temporaryConfig(["projects": ["/Users/someone": ["hasTrustDialogAccepted": true]]])
  let before = try Data(contentsOf: config)
  #expect(try !ClaudeFolderTrust.ensureTrusted(
    URL(fileURLWithPath: "/Users/someone/Library/Application Support/ECC Focus Queue"), configURL: config))
  #expect(try Data(contentsOf: config) == before)
}

@Test("A missing Claude config is left for Claude's own first run")
func claudeTrustIgnoresMissingConfig() throws {
  let missing = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).json")
  #expect(try !ClaudeFolderTrust.ensureTrusted(URL(fileURLWithPath: "/tmp/fq"), configURL: missing))
  #expect(!FileManager.default.fileExists(atPath: missing.path))
}

@Test("CLAUDE_CONFIG_DIR moves the Claude config")
func claudeTrustHonorsConfigDirectory() {
  #expect(ClaudeFolderTrust.configURL(environment: ["CLAUDE_CONFIG_DIR": "/alt"], home: URL(fileURLWithPath: "/h")).path
    == "/alt/.claude.json")
  #expect(ClaudeFolderTrust.configURL(environment: [:], home: URL(fileURLWithPath: "/h")).path == "/h/.claude.json")
}

@Test("A managed Claude launch trusts the support directory before the pane starts")
func claudeTrustRunsOnManagedClaudeLaunch() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-trust-launch-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let config = try temporaryConfig(["projects": [:]])
  let support = root.appendingPathComponent("support")
  let context = TaskContext(
    ticketID: "ECC-1", title: "Launch", summary: "", successCriteria: "Checks pass",
    planPath: root.appendingPathComponent("plan.md").path, worktreePath: root.path, updatedAt: Date())
  let subtask = TaskSubtask(id: "implement", title: "Implement", provider: .claude)
  let server = "claude-trust-" + UUID().uuidString.lowercased()
  defer { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-launches-\(server)", isDirectory: true)) }
  _ = try? await TaskAgentLauncher(runner: TaskPaneLaunchRunner(), tmuxServerName: server, claudeConfigURL: config)
    .startManagedSession(context: context, subtask: subtask, supportDirectory: support, tmuxExecutable: "/test/tmux")
  let key = support.resolvingSymlinksInPath().standardizedFileURL.path
  #expect(try projects(config)[key]?["hasTrustDialogAccepted"] as? Bool == true)
}
