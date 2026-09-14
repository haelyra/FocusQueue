import Foundation
import Testing

@testable import ECCFocusQueue

@Test("Agent launch diagnostics persist complete structured phases")
func agentLaunchDiagnosticsPersist() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "agent-launch-log-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let logger = AgentLaunchLogger(supportDirectory: root)
  let subtaskID = "worker-1"
  for (phase, outcome) in [("tmux-create", "started"), ("tmux-confirm", "succeeded")] {
    try await logger.record(AgentLaunchLogEvent(
      timestamp: Date(), taskID: "ECC-1", subtaskID: subtaskID,
      provider: "codex", runtime: "tmux", phase: phase, outcome: outcome,
      message: "Concrete diagnostic", details: ["panePID": "123"]))
  }

  let url = logger.url(subtaskID: subtaskID)
  let lines = try String(contentsOf: url, encoding: .utf8)
    .split(separator: "\n").map(String.init)
  #expect(lines.count == 2)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let events = try lines.map {
    try decoder.decode(AgentLaunchLogEvent.self, from: Data($0.utf8))
  }
  #expect(events.map(\.phase) == ["tmux-create", "tmux-confirm"])
  #expect(events.map(\.outcome) == ["started", "succeeded"])
  #expect(events.allSatisfy { $0.taskID == "ECC-1" && $0.details["panePID"] == "123" })
  let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
    as? NSNumber
  #expect(permissions?.intValue == 0o600)
}
