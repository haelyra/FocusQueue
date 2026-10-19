import Foundation
import Testing
import FocusQueueCore
@testable import ECCFocusQueue

@Suite("Task creator placement")
struct TaskCreatorTests {
  private static let script = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Scripts/focus_queue_placement.py")

  @Test("The app runs the shared placement script and reads its title, summary, and priority")
  func scriptSuggesterEndToEnd() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("creator-script-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let support = root.appendingPathComponent("support")
    let repository = root.appendingPathComponent("repo")
    let bin = home.appendingPathComponent(".local/bin")
    for directory in [bin, support, repository] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let dashboard = root.appendingPathComponent("dashboard.json")
    try Data(#"{"tickets":[{"id":"FOC-001","title":"Fix clipboard sync","status":"backlog"}]}"#.utf8)
      .write(to: dashboard)
    try JSONSerialization.data(withJSONObject: ["focusQueueProjects": [[
      "id": "focus", "name": "Focus", "taskPrefix": "FOC",
      "repositoryPath": repository.path, "dashboardPath": dashboard.path,
    ]]]).write(to: support.appendingPathComponent("config.json"))
    // The provider CLI is found the way setup discovery finds it: ~/.local/bin.
    let claude = bin.appendingPathComponent("claude")
    try Data("""
      #!/usr/bin/python3
      import json, sys
      sys.stdin.read()
      print(json.dumps({"is_error": False, "structured_output": {
          "taskID": None, "confidence": 0, "title": "Export reports to Obsidian", "reason": "new",
          "summary": "Send the daily report to Obsidian.", "priority": "high"}}))
      """.utf8).write(to: claude)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

    let suggester = ScriptTaskPlacementSuggester(supportDirectory: support, script: Self.script, home: home)
    let suggestion = await suggester.suggest(TaskPlacementQuery(
      description: "Export the daily report into Obsidian", provider: .claude, cwd: repository.path))

    #expect(suggestion.modelError == nil)
    #expect(suggestion.status == "new-task")
    #expect(suggestion.title == "Export reports to Obsidian")
    #expect(suggestion.summary == "Send the daily report to Obsidian.")
    #expect(suggestion.priority == "high")
    #expect(suggestion.model == "claude/haiku")
    #expect(suggestion.matchedTaskID == nil)
    let ledger = support.appendingPathComponent("placement-ledger.sqlite")
    #expect(FileManager.default.fileExists(atPath: ledger.path), "The app's calls land in the same ledger as fq")
  }

  @Test("A missing script or unreadable output is reported, never thrown")
  func scriptSuggesterFailures() async throws {
    let missing = ScriptTaskPlacementSuggester(
      supportDirectory: URL(fileURLWithPath: "/nonexistent-support"),
      script: URL(fileURLWithPath: "/nonexistent/focus_queue_placement.py"))
    let result = await missing.suggest(TaskPlacementQuery(description: "x", provider: .codex, cwd: "/tmp"))
    #expect(result.status == "unavailable")
    #expect(result.modelError?.contains("not installed") == true)
    #expect(ScriptTaskPlacementSuggester.parse("not json").status == "unavailable")
    let match = ScriptTaskPlacementSuggester.parse(
      #"{"status":"task","taskID":"FOC-018","confidence":0.9,"title":"t","backend":"model"}"#)
    #expect(match.matchedTaskID == "FOC-018")
  }

  @Test("The placement environment names each provider CLI and drops inherited queue identity")
  func scriptSuggesterEnvironment() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("creator-env-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let kimi = home.appendingPathComponent(".kimi-code/bin/kimi")
    try FileManager.default.createDirectory(at: kimi.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: kimi)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kimi.path)
    let environment = ScriptTaskPlacementSuggester.environment(
      supportDirectory: URL(fileURLWithPath: "/support"), home: home)
    #expect(environment["FOCUS_QUEUE_SUPPORT_DIR"] == "/support")
    #expect(environment["FOCUS_QUEUE_PLACEMENT_KIMI_EXECUTABLE"] == kimi.path)
    #expect(environment["PATH"]?.hasPrefix("\(home.path)/.local/bin:") == true)
    #expect(environment.keys.filter { $0.hasPrefix("FOCUS_QUEUE_") }.allSatisfy {
      $0 == "FOCUS_QUEUE_SUPPORT_DIR" || $0.hasPrefix("FOCUS_QUEUE_PLACEMENT_")
    })
  }
}
