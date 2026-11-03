import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Prompt extraction routing")
struct PromptExtractionTests {
  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("prompt-extraction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test("Two hooks reporting the same prompt claim it once; a new prompt or session claims again")
  func claimOnce() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "0F8FAD5B-D9CB-469F-A165-70867728950E"
    #expect(PromptExtraction.claim(provider: "claude", sessionID: session, prompt: "Add a puffer fish", root: root))
    #expect(!PromptExtraction.claim(provider: "claude", sessionID: session.lowercased(), prompt: "Add a puffer fish", root: root))
    #expect(PromptExtraction.claim(provider: "claude", sessionID: session, prompt: "Start with a heart", root: root))
    #expect(PromptExtraction.claim(provider: "claude", sessionID: UUID().uuidString, prompt: "Add a puffer fish", root: root))
  }

  @Test("Day-old claims are pruned so a long-lived support folder stays small")
  func pruneOldClaims() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(PromptExtraction.claim(provider: "claude", sessionID: nil, prompt: "old", root: root))
    let later = Date().addingTimeInterval(2 * 86_400)
    #expect(PromptExtraction.claim(provider: "claude", sessionID: nil, prompt: "new", root: root, now: later))
    let claims = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("extraction-claims").path)
    #expect(claims.count == 1)
  }

  @Test("The agent's project comes from its capsule, else the dashboard that owns its open task")
  func projectIdentity() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dashboard = root.appendingPathComponent("recipes.json")
    try Data(#"{"tickets":[{"id":"RCP-005","title":"Print button","status":"backlog","priority":"medium"}]}"#.utf8)
      .write(to: dashboard)
    var configuration = SetupEnvironment.starter(supportDirectory: root)
    configuration.projects.append(ProjectConfiguration(
      id: "recipe-box", name: "Recipe Box", dashboardPath: dashboard.path, workspacePath: root.path))
    let capsule = root.appendingPathComponent("capsule.json")
    try Data(#"{"projectID":"recipe-box","taskID":"RCP-005"}"#.utf8).write(to: capsule)

    #expect(PromptExtraction.projectID(environment: ["FOCUS_QUEUE_AGENT_CONTEXT": capsule.path],
                                       taskID: nil, configuration: configuration, root: root) == "recipe-box")
    #expect(PromptExtraction.projectID(environment: [:], taskID: "rcp-005",
                                       configuration: configuration, root: root) == "recipe-box")
    #expect(PromptExtraction.projectID(environment: [:], taskID: "RCP-404",
                                       configuration: configuration, root: root) == nil)
    try Data(#"{"projectID":"archived-or-unknown"}"#.utf8).write(to: capsule)
    #expect(PromptExtraction.projectID(environment: ["FOCUS_QUEUE_AGENT_CONTEXT": capsule.path],
                                       taskID: "RCP-005", configuration: configuration, root: root) == "recipe-box")
  }
}
