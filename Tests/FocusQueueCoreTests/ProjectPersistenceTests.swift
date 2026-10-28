import Foundation
import Testing

@testable import FocusQueueCore

@Test("Legacy configuration becomes one selected project without moving its paths")
func legacyConfigurationCreatesEffectiveProject() throws {
  let data = Data(
    """
    {
      "appName": "ECC Focus Queue",
      "dashboardPath": "/tmp/ECC/dashboard.json",
      "workspacePath": "/tmp/ECC",
      "defaultPlacement": "upper-right",
      "refreshIntervalSeconds": 2,
      "dailyRoutines": [],
      "wezTerm": {"executable": "/tmp/wezterm", "applicationName": "WezTerm"},
      "verifier": {
        "enabled": true,
        "executable": "/tmp/focus-queue-codex",
        "sessionName": "queue",
        "timeoutSeconds": 120,
        "maxTurns": 24
      }
    }
    """.utf8
  )

  let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
  let project = try #require(configuration.selectedProject)

  #expect(configuration.projects.count == 1)
  #expect(configuration.selectedProjectID == project.id)
  #expect(project.name == "ECC")
  #expect(project.dashboardPath == "/tmp/ECC/dashboard.json")
  #expect(project.workspacePath == "/tmp/ECC")
  #expect(!configuration.dailyReport.enabled)
  #expect(configuration.appName == "ECC Focus Queue")
}

@Test("Saving drops the removed completion review preference")
func removedCompletionReviewKeyIsDropped() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-review-setting-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("config.json")
  let repository = JSONConfigurationRepository(url: url)
  try await repository.save(AppConfiguration.eccDefault(homeDirectory: root))
  var stored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  stored["completionReviewEnabled"] = true
  try JSONSerialization.data(withJSONObject: stored).write(to: url)

  let reloaded = try await repository.loadOrCreate(default: .eccDefault(homeDirectory: root))
  try await repository.save(reloaded)

  let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  #expect(saved["completionReviewEnabled"] == nil)
}

@Test("Legacy repository project catalog does not shadow queue project migration")
func legacyRepositoryProjectCatalogIsPreserved() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-legacy-project-catalog-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("config.json")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try Data(
    """
    {
      "appName": "ECC Focus Queue",
      "dashboardPath": "/tmp/ECC/dashboard.json",
      "workspacePath": "/tmp/ECC",
      "defaultPlacement": "upper-right",
      "refreshIntervalSeconds": 2,
      "dailyRoutines": [],
      "wezTerm": {"executable": "/tmp/wezterm", "applicationName": "WezTerm"},
      "verifier": {
        "enabled": true,
        "executable": "/tmp/focus-queue-codex",
        "sessionName": "queue",
        "timeoutSeconds": 120,
        "maxTurns": 24
      },
      "selectedProjectID": "focus-queue",
      "projects": [
        {
          "id": "focus-queue",
          "name": "Focus Queue",
          "repositoryPath": "/tmp/FocusQueue",
          "remoteAliases": []
        },
        {
          "id": "ecc",
          "name": "ECC",
          "repositoryPath": "/tmp/ECC/repository",
          "remote": "https://example.test/ecc",
          "remoteAliases": ["https://example.test/ecc-fork"]
        }
      ],
      "vendorMetadata": {"owner": "external", "revision": 7}
    }
    """.utf8
  ).write(to: url)

  let repository = JSONConfigurationRepository(url: url)
  let configuration = try await repository.loadOrCreate(
    default: .eccDefault(homeDirectory: root))
  let selected = try #require(configuration.selectedProject)

  #expect(configuration.projects.count == 1)
  #expect(configuration.selectedProjectID == selected.id)
  #expect(selected.name == "ECC")
  #expect(selected.dashboardPath == "/tmp/ECC/dashboard.json")
  #expect(selected.workspacePath == "/tmp/ECC")

  try await repository.save(configuration)
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let preserved = try #require(object["projects"] as? [[String: Any]])
  let focusProjects = try #require(object["focusQueueProjects"] as? [[String: Any]])
  let vendorMetadata = try #require(object["vendorMetadata"] as? [String: Any])

  #expect(preserved.count == 2)
  #expect(preserved[1]["repositoryPath"] as? String == "/tmp/ECC/repository")
  #expect(preserved[1]["remote"] as? String == "https://example.test/ecc")
  #expect(focusProjects.count == 1)
  #expect(focusProjects[0]["dashboardPath"] as? String == "/tmp/ECC/dashboard.json")
  #expect(object["selectedProjectID"] as? String == "focus-queue")
  #expect(object["focusQueueSelectedProjectID"] as? String == selected.id)
  #expect(vendorMetadata["owner"] as? String == "external")
  #expect(vendorMetadata["revision"] as? Int == 7)
}

@Test("Valid legacy queue projects migrate to the new key and retain selection")
func validLegacyQueueProjectsMigrate() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-valid-legacy-projects-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("config.json")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try legacyQueueProjectConfigurationData(
    projects: [
      [
        "id": "first", "name": "First",
        "dashboardPath": "/tmp/first/dashboard.json", "workspacePath": "/tmp/first",
      ],
      [
        "id": "second", "name": "Second",
        "dashboardPath": "/tmp/second/dashboard.json", "workspacePath": "/tmp/second",
      ],
    ],
    selectedProjectID: "second"
  ).write(to: url)

  let repository = JSONConfigurationRepository(url: url)
  let migrated = try await repository.loadOrCreate(default: .eccDefault(homeDirectory: root))
  #expect(migrated.projects.map(\.id) == ["first", "second"])
  #expect(migrated.selectedProjectID == "second")
  #expect(migrated.dashboardPath == "/tmp/second/dashboard.json")

  try await repository.save(migrated)
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  #expect((object["focusQueueProjects"] as? [[String: Any]])?.count == 2)
  #expect(object["projects"] == nil)
  #expect(object["selectedProjectID"] == nil)
  #expect(object["focusQueueSelectedProjectID"] as? String == "second")
  let reloaded = try await repository.loadOrCreate(default: .eccDefault(homeDirectory: root))
  #expect(reloaded.selectedProjectID == "second")
  #expect(reloaded.selectedProject?.dashboardPath == "/tmp/second/dashboard.json")
}

@Test("Invalid legacy queue projects fail instead of silently collapsing the catalog")
func invalidLegacyQueueProjectsFail() throws {
  let data = try legacyQueueProjectConfigurationData(
    projects: [[
      "id": "invalid", "name": "Invalid",
      "dashboardPath": "relative/dashboard.json", "workspacePath": "/tmp/invalid",
    ]],
    selectedProjectID: "invalid"
  )

  #expect(throws: ConfigurationError.self) {
    try JSONDecoder().decode(AppConfiguration.self, from: data).validated()
  }
}

@Test("Partially malformed legacy queue projects report the damaged catalog")
func partiallyMalformedLegacyQueueProjectsFail() throws {
  let data = try legacyQueueProjectConfigurationData(
    projects: [
      [
        "id": "valid", "name": "Valid",
        "dashboardPath": "/tmp/valid/dashboard.json", "workspacePath": "/tmp/valid",
      ],
      [
        "id": "damaged", "name": "Damaged",
        "dashboardPath": "/tmp/damaged/dashboard.json",
      ],
    ],
    selectedProjectID: "valid"
  )

  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(AppConfiguration.self, from: data)
  }
}

@Test("Saving configuration does not resurrect cleared known optional settings")
func clearedOptionalConfigurationStaysCleared() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-cleared-options-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("config.json")
  let repository = JSONConfigurationRepository(url: url)
  var configuration = AppConfiguration.eccDefault(homeDirectory: root)
  configuration.persistentTerminals = true
  configuration.tmuxExecutable = "/tmp/tmux"
  configuration.setupCompleted = true
  try await repository.save(configuration)

  configuration.persistentTerminals = nil
  configuration.tmuxExecutable = nil
  configuration.setupCompleted = nil
  try await repository.save(configuration)

  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  #expect(object["persistentTerminals"] == nil)
  #expect(object["tmuxExecutable"] == nil)
  #expect(object["setupCompleted"] == nil)
}

@Test("Saving over a non-object configuration preserves its bytes and fails")
func nonObjectConfigurationIsNotOverwritten() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-non-object-config-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("config.json")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let original = Data("[]\n".utf8)
  try original.write(to: url)
  let repository = JSONConfigurationRepository(url: url)

  await #expect(throws: CocoaError.self) {
    try await repository.save(.eccDefault(homeDirectory: root))
  }
  #expect(try Data(contentsOf: url) == original)
}

@Test("Ambiguous legacy project metadata is retained by rejecting the save")
func ambiguousLegacyProjectsAreNotDeleted() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-ambiguous-projects-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("config.json")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let configuration = AppConfiguration.eccDefault(homeDirectory: root)
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
  object["projects"] = [
    ["id": "one", "name": "One", "repositoryPath": "/tmp/one"],
    ["id": "two", "name": "Two"],
  ]
  object["selectedProjectID"] = "one"
  let original = try JSONSerialization.data(
    withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  try original.write(to: url)
  let repository = JSONConfigurationRepository(url: url)
  let loaded = try await repository.loadOrCreate(default: .eccDefault(homeDirectory: root))

  await #expect(throws: CocoaError.self) {
    try await repository.save(loaded)
  }
  #expect(try Data(contentsOf: url) == original)
}

@Test("Selecting a project keeps legacy paths aligned and survives persistence")
func projectSelectionSynchronizesLegacyPaths() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-project-test-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let first = ProjectConfiguration(
    id: "ecc",
    name: "ECC",
    dashboardPath: "/tmp/ecc/dashboard.json",
    workspacePath: "/tmp/ecc"
  )
  let second = ProjectConfiguration(
    id: "focus-queue",
    name: "Focus Queue",
    dashboardPath: "/tmp/focus-queue/dashboard.json",
    workspacePath: "/tmp/focus-queue"
  )
  var configuration = AppConfiguration.eccDefault(homeDirectory: root)
  configuration.projects = [first, second]
  configuration.selectedProjectID = first.id

  let didSelect = configuration.selectProject(id: second.id)
  #expect(didSelect)
  #expect(configuration.selectedProject == second)
  #expect(configuration.dashboardPath == second.dashboardPath)
  #expect(configuration.workspacePath == second.workspacePath)
  let didSelectMissing = configuration.selectProject(id: "missing")
  #expect(!didSelectMissing)
  #expect(configuration.selectedProject == second)

  let repository = JSONConfigurationRepository(url: root.appendingPathComponent("config.json"))
  try await repository.save(configuration)
  let reloaded = try await repository.loadOrCreate(default: .eccDefault(homeDirectory: root))

  #expect(reloaded.projects == [first, second])
  #expect(reloaded.selectedProject == second)
  #expect(reloaded.dashboardPath == second.dashboardPath)
  #expect(reloaded.workspacePath == second.workspacePath)
}

@Test("Legacy path setters keep the selected project aligned")
func legacyPathSettersSynchronizeSelectedProject() {
  var configuration = AppConfiguration.eccDefault(
    homeDirectory: URL(fileURLWithPath: "/Users/test"))

  configuration.dashboardPath = "/tmp/selected/dashboard.json"
  configuration.workspacePath = "/tmp/selected"

  #expect(configuration.selectedProject?.dashboardPath == "/tmp/selected/dashboard.json")
  #expect(configuration.selectedProject?.workspacePath == "/tmp/selected")
}

@Test("Configuration rejects duplicate project identities")
func duplicateProjectIDsAreRejected() throws {
  let project = ProjectConfiguration(
    id: "same",
    name: "One",
    dashboardPath: "/tmp/one/dashboard.json",
    workspacePath: "/tmp/one"
  )
  var configuration = AppConfiguration.eccDefault(homeDirectory: URL(fileURLWithPath: "/tmp"))
  configuration.projects = [
    project,
    ProjectConfiguration(
      id: "same",
      name: "Two",
      dashboardPath: "/tmp/two/dashboard.json",
      workspacePath: "/tmp/two"
    ),
  ]
  configuration.selectedProjectID = "same"

  #expect(throws: ConfigurationError.duplicateProjectID) {
    try configuration.validated()
  }
}

@Test("Local state defaults to FQ minimization and persists another choice")
func minimizationPreferencePersistence() async throws {
  let legacy = try JSONDecoder().decode(LocalState.self, from: Data("{}".utf8))
  #expect(legacy.minimizationPreference == .fq)

  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-minimization-test-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = JSONLocalStateStore(url: root.appendingPathComponent("state.json"))
  var state = LocalState()
  state.minimizationPreference = .topTask
  try await repository.save(state)

  #expect(try await JSONLocalStateStore(url: root.appendingPathComponent("state.json")).load()
    .minimizationPreference == .topTask)
}

@Test("Dashboard rename preserves fields the app does not model")
func dashboardRenamePreservesUnknownFields() async throws {
  let fixture = try DashboardMutationFixture(
    """
    {
      "updatedAt": "2026-09-18T12:00:00Z",
      "sourceMetadata": {"owner": "external", "sequence": 7},
      "tickets": [{
        "id": "ECC-101",
        "title": "Old title",
        "status": "open",
        "summary": "Keep me",
        "externalState": {"opaque": true}
      }]
    }
    """
  )
  defer { fixture.remove() }
  let repository = JSONDashboardRepository()
  let snapshot = try await repository.loadSnapshot(from: fixture.url)

  let updated = try await repository.renameTicket(
    id: "ECC-101",
    to: "New title",
    in: fixture.url,
    expectedRevision: snapshot.revision
  )
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any]
  )
  let metadata = try #require(object["sourceMetadata"] as? [String: Any])
  let tickets = try #require(object["tickets"] as? [[String: Any]])
  let externalState = try #require(tickets.first?["externalState"] as? [String: Any])

  #expect(updated.document.tickets.first?.title == "New title")
  #expect(metadata["owner"] as? String == "external")
  #expect(metadata["sequence"] as? Int == 7)
  #expect(externalState["opaque"] as? Bool == true)
  #expect(tickets.first?["summary"] as? String == "Keep me")
}

@Test("Dashboard priority and status updates persist with revision checks")
func dashboardPriorityAndStatusUpdates() async throws {
  let fixture = try DashboardMutationFixture(
    #"{"tickets":[{"id":"ECC-101","title":"Task","status":"open","priority":"low"}]}"#
  )
  defer { fixture.remove() }
  let repository = JSONDashboardRepository()
  let snapshot = try await repository.loadSnapshot(from: fixture.url)

  let prioritized = try await repository.setTicketPriority(
    id: "ECC-101", to: "high", in: fixture.url, expectedRevision: snapshot.revision)
  #expect(prioritized.document.tickets.first?.priority == "high")
  let updated = try await repository.setTicketStatus(
    id: "ECC-101", to: "in-progress", in: fixture.url, expectedRevision: prioritized.revision)
  #expect(updated.document.tickets.first?.status == "in-progress")

  let saved = try JSONDecoder().decode(DashboardDocument.self, from: Data(contentsOf: fixture.url))
  #expect(saved.tickets.first?.priority == "high")
  #expect(saved.tickets.first?.status == "in-progress")

  await #expect(throws: DashboardMutationError.invalidFieldValue("priority")) {
    try await repository.setTicketPriority(
      id: "ECC-101", to: "   ", in: fixture.url, expectedRevision: updated.revision)
  }
  await #expect(throws: DashboardMutationError.ticketNotFound("ECC-999")) {
    try await repository.setTicketStatus(
      id: "ECC-999", to: "open", in: fixture.url, expectedRevision: updated.revision)
  }
}

@Test("Reopening a completed task preserves its completion event and clears active completion fields")
func dashboardReopenPreservesCompletionHistory() async throws {
  let fixture = try DashboardMutationFixture(
    #"{"sourceMetadata":{"owner":"external"},"tickets":[{"id":"ECC-101","title":"Task","status":"resolved","completedAt":"2026-10-18T14:00:00Z","completion":{"outcome":"completed","reason":"Verified","evidence":["test.log"],"completedBy":"reviewer"},"completionHistory":[{"status":"cancelled","completedAt":"2026-09-01T12:00:00Z"}],"externalState":{"keep":true}}]}"#
  )
  defer { fixture.remove() }
  let repository = JSONDashboardRepository()
  let snapshot = try await repository.loadSnapshot(from: fixture.url)

  let reopened = try await repository.reopenTicket(
    id: "ECC-101", in: fixture.url, expectedRevision: snapshot.revision)

  #expect(reopened.document.tickets.first?.status == "open")
  #expect(reopened.document.tickets.first?.completedAt == nil)
  #expect(reopened.document.tickets.first?.completion == nil)
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any]
  )
  let metadata = try #require(object["sourceMetadata"] as? [String: Any])
  let ticket = try #require((object["tickets"] as? [[String: Any]])?.first)
  let history = try #require(ticket["completionHistory"] as? [[String: Any]])
  let prior = try #require(history.last)
  let completion = try #require(prior["completion"] as? [String: Any])
  let externalState = try #require(ticket["externalState"] as? [String: Any])
  #expect(history.count == 2)
  #expect(prior["status"] as? String == "resolved")
  #expect(prior["completedAt"] as? String == "2026-10-18T14:00:00Z")
  #expect(prior["reopenedAt"] as? String != nil)
  #expect(completion["reason"] as? String == "Verified")
  #expect(ticket["completedAt"] == nil)
  #expect(ticket["completion"] == nil)
  #expect(metadata["owner"] as? String == "external")
  #expect(externalState["keep"] as? Bool == true)
}

@Test("Dashboard hard deadlines set and clear without overwriting other fields")
func dashboardHardDeadlineUpdates() async throws {
  let fixture = try DashboardMutationFixture(
    #"{"opaque":{"keep":true},"tickets":[{"id":"ECC-101","title":"Task","status":"open","summary":"Keep me"}]}"#
  )
  defer { fixture.remove() }
  let repository = JSONDashboardRepository()
  let snapshot = try await repository.loadSnapshot(from: fixture.url)

  let dated = try await repository.setTicketDueDate(
    id: "ECC-101", to: "2026-10-24", source: "User specified",
    in: fixture.url, expectedRevision: snapshot.revision)
  #expect(dated.document.tickets.first?.dueDate == "2026-10-24")
  #expect(dated.document.tickets.first?.dueDateSource == "User specified")
  #expect(dated.document.tickets.first?.summary == "Keep me")

  let cleared = try await repository.setTicketDueDate(
    id: "ECC-101", to: nil, source: nil, in: fixture.url, expectedRevision: dated.revision)
  #expect(cleared.document.tickets.first?.dueDate == nil)
  #expect(cleared.document.tickets.first?.dueDateSource == nil)
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any])
  #expect((object["opaque"] as? [String: Any])?["keep"] as? Bool == true)

  let beforeInvalid = try Data(contentsOf: fixture.url)
  await #expect(throws: DashboardMutationError.invalidFieldValue("dueDate")) {
    try await repository.setTicketDueDate(
      id: "ECC-101", to: "not-a-date", source: nil, in: fixture.url, expectedRevision: cleared.revision)
  }
  #expect(try Data(contentsOf: fixture.url) == beforeInvalid)
  await #expect(throws: DashboardMutationError.concurrentModification) {
    try await repository.setTicketDueDate(
      id: "ECC-101", to: "2026-10-25", source: nil, in: fixture.url, expectedRevision: snapshot.revision)
  }
  #expect(try Data(contentsOf: fixture.url) == beforeInvalid)
}

@Test("Dashboard creation is project-scoped and rejects globally duplicate ticket IDs")
func dashboardCreateRejectsCrossProjectDuplicate() async throws {
  let target = try DashboardMutationFixture(#"{"project":"target","tickets":[]}"#)
  let other = try DashboardMutationFixture(
    #"{"project":"other","tickets":[{"id":"ECC-200","title":"Existing"}]}"#
  )
  defer {
    target.remove()
    other.remove()
  }
  let repository = JSONDashboardRepository()
  let snapshot = try await repository.loadSnapshot(from: target.url)
  let ticket = DashboardTicket(
    id: "ECC-201",
    title: "New task",
    status: "open",
    summary: "Created in the selected project"
  )

  let updated = try await repository.createTicket(
    ticket,
    in: target.url,
    expectedRevision: snapshot.revision,
    checking: [other.url]
  )
  #expect(updated.document.tickets.map(\.id) == ["ECC-201"])
  #expect(try await repository.load(from: other.url).tickets.map(\.id) == ["ECC-200"])

  let duplicate = DashboardTicket(
    id: "ECC-200",
    title: "Duplicate",
    status: "open",
    summary: "Must not be written"
  )
  await #expect(throws: DashboardMutationError.duplicateTicketID("ECC-200")) {
    try await repository.createTicket(
      duplicate,
      in: target.url,
      expectedRevision: updated.revision,
      checking: [other.url]
    )
  }
}

@Test("Dashboard mutation rejects a stale revision without overwriting external work")
func dashboardMutationRejectsConcurrentChange() async throws {
  let fixture = try DashboardMutationFixture(
    #"{"tickets":[{"id":"ECC-300","title":"Original"}]}"#
  )
  defer { fixture.remove() }
  let repository = JSONDashboardRepository()
  let stale = try await repository.loadSnapshot(from: fixture.url)
  let external = #"{"external":true,"tickets":[{"id":"ECC-300","title":"External edit"}]}"#
  try Data(external.utf8).write(to: fixture.url, options: .atomic)

  await #expect(throws: DashboardMutationError.concurrentModification) {
    try await repository.renameTicket(
      id: "ECC-300",
      to: "Our edit",
      in: fixture.url,
      expectedRevision: stale.revision
    )
  }
  #expect(String(decoding: try Data(contentsOf: fixture.url), as: UTF8.self) == external)
}

@Test("Independent dashboard writers serialize the final revision check and write")
func dashboardWritersSerializeMutation() async throws {
  let fixture = try DashboardMutationFixture(
    #"{"tickets":[{"id":"ECC-301","title":"Original"}]}"#
  )
  defer { fixture.remove() }
  let first = JSONDashboardRepository()
  let second = JSONDashboardRepository()
  let revision = try await first.loadSnapshot(from: fixture.url).revision

  async let firstSucceeded = renameSucceeded(
    repository: first, url: fixture.url, revision: revision, title: "First")
  async let secondSucceeded = renameSucceeded(
    repository: second, url: fixture.url, revision: revision, title: "Second")
  let outcomes = await (firstSucceeded, secondSucceeded)

  #expect([outcomes.0, outcomes.1].filter { $0 }.count == 1)
  let final = try await JSONDashboardRepository().load(from: fixture.url)
  #expect(["First", "Second"].contains(final.tickets.first?.title ?? ""))
}

@Test("Dashboard lock path matches the Python writer contract")
func dashboardLockPathContract() {
  let dashboard = URL(fileURLWithPath: "/tmp/project/dashboard.json")

  #expect(
    DashboardFileLock.url(for: dashboard).path
      == "/tmp/project/.dashboard.json.focus-queue.lock")
}

@Test("Installed resource lookups prefer Focus Queue and retain the legacy bundle fallback")
func renamedBundleResourceLookupOrder() {
  let home = URL(fileURLWithPath: "/Users/test")
  let tmuxCandidates = TmuxPersistence.installedResourceCandidates(homeDirectory: home)
  let mapCandidates = TaskContext.installedMapHelperCandidates(homeDirectory: home)

  #expect(tmuxCandidates.map(\.path) == [
    "/Users/test/Applications/Focus Queue.app/Contents/Resources/tmux",
    "/Users/test/Applications/ECC Focus Queue.app/Contents/Resources/tmux",
  ])
  #expect(mapCandidates.map(\.path) == [
    "/Users/test/Applications/Focus Queue.app/Contents/MacOS/focus-queue-map",
    "/Users/test/Applications/ECC Focus Queue.app/Contents/MacOS/focus-queue-map",
  ])
}

private struct DashboardMutationFixture {
  let directory: URL
  let url: URL

  init(_ json: String) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("focus-queue-dashboard-mutation-\(UUID().uuidString)", isDirectory: true)
    url = directory.appendingPathComponent("dashboard.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private func renameSucceeded(
  repository: JSONDashboardRepository,
  url: URL,
  revision: DashboardRevision,
  title: String
) async -> Bool {
  do {
    _ = try await repository.renameTicket(
      id: "ECC-301", to: title, in: url, expectedRevision: revision)
    return true
  } catch {
    return false
  }
}

private func legacyQueueProjectConfigurationData(
  projects: [[String: Any]],
  selectedProjectID: String?
) throws -> Data {
  let encoder = JSONEncoder()
  var object = try #require(
    JSONSerialization.jsonObject(
      with: encoder.encode(
        AppConfiguration.eccDefault(homeDirectory: URL(fileURLWithPath: "/tmp/test-home"))))
      as? [String: Any])
  object["projects"] = projects
  object.removeValue(forKey: "focusQueueProjects")
  object.removeValue(forKey: "focusQueueSelectedProjectID")
  object["selectedProjectID"] = selectedProjectID
  return try JSONSerialization.data(withJSONObject: object)
}

@Test("Dashboard evidence links append once and keep existing links and fields")
func dashboardLinkAppend() async throws {
  let fixture = try DashboardMutationFixture(
    #"{"tickets":[{"id":"ECC-101","title":"Task","status":"open","summary":"Keep me","links":[{"label":"Spec","url":"https://example.com/spec"}]}]}"#
  )
  defer { fixture.remove() }
  let repository = JSONDashboardRepository()
  let snapshot = try await repository.loadSnapshot(from: fixture.url)
  let added = try await repository.addTicketLink(
    id: "ECC-101", label: "Why", url: "/tmp/why.md", type: "plan", in: fixture.url, expectedRevision: snapshot.revision)
  #expect(added.document.tickets.first?.links.map(\.url) == ["https://example.com/spec", "/tmp/why.md"])
  let repeated = try await repository.addTicketLink(
    id: "ECC-101", label: "Again", url: "/tmp/why.md", type: nil, in: fixture.url, expectedRevision: added.revision)
  #expect(repeated.document.tickets.first?.links.count == 2)
  let tickets = try #require(
    (JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any])?["tickets"] as? [[String: Any]])
  #expect(tickets.first?["summary"] as? String == "Keep me")
  await #expect(throws: DashboardMutationError.concurrentModification) {
    try await repository.addTicketLink(
      id: "ECC-101", label: "Stale", url: "/tmp/other.md", type: nil, in: fixture.url, expectedRevision: snapshot.revision)
  }
}
