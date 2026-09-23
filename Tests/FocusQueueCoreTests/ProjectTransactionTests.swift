import CryptoKit
import Foundation
import Testing

@testable import FocusQueueCore

@Suite("Recoverable project creation")
struct ProjectTransactionTests {
  @Test("Creating a project moves exact raw tasks and preserves configuration metadata")
  func createsProjectAndPreservesCanonicalData() throws {
    let fixture = try ProjectTransactionFixture()
    defer { fixture.remove() }
    _ = try QueueOrderStore(root: fixture.support, projectID: "ecc").move(
      "ECC-044", to: .top, tickets: fixture.decodedTickets,
      fallbackIDs: ["ECC-035", "ECC-044", "ECC-999"])

    let receipt = try fixture.transaction.create(fixture.request)

    #expect(receipt.sourceProjectID == "ecc")
    #expect(receipt.project.id == "focus-queue")
    #expect(receipt.movedTaskIDs == ["ECC-044", "ECC-035"])
    #expect(receipt.dashboardPath == fixture.destinationDashboard.path)

    let source = try fixture.object(at: fixture.sourceDashboard)
    let sourceTickets = try #require(source["tickets"] as? [[String: Any]])
    #expect(sourceTickets.compactMap { $0["id"] as? String } == ["ECC-999"])
    #expect((source["sourceMetadata"] as? [String: Any])?["owner"] as? String == "external")

    let destination = try fixture.object(at: fixture.destinationDashboard)
    let moved = try #require(destination["tickets"] as? [[String: Any]])
    #expect(moved.compactMap { $0["id"] as? String } == ["ECC-035", "ECC-044"])
    #expect((moved[0]["opaque"] as? [String: Any])?["keep"] as? Bool == true)
    #expect(moved[1]["worktree"] as? String == fixture.workspace.path)
    #expect(try QueueOrderStore(root: fixture.support, projectID: "focus-queue").load()
      == ["ECC-044", "ECC-035"])

    let config = try fixture.object(at: fixture.configuration)
    #expect((config["vendorMetadata"] as? [String: Any])?["revision"] as? Int == 7)
    #expect((config["projects"] as? [[String: Any]])?.first?["repositoryPath"] as? String
      == "/tmp/external-repository-catalog")
    #expect(config["selectedProjectID"] as? String == "external-selection")
    #expect(config["focusQueueSelectedProjectID"] as? String == "ecc")
    let projects = try #require(config["focusQueueProjects"] as? [[String: Any]])
    #expect(projects.compactMap { $0["id"] as? String } == ["ecc", "focus-queue"])
    #expect(try fixture.permissions(of: fixture.destinationDashboard) == 0o600)
    #expect(try fixture.permissions(of: fixture.destinationDashboard.deletingLastPathComponent())
      == 0o700)
    #expect(try fixture.permissions(
      of: QueueOrderStore(root: fixture.support, projectID: "focus-queue")
        .storageURL.deletingLastPathComponent()) == 0o700)
  }

  @Test("Invalid or ambiguous project requests leave every source byte unchanged")
  func rejectsInvalidRequestsAtomically() throws {
    for mutation in ProjectRequestMutation.allCases {
      let fixture = try ProjectTransactionFixture()
      defer { fixture.remove() }
      let originalConfig = try Data(contentsOf: fixture.configuration)
      let originalSource = try Data(contentsOf: fixture.sourceDashboard)

      #expect(throws: ProjectCreationError.self) {
        try fixture.transaction.create(mutation.apply(to: fixture.request, fixture: fixture))
      }

      #expect(try Data(contentsOf: fixture.configuration) == originalConfig)
      #expect(try Data(contentsOf: fixture.sourceDashboard) == originalSource)
      #expect(!FileManager.default.fileExists(atPath: fixture.destinationDashboard.path))
    }
  }

  @Test("A task already present in another project cannot be duplicated by a move")
  func rejectsCrossProjectDuplicateTask() throws {
    let fixture = try ProjectTransactionFixture()
    defer { fixture.remove() }
    let otherDashboard = fixture.root.appendingPathComponent("other/dashboard.json")
    try FileManager.default.createDirectory(
      at: otherDashboard.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"tickets":[{"id":"ECC-035","title":"Duplicate elsewhere","status":"open"}]}"#.utf8
    ).write(to: otherDashboard)
    var config = try fixture.object(at: fixture.configuration)
    var projects = try #require(config["focusQueueProjects"] as? [[String: Any]])
    projects.append([
      "id": "other", "name": "Other", "dashboardPath": otherDashboard.path,
      "workspacePath": otherDashboard.deletingLastPathComponent().path,
    ])
    config["focusQueueProjects"] = projects
    try JSONSerialization.data(
      withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
    ).write(to: fixture.configuration, options: .atomic)
    let originalConfig = try Data(contentsOf: fixture.configuration)
    let originalSource = try Data(contentsOf: fixture.sourceDashboard)

    #expect(throws: ProjectCreationError.self) {
      try fixture.transaction.create(fixture.request)
    }

    #expect(try Data(contentsOf: fixture.configuration) == originalConfig)
    #expect(try Data(contentsOf: fixture.sourceDashboard) == originalSource)
    #expect(!FileManager.default.fileExists(atPath: fixture.destinationDashboard.path))
  }

  @Test("A failure after any target write restores exact original bytes")
  func writeBoundaryFailuresRollBack() throws {
    for boundary in 1...4 {
      let fixture = try ProjectTransactionFixture()
      defer { fixture.remove() }
      let originalConfig = try Data(contentsOf: fixture.configuration)
      let originalSource = try Data(contentsOf: fixture.sourceDashboard)
      let transaction = ProjectCreationTransaction(
        supportDirectory: fixture.support,
        configurationURL: fixture.configuration,
        rollbackOnFailure: true,
        afterTargetWrite: { index, _ in
          if index == boundary { throw ProjectTransactionTestError.injected }
        })

      #expect(throws: ProjectTransactionTestError.injected) {
        try transaction.create(fixture.request)
      }

      #expect(try Data(contentsOf: fixture.configuration) == originalConfig)
      #expect(try Data(contentsOf: fixture.sourceDashboard) == originalSource)
      #expect(!FileManager.default.fileExists(atPath: fixture.destinationDashboard.path))
      #expect(try QueueOrderStore(root: fixture.support, projectID: "focus-queue").load() == nil)
    }
  }

  @Test("Startup recovery rolls back a prepared transaction interrupted between writes")
  func recoversInterruptedTransaction() throws {
    let fixture = try ProjectTransactionFixture()
    defer { fixture.remove() }
    let originalConfig = try Data(contentsOf: fixture.configuration)
    let originalSource = try Data(contentsOf: fixture.sourceDashboard)
    let interrupted = ProjectCreationTransaction(
      supportDirectory: fixture.support,
      configurationURL: fixture.configuration,
      rollbackOnFailure: false,
      afterTargetWrite: { index, _ in
        if index == 2 { throw ProjectTransactionTestError.injected }
      })
    #expect(throws: ProjectTransactionTestError.injected) {
      try interrupted.create(fixture.request)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.destinationDashboard.path))

    let recoveries = try fixture.transaction.recoverPending()

    #expect(recoveries.count == 1)
    #expect(recoveries.first?.status == "rolled-back")
    #expect(try Data(contentsOf: fixture.configuration) == originalConfig)
    #expect(try Data(contentsOf: fixture.sourceDashboard) == originalSource)
    #expect(!FileManager.default.fileExists(atPath: fixture.destinationDashboard.path))
    #expect(try QueueOrderStore(root: fixture.support, projectID: "focus-queue").load() == nil)
  }

  @Test("Concurrent project helpers produce one winner without losing tasks")
  func simultaneousCreationHasOneWinner() async throws {
    let fixture = try ProjectTransactionFixture()
    defer { fixture.remove() }
    let request = fixture.request
    let support = fixture.support
    let configuration = fixture.configuration

    async let first = Task.detached {
      try? ProjectCreationTransaction(
        supportDirectory: support, configurationURL: configuration).create(request)
    }.value
    async let second = Task.detached {
      try? ProjectCreationTransaction(
        supportDirectory: support, configurationURL: configuration).create(request)
    }.value
    let receipts = await [first, second]

    #expect(receipts.compactMap { $0 }.count == 1)
    let source = try fixture.object(at: fixture.sourceDashboard)
    let sourceIDs = (source["tickets"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
    #expect(sourceIDs == ["ECC-999"])
    let destination = try fixture.object(at: fixture.destinationDashboard)
    let destinationIDs = (destination["tickets"] as? [[String: Any]])?
      .compactMap { $0["id"] as? String }
    #expect(destinationIDs == ["ECC-035", "ECC-044"])
  }

  @Test("A symlinked project directory cannot redirect writes outside Application Support")
  func rejectsDestinationSymlinkEscape() throws {
    let fixture = try ProjectTransactionFixture()
    defer { fixture.remove() }
    let projectRoot = fixture.support.appendingPathComponent("projects")
    let outside = fixture.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: projectRoot.appendingPathComponent("focus-queue"),
      withDestinationURL: outside)

    #expect(throws: ProjectCreationError.self) {
      try fixture.transaction.create(fixture.request)
    }
    #expect(!FileManager.default.fileExists(
      atPath: outside.appendingPathComponent("dashboard.json").path))
  }

  @Test("Recovery rejects a tampered manifest before it can overwrite an unrelated file")
  func rejectsTamperedRecoveryTargets() throws {
    let fixture = try ProjectTransactionFixture()
    defer { fixture.remove() }
    let interrupted = ProjectCreationTransaction(
      supportDirectory: fixture.support,
      configurationURL: fixture.configuration,
      rollbackOnFailure: false,
      afterTargetWrite: { index, _ in
        if index == 2 { throw ProjectTransactionTestError.injected }
      })
    #expect(throws: ProjectTransactionTestError.injected) {
      try interrupted.create(fixture.request)
    }

    let victim = fixture.root.appendingPathComponent("unrelated.txt")
    let originalVictim = Data("preserve this file".utf8)
    let replacement = Data("manifest-controlled replacement".utf8)
    try originalVictim.write(to: victim)
    let transactionDirectory = try #require(
      FileManager.default.contentsOfDirectory(
        at: fixture.support.appendingPathComponent("project-transactions"),
        includingPropertiesForKeys: nil).first)
    let manifestURL = transactionDirectory.appendingPathComponent("manifest.json")
    var manifest = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    var records = try #require(manifest["files"] as? [[String: Any]])
    let maliciousBackup = transactionDirectory.appendingPathComponent("backups/malicious.data")
    try replacement.write(to: maliciousBackup)
    records[0]["targetPath"] = victim.path
    records[0]["backupPath"] = maliciousBackup.path
    records[0]["originalHash"] = sha256(replacement)
    records[0]["intendedHash"] = sha256(originalVictim)
    manifest["files"] = records
    try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
    ).write(to: manifestURL, options: .atomic)

    #expect(throws: ProjectCreationError.self) {
      try fixture.transaction.recoverPending()
    }
    #expect(try Data(contentsOf: victim) == originalVictim)
  }
}

private enum ProjectTransactionTestError: Error { case injected }

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension ProjectCreationRequest {
  func replacing(
    id: String? = nil,
    name: String? = nil,
    workspacePath: String? = nil,
    taskIDs: [String]? = nil
  ) -> Self {
    Self(
      id: id ?? self.id,
      name: name ?? self.name,
      workspacePath: workspacePath ?? self.workspacePath,
      sourceProjectID: sourceProjectID,
      taskIDs: taskIDs ?? self.taskIDs)
  }
}

private enum ProjectRequestMutation: CaseIterable {
  case invalidSlug, duplicateName, missingWorkspace, missingTask, duplicateTask

  func apply(
    to request: ProjectCreationRequest, fixture: ProjectTransactionFixture
  ) -> ProjectCreationRequest {
    switch self {
    case .invalidSlug:
      return request.replacing(id: "../escape")
    case .duplicateName:
      return request.replacing(name: "ecc")
    case .missingWorkspace:
      return request.replacing(workspacePath: fixture.root.appendingPathComponent("missing").path)
    case .missingTask:
      return request.replacing(taskIDs: ["ECC-404"])
    case .duplicateTask:
      return request.replacing(taskIDs: ["ECC-035", "ecc-035"])
    }
  }
}

private struct ProjectTransactionFixture {
  let root: URL
  let support: URL
  let configuration: URL
  let sourceDashboard: URL
  let workspace: URL
  let destinationDashboard: URL
  let request: ProjectCreationRequest

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("focus-queue-project-transaction-\(UUID().uuidString)")
    support = root.appendingPathComponent("support")
    configuration = support.appendingPathComponent("config.json")
    sourceDashboard = root.appendingPathComponent("ecc/dashboard.json")
    workspace = root.appendingPathComponent("focus-queue-workspace")
    destinationDashboard = support.appendingPathComponent("projects/focus-queue/dashboard.json")
    try FileManager.default.createDirectory(
      at: sourceDashboard.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try Data(
      """
      {
        "updatedAt": "2026-09-18T12:00:00Z",
        "sourceMetadata": {"owner": "external"},
        "tickets": [
          {"id":"ECC-035","title":"Focus Queue app","status":"open","priority":"high","summary":"App","opaque":{"keep":true}},
          {"id":"ECC-044","title":"Focus Queue integrations","status":"open","priority":"medium","summary":"Integrations","worktree":"\(workspace.path)"},
          {"id":"ECC-999","title":"Other ECC work","status":"open","priority":"low","summary":"Keep in ECC"}
        ]
      }
      """.utf8
    ).write(to: sourceDashboard)

    let source = ProjectConfiguration(
      id: "ecc", name: "ECC", dashboardPath: sourceDashboard.path,
      workspacePath: root.appendingPathComponent("ecc").path)
    var app = AppConfiguration.eccDefault(homeDirectory: root)
    app.projects = [source]
    app.selectedProjectID = source.id
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
    object["projects"] = [[
      "id": "external", "name": "External catalog",
      "repositoryPath": "/tmp/external-repository-catalog",
    ]]
    object["selectedProjectID"] = "external-selection"
    object["vendorMetadata"] = ["revision": 7, "owner": "external"]
    try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ).write(to: configuration)

    request = ProjectCreationRequest(
      id: "focus-queue", name: "Focus Queue", workspacePath: workspace.path,
      sourceProjectID: "ecc", taskIDs: ["ECC-044", "ECC-035"])
  }

  var transaction: ProjectCreationTransaction {
    ProjectCreationTransaction(supportDirectory: support, configurationURL: configuration)
  }

  var decodedTickets: [DashboardTicket] {
    get throws {
      try JSONDecoder().decode(
        DashboardDocument.self, from: Data(contentsOf: sourceDashboard)).tickets
    }
  }

  func object(at url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  func permissions(of url: URL) throws -> Int {
    try #require(
      FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
