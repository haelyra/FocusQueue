import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Built-in agent prompts")
struct BuiltInAgentPromptTests {
  static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  @Test("Every catalog entry produces a complete readable copy from real sources")
  func fullCatalog() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let written = BuiltInAgentPrompt.writeAll(root: root, resources: Self.repository)
    #expect(written.count == BuiltInAgentPrompt.allCases.count)
    for prompt in BuiltInAgentPrompt.allCases {
      #expect(prompt.isAvailable(resources: Self.repository))
      let url = try #require(written[prompt])
      let text = try String(contentsOf: url, encoding: .utf8)
      #expect(text.contains(prompt.delivery))
      #expect(text.contains("# \(prompt.title)"))
      #expect(BuiltInAgentPrompt.isReadOnlyCopy(url, root: root))
    }
    let steward = try #require(BuiltInAgentPrompt.developmentSteward.text(resources: Self.repository))
    #expect(steward.contains("Never accept a step; a human does that."))
    #expect(steward.contains("You keep a project's development-process tracker"))
    let placement = try #require(BuiltInAgentPrompt.taskPlacement.text(resources: Self.repository))
    #expect(placement.contains("You place a newly launched coding agent"))
    let queue = try #require(BuiltInAgentPrompt.queueAgent.text(resources: nil))
    #expect(queue.contains("You are the <the chat's provider> Queue agent"))
    #expect(queue.contains("matching connector evidence contract"))
    #expect(!BuiltInAgentPrompt.isReadOnlyCopy(root.appendingPathComponent("agent-contract.md"), root: root))
  }

  @Test("Installed resources find shell placement and automation extraction, with stale copies unavailable")
  func installedLayout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for (folder, script) in [("shell", "focus_queue_placement.py"), ("automation/Scripts", "focus_queue_extractor.py"), ("automation/Scripts", "focus_queue_morning.py"), ("automation/Scripts", "focus_queue_claude.py"), ("automation/Scripts", "focus_queue_kimi.py")] {
      let directory = root.appendingPathComponent(folder)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: Self.repository.appendingPathComponent("Scripts/\(script)"), to: directory.appendingPathComponent(script))
    }
    for prompt in [BuiltInAgentPrompt.taskPlacement, .developmentSteward, .dataExtraction, .dailyClassification, .dailyAnalysis, .claudeEditor, .kimiProfiles] {
      #expect(prompt.text(resources: root) == prompt.text(resources: Self.repository))
      #expect(!prompt.isAvailable(resources: nil))
    }
    let script = root.appendingPathComponent("shell/focus_queue_placement.py")
    try "# no prompt constants\n".write(to: script, atomically: true, encoding: .utf8)
    #expect(!BuiltInAgentPrompt.taskPlacement.isAvailable(resources: root))
    #expect(try BuiltInAgentPrompt.taskPlacement.write(root: root, resources: root) == nil)
  }
}
