import Foundation
import Testing

@testable import FocusQueueCore

@Suite("Built-in agent contracts")
struct BuiltInAgentContractTests {
  /// The repository's Config folder, which the app bundles as its resources.
  static let config = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Config", isDirectory: true)

  @Test("Each contract is written in full under contracts/built-in, with a note on where agents get it")
  func writesFullCopies() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("built-in \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let written = BuiltInAgentContract.writeAll(root: root, resources: Self.config)
    #expect(Set(written.keys) == Set(BuiltInAgentContract.allCases))
    for contract in BuiltInAgentContract.allCases {
      let url = try #require(written[contract])
      #expect(url == contract.url(root: root))
      #expect(url.deletingLastPathComponent().path.hasSuffix("contracts/built-in"))
      let copy = try String(contentsOf: url, encoding: .utf8)
      #expect(copy.hasPrefix("> \(contract.delivery)"))
      if let resource = contract.resourceName {
        // The whole bundled payload, markers included, follows the note.
        let payload = try String(contentsOf: Self.config.appendingPathComponent(resource), encoding: .utf8)
        #expect(copy.hasSuffix(payload))
        #expect(copy.contains("Record every divergence before acting on it."))
      } else {
        #expect(copy.contains(FocusQueueOrchestratorRules.text))
      }
    }
  }

  @Test("Without bundled payloads only the orchestrator rules are available")
  func developmentBuildHasOnlyOrchestratorRules() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("built-in \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(BuiltInAgentContract.orchestrator.isAvailable(resources: nil))
    #expect(!BuiltInAgentContract.claude.isAvailable(resources: nil))
    #expect(!BuiltInAgentContract.codex.isAvailable(resources: root))
    #expect(try BuiltInAgentContract.claude.write(root: root, resources: nil) == nil)
    #expect(Set(BuiltInAgentContract.writeAll(root: root, resources: nil).keys) == [.orchestrator])
  }

  @Test("An unchanged copy is not rewritten; a changed payload refreshes it")
  func refreshesOnlyOnChange() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("built-in \(UUID().uuidString)")
    let resources = root.appendingPathComponent("resources", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let payload = resources.appendingPathComponent("CLAUDE_GLOBAL_INSTRUCTIONS.md")
    try "- First rule.\n".write(to: payload, atomically: true, encoding: .utf8)

    let url = try #require(try BuiltInAgentContract.claude.write(root: root, resources: resources))
    let stamp = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
    try BuiltInAgentContract.claude.write(root: root, resources: resources)
    let unchanged = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    #expect(unchanged == stamp)

    try "- Second rule.\n".write(to: payload, atomically: true, encoding: .utf8)
    try BuiltInAgentContract.claude.write(root: root, resources: resources)
    #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix("- Second rule.\n"))
  }
}
