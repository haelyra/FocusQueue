import CryptoKit
import Foundation
import Testing

@testable import FocusQueueCore

private final class ArchitectureFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("architecture-\(UUID().uuidString)").resolvingSymlinksInPath()
  var output: URL { root.appendingPathComponent("task/architecture") }
  init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
  deinit { try? FileManager.default.removeItem(at: root) }

  @discardableResult func write(_ path: String, _ text: String) throws -> URL {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
  }

  @discardableResult func card(_ id: String, sources: [[String: String]], summary: String = "Authored explanation.") throws -> URL {
    let metadata: [String: Any] = ["id": id, "title": "Module \(id)", "sources": sources]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)
    return try write("Docs/Architecture/\(id).md", "<!-- fq-architecture: \(json) -->\n\n# Module \(id)\n\n\(summary)\n")
  }
}

@Suite("Architecture context indexing")
struct ArchitectureContextTests {
  private func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func cards(_ report: ArchitectureContextReport) throws -> [[String: Any]] {
    let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report.stateURL)) as? [String: Any])
    #expect(state["semanticVerification"] as? String == "unverified")
    return try #require(state["cards"] as? [[String: Any]])
  }

  @Test("Indexing is deterministic and marks changed sources without rewriting authored cards")
  func deterministicStaleness() throws {
    let fixture = try ArchitectureFixture()
    defer { withExtendedLifetime(fixture) {} }
    try fixture.write("Sources/Feature.swift", "struct Feature {}")
    let card = try fixture.card("feature", sources: [["path": "Sources/Feature.swift", "sha256": hash("struct Feature {}")]])
    let authored = try Data(contentsOf: card)
    let first = try ArchitectureContextService.generate(repositoryRoot: fixture.root, outputDirectory: fixture.output)
    let firstIndex = try Data(contentsOf: first.indexURL)
    let firstState = try Data(contentsOf: first.stateURL)
    #expect(try cards(first).first?["status"] as? String == "source-current")
    let second = try ArchitectureContextService.generate(repositoryRoot: fixture.root, outputDirectory: fixture.output)
    #expect(try Data(contentsOf: second.indexURL) == firstIndex)
    #expect(try Data(contentsOf: second.stateURL) == firstState)
    try fixture.write("Sources/Feature.swift", "struct Feature { let changed: Bool }")
    let changed = try ArchitectureContextService.generate(repositoryRoot: fixture.root, outputDirectory: fixture.output)
    #expect(try cards(changed).first?["status"] as? String == "stale")
    #expect(try Data(contentsOf: card) == authored)
    #expect(changed.cardURLs.count == 1)
    #expect(changed.cardURLs.first?.lastPathComponent == card.lastPathComponent)
    #expect(try Data(contentsOf: #require(changed.cardURLs.first)) == authored)
  }

  @Test("Secrets, generated and vendor files, traversal, and symlinks are excluded")
  func exclusions() throws {
    let fixture = try ArchitectureFixture()
    defer { withExtendedLifetime(fixture) {} }
    let source = try fixture.write("Sources/Real.swift", "private material")
    try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("Sources/Link.swift").path,
      withDestinationPath: source.path)
    let paths = ["Sources/Link.swift", "../outside.swift", "vendor/file.swift", ".env", "Sources/secrets.swift", "Sources/File.generated.swift"]
    for path in paths where !path.contains("Link") && !path.contains("..") { try fixture.write(path, "private material") }
    try fixture.card("excluded", sources: paths.map { ["path": $0] })
    let report = try ArchitectureContextService.generate(repositoryRoot: fixture.root, outputDirectory: fixture.output)
    let states = try #require(try cards(report).first?["sources"] as? [[String: Any]])
    #expect(states.count == paths.count)
    #expect(states.allSatisfy { $0["status"] as? String == "excluded" && $0["currentSHA256"] == nil })
    #expect(!(try String(contentsOf: report.indexURL, encoding: .utf8)).contains("private material"))
  }

  @Test("Authored output conflicts abort before writing another generated file")
  func preservesOutputConflicts() throws {
    let fixture = try ArchitectureFixture()
    defer { withExtendedLifetime(fixture) {} }
    let index = try fixture.write("task/architecture/architecture-index.generated.md", "Human authored notes")
    #expect(throws: ArchitectureContextError.self) {
      try ArchitectureContextService.generate(repositoryRoot: fixture.root, outputDirectory: fixture.output)
    }
    #expect(try String(contentsOf: index, encoding: .utf8) == "Human authored notes")
    #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("architecture-state.generated.json").path))
  }

  @Test("Missing and unbaselined sources stay explicit, and index budgets hold")
  func missingAndBudget() throws {
    let fixture = try ArchitectureFixture()
    defer { withExtendedLifetime(fixture) {} }
    try fixture.write("Sources/Empty.swift", "")
    try fixture.card("a-missing", sources: [["path": "Sources/Missing.swift"]])
    try fixture.card("b-unverified", sources: [["path": "Sources/Empty.swift"]], summary: String(repeating: "Overview ", count: 100))
    let report = try ArchitectureContextService.generate(repositoryRoot: fixture.root, outputDirectory: fixture.output,
      budget: .init(maximumIndexBytes: 1_024))
    let states = try cards(report)
    #expect(states[0]["status"] as? String == "stale")
    #expect(states[1]["status"] as? String == "unverified")
    #expect(report.truncated)
    #expect(try Data(contentsOf: report.indexURL).count <= 1_024)
  }

  @Test("A missing authored-card directory produces an honest empty index")
  func emptyScaffold() throws {
    let fixture = try ArchitectureFixture()
    defer { withExtendedLifetime(fixture) {} }
    let report = try ArchitectureContextService.generate(repositoryRoot: fixture.root, outputDirectory: fixture.output)
    #expect(report.cardCount == 0 && report.sourceCount == 0)
    #expect((try String(contentsOf: report.indexURL, encoding: .utf8)).contains("No authored cards found"))
  }

  @Test("Source read limits and reference limits leave summaries unverified")
  func sourceBudgets() throws {
    let fixture = try ArchitectureFixture()
    defer { withExtendedLifetime(fixture) {} }
    try fixture.write("Sources/Large.swift", String(repeating: "x", count: 100))
    try fixture.card("limited", sources: [["path": "Sources/Large.swift"], ["path": "Sources/Other.swift"]])
    let report = try ArchitectureContextService.generate(repositoryRoot: fixture.root, outputDirectory: fixture.output,
      budget: .init(maximumSourcesPerCard: 1, maximumSourceBytes: 16))
    let card = try #require(try cards(report).first)
    let sources = try #require(card["sources"] as? [[String: Any]])
    #expect(report.truncated && report.sourceCount == 1)
    #expect(card["status"] as? String == "unverified")
    #expect(sources.first?["currentSHA256"] == nil)
  }

  @Test("A symlinked authored-card directory is never followed")
  func rejectsCardDirectorySymlink() throws {
    let fixture = try ArchitectureFixture()
    defer { withExtendedLifetime(fixture) {} }
    try fixture.write("Elsewhere/card.md", "Authored material")
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Docs"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("Docs/Architecture").path,
      withDestinationPath: fixture.root.appendingPathComponent("Elsewhere").path)
    #expect(throws: ArchitectureContextError.self) {
      try ArchitectureContextService.generate(repositoryRoot: fixture.root, outputDirectory: fixture.output)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
  }
}
