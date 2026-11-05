import CryptoKit
import Foundation

public struct ProjectCreationRequest: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let workspacePath: String
  public let sourceProjectID: String
  public let taskIDs: [String]

  public init(
    id: String,
    name: String,
    workspacePath: String,
    sourceProjectID: String,
    taskIDs: [String]
  ) {
    self.id = id
    self.name = name
    self.workspacePath = workspacePath
    self.sourceProjectID = sourceProjectID
    self.taskIDs = taskIDs
  }
}

public struct ProjectCreationReceipt: Codable, Equatable, Sendable {
  public let status: String
  public let transactionID: String
  public let sourceProjectID: String
  public let project: ProjectConfiguration
  public let dashboardPath: String
  public let movedTaskIDs: [String]
  public let backupDirectory: String
}

public struct ProjectCatalogListing: Codable, Equatable, Sendable {
  public let projects: [ProjectConfiguration]
  public let selectedProjectID: String?
}

public struct ProjectRecoveryReceipt: Codable, Equatable, Sendable {
  public let transactionID: String
  public let status: String
}

public enum ProjectCatalogChangeNotification {
  public static let name = "com.haelyra.focus-queue.project-catalog-change"
}

public enum ProjectCreationError: Error, LocalizedError {
  case invalidProjectID
  case invalidName
  case invalidWorkspace(String)
  case invalidTaskSelection
  case sourceProjectNotFound(String)
  case projectAlreadyExists(String)
  case projectPathAlreadyExists(String)
  case taskNotFound(String)
  case duplicateTask(String)
  case destinationAlreadyExists(String)
  case invalidConfiguration
  case invalidDashboard(String)
  case concurrentModification
  case unsafeRecovery(String)

  public var errorDescription: String? {
    switch self {
    case .invalidProjectID:
      "Project IDs must be lowercase slugs of 1 to 48 letters, numbers, and single hyphens."
    case .invalidName:
      "Project names must contain 1 to 80 visible characters without surrounding whitespace."
    case .invalidWorkspace(let path):
      "The project workspace must be an existing absolute directory: \(path)"
    case .invalidTaskSelection:
      "Choose at least one unique task to move into the new project."
    case .sourceProjectNotFound(let id):
      "The source project \(id) does not exist."
    case .projectAlreadyExists(let value):
      "A project named or identified as \(value) already exists."
    case .projectPathAlreadyExists(let path):
      "A project already uses \(path)."
    case .taskNotFound(let id):
      "Task \(id) was not found exactly once in the source project."
    case .duplicateTask(let id):
      "Task \(id) occurs more than once in the source project."
    case .destinationAlreadyExists(let path):
      "The destination dashboard already exists at \(path)."
    case .invalidConfiguration:
      "The Focus Queue configuration is not a valid JSON object."
    case .invalidDashboard(let path):
      "The project dashboard is not a JSON object with unique task IDs: \(path)"
    case .concurrentModification:
      "Project data changed while the operation was being prepared. Retry from a fresh project list."
    case .unsafeRecovery(let detail):
      "Project recovery stopped to preserve a newer edit: \(detail)"
    }
  }
}

public struct ProjectCreationTransaction: Sendable {
  private let supportDirectory: URL
  private let configurationURL: URL
  private let rollbackOnFailure: Bool
  private let afterTargetWrite: (@Sendable (Int, URL) throws -> Void)?
  private let files = SystemFileAccessor()

  private var transactionsDirectory: URL {
    supportDirectory.appendingPathComponent("project-transactions", isDirectory: true)
  }

  public init(supportDirectory: URL, configurationURL: URL? = nil) {
    self.supportDirectory = supportDirectory.standardizedFileURL
    self.configurationURL = (configurationURL
      ?? supportDirectory.appendingPathComponent("config.json")).standardizedFileURL
    rollbackOnFailure = true
    afterTargetWrite = nil
  }

  init(
    supportDirectory: URL,
    configurationURL: URL,
    rollbackOnFailure: Bool,
    afterTargetWrite: (@Sendable (Int, URL) throws -> Void)?
  ) {
    self.supportDirectory = supportDirectory.standardizedFileURL
    self.configurationURL = configurationURL.standardizedFileURL
    self.rollbackOnFailure = rollbackOnFailure
    self.afterTargetWrite = afterTargetWrite
  }

  public func listProjects() throws -> ProjectCatalogListing {
    _ = try recoverPending()
    return try FocusQueueFileLock.withLocks(for: [configurationURL]) {
      let configuration = try readConfiguration()
      return ProjectCatalogListing(
        projects: configuration.projects,
        selectedProjectID: configuration.selectedProjectID)
    }
  }

  public func create(_ request: ProjectCreationRequest) throws -> ProjectCreationReceipt {
    _ = try recoverPending()
    try validate(request)

    let initialConfiguration = try readConfiguration()
    guard let initialSource = initialConfiguration.projects.first(where: {
      $0.id.caseInsensitiveCompare(request.sourceProjectID) == .orderedSame
    }) else {
      throw ProjectCreationError.sourceProjectNotFound(request.sourceProjectID)
    }
    let destinationDashboard = supportDirectory
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(request.id, isDirectory: true)
      .appendingPathComponent("dashboard.json")
      .standardizedFileURL
    let destinationOrder = QueueOrderStore(
      root: supportDirectory, projectID: request.id).storageURL.standardizedFileURL
    let sourceDashboard = URL(fileURLWithPath: initialSource.dashboardPath).standardizedFileURL
    let initialDashboardPaths = initialConfiguration.projects.map {
      URL(fileURLWithPath: $0.dashboardPath).standardizedFileURL.path
    }
    try validateManagedDestination(destinationDashboard, rootName: "projects")
    try validateManagedDestination(destinationOrder, rootName: "queue-order")
    let lockTargets = [configurationURL, destinationDashboard, destinationOrder]
      + initialDashboardPaths.map { URL(fileURLWithPath: $0) }

    return try FocusQueueFileLock.withLocks(for: lockTargets) {
      let configurationData = try files.read(from: configurationURL)
      let configuration = try decodeConfiguration(configurationData)
      guard let source = configuration.projects.first(where: {
        $0.id.caseInsensitiveCompare(request.sourceProjectID) == .orderedSame
      }) else {
        throw ProjectCreationError.sourceProjectNotFound(request.sourceProjectID)
      }
      guard URL(fileURLWithPath: source.dashboardPath).standardizedFileURL == sourceDashboard else {
        throw ProjectCreationError.concurrentModification
      }
      guard configuration.projects.map({
        URL(fileURLWithPath: $0.dashboardPath).standardizedFileURL.path
      }) == initialDashboardPaths else {
        throw ProjectCreationError.concurrentModification
      }
      try validateManagedDestination(destinationDashboard, rootName: "projects")
      try validateManagedDestination(destinationOrder, rootName: "queue-order")
      try validateNewProject(
        request, in: configuration, destinationDashboard: destinationDashboard)
      guard !files.fileExists(at: destinationDashboard) else {
        throw ProjectCreationError.destinationAlreadyExists(destinationDashboard.path)
      }
      guard !files.fileExists(at: destinationOrder) else {
        throw ProjectCreationError.destinationAlreadyExists(destinationOrder.path)
      }

      let sourceData = try files.read(from: sourceDashboard)
      try validateNoCrossProjectDuplicate(
        taskIDs: request.taskIDs,
        sourceProjectID: source.id,
        configuration: configuration)
      let prepared = try prepareCandidates(
        request: request,
        configuration: configuration,
        configurationData: configurationData,
        source: source,
        sourceData: sourceData,
        destinationDashboard: destinationDashboard,
        destinationOrder: destinationOrder)
      let receipt = try apply(prepared)
      // The move is committed; bootstrap and placement repair a document this misses.
      _ = try? ProjectContextStore(root: supportDirectory).ensurePlan(for: receipt.project)
      return receipt
    }
  }

  public func recoverPending() throws -> [ProjectRecoveryReceipt] {
    guard FileManager.default.fileExists(atPath: transactionsDirectory.path) else { return [] }
    let directories = try FileManager.default.contentsOfDirectory(
      at: transactionsDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    var receipts: [ProjectRecoveryReceipt] = []
    for directory in directories {
      let manifestURL = directory.appendingPathComponent("manifest.json")
      guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
      try validateTransactionContainer(directory: directory, manifestURL: manifestURL)
      var manifest = try decodeManifest(at: manifestURL)
      guard manifest.status == .prepared else { continue }
      try validateRecoveryManifest(manifest, transactionDirectory: directory)
      let targets = manifest.files.map { URL(fileURLWithPath: $0.targetPath) }
      let receipt = try FocusQueueFileLock.withLocks(for: targets) {
        manifest = try decodeManifest(at: manifestURL)
        guard manifest.status == .prepared else {
          return ProjectRecoveryReceipt(
            transactionID: manifest.id, status: manifest.status.rawValue)
        }
        try validateRecoveryManifest(manifest, transactionDirectory: directory)
        let allCommitted = try manifest.files.allSatisfy { record in
          try currentHash(at: URL(fileURLWithPath: record.targetPath)) == record.intendedHash
        }
        if allCommitted {
          manifest.status = .committed
          try writeManifest(manifest, to: manifestURL)
          return ProjectRecoveryReceipt(transactionID: manifest.id, status: "committed")
        }
        try ensureRecoveryIsSafe(manifest)
        try restoreOriginals(manifest)
        manifest.status = .rolledBack
        try writeManifest(manifest, to: manifestURL)
        return ProjectRecoveryReceipt(transactionID: manifest.id, status: "rolled-back")
      }
      receipts.append(receipt)
    }
    return receipts
  }

  private func validate(_ request: ProjectCreationRequest) throws {
    guard request.id.range(
      of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#,
      options: .regularExpression) != nil,
      request.id.count <= 48
    else { throw ProjectCreationError.invalidProjectID }
    let trimmedName = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard request.name == trimmedName,
      (1...80).contains(trimmedName.count),
      trimmedName.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw ProjectCreationError.invalidName
    }
    let workspace = URL(fileURLWithPath: request.workspacePath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard request.workspacePath.hasPrefix("/"),
      FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw ProjectCreationError.invalidWorkspace(request.workspacePath) }
    let normalizedTasks = request.taskIDs.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
    guard (1...100).contains(normalizedTasks.count),
      zip(request.taskIDs, normalizedTasks).allSatisfy({ original, normalized in
        original == original.trimmingCharacters(in: .whitespacesAndNewlines)
          && (1...128).contains(normalized.count)
          && normalized.range(
            of: #"^[A-Z0-9][A-Z0-9._-]*$"#,
            options: .regularExpression) != nil
      }),
      Set(normalizedTasks).count == normalizedTasks.count
    else { throw ProjectCreationError.invalidTaskSelection }
  }

  private func validateNewProject(
    _ request: ProjectCreationRequest,
    in configuration: AppConfiguration,
    destinationDashboard: URL
  ) throws {
    let workspace = canonicalPath(request.workspacePath)
    let destination = canonicalPath(destinationDashboard.path)
    for project in configuration.projects {
      if project.id.caseInsensitiveCompare(request.id) == .orderedSame
        || project.name.caseInsensitiveCompare(request.name) == .orderedSame
      {
        throw ProjectCreationError.projectAlreadyExists(request.name)
      }
      for path in [project.workspacePath, project.dashboardPath]
      where canonicalPath(path) == workspace || canonicalPath(path) == destination {
        throw ProjectCreationError.projectPathAlreadyExists(path)
      }
    }
  }

  private func prepareCandidates(
    request: ProjectCreationRequest,
    configuration: AppConfiguration,
    configurationData: Data,
    source: ProjectConfiguration,
    sourceData: Data,
    destinationDashboard: URL,
    destinationOrder: URL
  ) throws -> PreparedTransaction {
    guard var sourceObject = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
      let sourceTickets = sourceObject["tickets"] as? [[String: Any]]
    else { throw ProjectCreationError.invalidDashboard(source.dashboardPath) }

    var seen: [String: Int] = [:]
    for ticket in sourceTickets {
      guard let id = ticket["id"] as? String, !id.isEmpty else {
        throw ProjectCreationError.invalidDashboard(source.dashboardPath)
      }
      seen[id.uppercased(), default: 0] += 1
    }
    if let duplicate = seen.first(where: { $0.value > 1 })?.key {
      throw ProjectCreationError.duplicateTask(duplicate)
    }
    let requested = Set(request.taskIDs.map { $0.uppercased() })
    for id in requested where seen[id] != 1 {
      throw ProjectCreationError.taskNotFound(id)
    }
    let movedTickets = sourceTickets.filter {
      ($0["id"] as? String).map { requested.contains($0.uppercased()) } == true
    }
    let remainingTickets = sourceTickets.filter {
      ($0["id"] as? String).map { !requested.contains($0.uppercased()) } == true
    }
    sourceObject["tickets"] = remainingTickets
    let sourceCandidate = try encodeJSONObject(sourceObject)
    let destinationCandidate = try encodeJSONObject(["tickets": movedTickets])

    let decodedSource = try JSONDecoder().decode(DashboardDocument.self, from: sourceData)
    let projectionState = readQueueProjectionState()
    let sourceContexts = readTaskContexts(
      ticketIDs: Set(decodedSource.tickets.map { $0.id.uppercased() }))
    let sourceAutomatic = QueueOrderStore.automaticTickets(
      decodedSource.tickets,
      deferredTicketIDs: projectionState.deferredTicketIDs,
      mode: projectionState.mode,
      contexts: sourceContexts)
    let sourceAutomaticIDs = sourceAutomatic.map(\.id)
    let sourceOverride = try QueueOrderStore(
      root: supportDirectory, projectID: source.id).applicableOrder(
        automaticIDs: sourceAutomaticIDs, sortMode: projectionState.mode)
    let sourceDisplayed: [DashboardTicket]
    if let sourceOverride {
      let manuallyOrdered = QueueOrderStore.orderedTickets(
        sourceAutomatic, savedIDs: sourceOverride)
      let pinnedDates = Dictionary(sourceContexts.compactMap { context in
        context.pinnedAt.map { (context.ticketID, $0) }
      }, uniquingKeysWith: max)
      sourceDisplayed = QueueOrderStore.prioritizingPins(
        manuallyOrdered, pinnedAtByTicketID: pinnedDates)
    } else {
      sourceDisplayed = sourceAutomatic
    }
    let canonicalIDs = Dictionary(
      movedTickets.compactMap { ticket -> (String, String)? in
        guard let id = ticket["id"] as? String else { return nil }
        return (id.uppercased(), id)
      },
      uniquingKeysWith: { first, _ in first })
    var orderedMovedIDs = sourceDisplayed.compactMap {
      canonicalIDs[$0.id.uppercased()]
    }
    for ticket in movedTickets {
      guard let id = ticket["id"] as? String, !orderedMovedIDs.contains(id) else { continue }
      orderedMovedIDs.append(id)
    }
    let movedDocument = try JSONDecoder().decode(DashboardDocument.self, from: destinationCandidate)
    let movedIDs = Set(movedDocument.tickets.map { $0.id.uppercased() })
    let movedContexts = sourceContexts.filter { movedIDs.contains($0.ticketID.uppercased()) }
    let automaticMovedIDs = QueueOrderStore.automaticTickets(
      movedDocument.tickets,
      deferredTicketIDs: projectionState.deferredTicketIDs,
      mode: projectionState.mode,
      contexts: movedContexts).map(\.id)
    let orderCandidate = try prettyEncoder.encode(QueueOrderDocument(
      orderedIDs: orderedMovedIDs,
      automaticBaselineIDs: automaticMovedIDs,
      sortMode: projectionState.mode))

    let project = ProjectConfiguration(
      id: request.id,
      name: request.name,
      dashboardPath: destinationDashboard.path,
      workspacePath: URL(fileURLWithPath: request.workspacePath).standardizedFileURL.path)
    var updatedConfiguration = configuration
    updatedConfiguration.projects.append(project)
    _ = try updatedConfiguration.validated()
    let encodedConfiguration = try prettyEncoder.encode(updatedConfiguration)
    guard var rawConfiguration = try JSONSerialization.jsonObject(with: configurationData)
      as? [String: Any],
      let canonicalConfiguration = try JSONSerialization.jsonObject(with: encodedConfiguration)
        as? [String: Any]
    else { throw ProjectCreationError.invalidConfiguration }
    rawConfiguration["focusQueueProjects"] = canonicalConfiguration["focusQueueProjects"]
    rawConfiguration["focusQueueSelectedProjectID"] =
      canonicalConfiguration["focusQueueSelectedProjectID"]
    let configurationCandidate = try encodeJSONObject(rawConfiguration)

    let transactionID = UUID().uuidString.lowercased()
    let transactionDirectory = transactionsDirectory.appendingPathComponent(
      transactionID, isDirectory: true)
    let backupDirectory = transactionDirectory.appendingPathComponent("backups", isDirectory: true)
    let candidateDirectory = transactionDirectory.appendingPathComponent(
      "candidates", isDirectory: true)
    try files.createDirectory(at: transactionsDirectory)
    try files.createDirectory(at: transactionDirectory)
    try files.createDirectory(at: backupDirectory)
    try files.createDirectory(at: candidateDirectory)
    let receipt = ProjectCreationReceipt(
      status: "created",
      transactionID: transactionID,
      sourceProjectID: source.id,
      project: project,
      dashboardPath: destinationDashboard.path,
      movedTaskIDs: orderedMovedIDs,
      backupDirectory: backupDirectory.path)
    let candidates: [(URL, Data, Data?)] = [
      (destinationDashboard, destinationCandidate, nil),
      (destinationOrder, orderCandidate, nil),
      (configurationURL, configurationCandidate, configurationData),
      (URL(fileURLWithPath: source.dashboardPath), sourceCandidate, sourceData),
    ]
    var records: [ProjectTransactionFileRecord] = []
    for (index, candidate) in candidates.enumerated() {
      let candidateURL = candidateDirectory.appendingPathComponent("\(index).data")
      try files.write(candidate.1, to: candidateURL)
      var backupPath: String?
      if let original = candidate.2 {
        let backupURL = backupDirectory.appendingPathComponent("\(index).data")
        try files.write(original, to: backupURL)
        backupPath = backupURL.path
      }
      records.append(ProjectTransactionFileRecord(
        targetPath: candidate.0.standardizedFileURL.path,
        candidatePath: candidateURL.path,
        backupPath: backupPath,
        originalHash: candidate.2.map(digest),
        intendedHash: digest(candidate.1)))
    }
    let manifest = ProjectTransactionManifest(
      id: transactionID,
      status: .prepared,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      files: records,
      receipt: receipt)
    let manifestURL = transactionDirectory.appendingPathComponent("manifest.json")
    try writeManifest(manifest, to: manifestURL)
    return PreparedTransaction(manifest: manifest, manifestURL: manifestURL)
  }

  /// Reads only the queue fields this transaction needs. Unknown fields and a
  /// future sort-mode value fall back safely without blocking project creation.
  private func readQueueProjectionState() -> (
    mode: QueueActivitySortMode, deferredTicketIDs: [String]
  ) {
    let stateURL = supportDirectory.appendingPathComponent("state.json")
    guard let data = try? Data(contentsOf: stateURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (.recentActivity, []) }
    let decodedMode = (object["queueSortMode"] as? String)
      .flatMap(QueueActivitySortMode.init(rawValue:))
    let mode = decodedMode == .manual
      ? QueueActivitySortMode.recentActivity
      : decodedMode ?? .recentActivity
    let deferred = (object["deferredTicketIDs"] as? [Any])?.compactMap { $0 as? String } ?? []
    return (mode, deferred)
  }

  /// Task context writes are atomic, so a read sees either complete version.
  /// Symlinked and malformed entries are ignored like context discovery.
  private func readTaskContexts(ticketIDs: Set<String>) -> [TaskContext] {
    let tasks = supportDirectory.appendingPathComponent("tasks", isDirectory: true)
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: tasks,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
    else { return [] }
    return entries.compactMap { entry in
      guard ticketIDs.contains(entry.lastPathComponent.uppercased()),
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isDirectory == true, values.isSymbolicLink != true,
        let data = try? Data(contentsOf: entry.appendingPathComponent("context.json")),
        let context = try? JSONDecoder().decode(TaskContext.self, from: data),
        ticketIDs.contains(context.ticketID.uppercased())
      else { return nil }
      return context
    }
  }

  private func validateNoCrossProjectDuplicate(
    taskIDs: [String],
    sourceProjectID: String,
    configuration: AppConfiguration
  ) throws {
    let requested = Set(taskIDs.map { $0.uppercased() })
    for project in configuration.projects where project.id != sourceProjectID {
      let url = URL(fileURLWithPath: project.dashboardPath).standardizedFileURL
      let data = try files.read(from: url)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tickets = object["tickets"] as? [[String: Any]]
      else { throw ProjectCreationError.invalidDashboard(url.path) }
      for ticket in tickets {
        guard let id = ticket["id"] as? String, !id.isEmpty else {
          throw ProjectCreationError.invalidDashboard(url.path)
        }
        if requested.contains(id.uppercased()) {
          throw ProjectCreationError.duplicateTask(id)
        }
      }
    }
  }

  private func apply(_ prepared: PreparedTransaction) throws -> ProjectCreationReceipt {
    var manifest = prepared.manifest
    do {
      try validateRecoveryManifest(
        manifest,
        transactionDirectory: prepared.manifestURL.deletingLastPathComponent())
      for (index, record) in manifest.files.enumerated() {
        let target = URL(fileURLWithPath: record.targetPath)
        if index == 0 { try validateManagedDestination(target, rootName: "projects") }
        if index == 1 { try validateManagedDestination(target, rootName: "queue-order") }
        let current = try currentHash(at: target)
        guard current == record.originalHash else {
          throw ProjectCreationError.concurrentModification
        }
        let candidate = try files.read(from: URL(fileURLWithPath: record.candidatePath))
        guard digest(candidate) == record.intendedHash else {
          throw ProjectCreationError.unsafeRecovery("A staged project file failed verification.")
        }
        try files.write(candidate, to: target)
        try afterTargetWrite?(index + 1, target)
      }
      guard try manifest.files.allSatisfy({ record in
        try currentHash(at: URL(fileURLWithPath: record.targetPath)) == record.intendedHash
      }) else { throw ProjectCreationError.concurrentModification }
      manifest.status = .committed
      try writeManifest(manifest, to: prepared.manifestURL)
      return manifest.receipt
    } catch {
      guard rollbackOnFailure else { throw error }
      do {
        try ensureRecoveryIsSafe(manifest)
        try restoreOriginals(manifest)
        manifest.status = .rolledBack
        try writeManifest(manifest, to: prepared.manifestURL)
      } catch let rollbackError {
        throw ProjectCreationError.unsafeRecovery(
          "Rollback failed after \(error.localizedDescription): \(rollbackError.localizedDescription)")
      }
      throw error
    }
  }

  private func ensureRecoveryIsSafe(_ manifest: ProjectTransactionManifest) throws {
    for record in manifest.files {
      let target = URL(fileURLWithPath: record.targetPath)
      let current = try currentHash(at: target)
      guard current == record.originalHash || current == record.intendedHash else {
        throw ProjectCreationError.unsafeRecovery(target.path)
      }
    }
  }

  private func restoreOriginals(_ manifest: ProjectTransactionManifest) throws {
    for record in manifest.files.reversed() {
      let target = URL(fileURLWithPath: record.targetPath)
      if let backupPath = record.backupPath, let originalHash = record.originalHash {
        let original = try files.read(from: URL(fileURLWithPath: backupPath))
        guard digest(original) == originalHash else {
          throw ProjectCreationError.unsafeRecovery("Backup verification failed for \(target.path)")
        }
        try files.write(original, to: target)
      } else if files.fileExists(at: target) {
        try files.removeItem(at: target)
      }
    }
  }

  private func validateManagedDestination(_ destination: URL, rootName: String) throws {
    let resolvedSupport = supportDirectory.resolvingSymlinksInPath()
    let managedRoot = supportDirectory.appendingPathComponent(rootName, isDirectory: true)
    let resolvedRoot = managedRoot.resolvingSymlinksInPath()
    let resolvedDestination = destination.deletingLastPathComponent()
      .resolvingSymlinksInPath()
      .appendingPathComponent(destination.lastPathComponent)
    guard isContained(resolvedRoot, in: resolvedSupport),
      isContained(resolvedDestination, in: resolvedRoot)
    else {
      throw ProjectCreationError.unsafeRecovery(
        "Managed project path escapes Application Support: \(destination.path)")
    }
  }

  private func validateTransactionContainer(directory: URL, manifestURL: URL) throws {
    let root = transactionsDirectory.standardizedFileURL
    guard directory.deletingLastPathComponent().standardizedFileURL == root,
      !isSymbolicLink(directory),
      !isSymbolicLink(manifestURL),
      isContained(
        root.resolvingSymlinksInPath(),
        in: supportDirectory.resolvingSymlinksInPath()),
      isContained(directory.resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath())
    else {
      throw ProjectCreationError.unsafeRecovery("Invalid project transaction directory.")
    }
  }

  private func validateRecoveryManifest(
    _ manifest: ProjectTransactionManifest,
    transactionDirectory: URL
  ) throws {
    let manifestURL = transactionDirectory.appendingPathComponent("manifest.json")
    try validateTransactionContainer(directory: transactionDirectory, manifestURL: manifestURL)
    guard manifest.id == transactionDirectory.lastPathComponent,
      manifest.receipt.transactionID == manifest.id,
      manifest.files.count == 4,
      Set(manifest.files.map(\.targetPath)).count == manifest.files.count
    else { throw ProjectCreationError.unsafeRecovery("Invalid project transaction manifest.") }

    let projectID = manifest.receipt.project.id
    let projectName = manifest.receipt.project.name
    guard projectID.range(
      of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#,
      options: .regularExpression) != nil,
      projectID.count <= 48,
      projectName == projectName.trimmingCharacters(in: .whitespacesAndNewlines),
      (1...80).contains(projectName.count),
      manifest.receipt.project.workspacePath.hasPrefix("/"),
      (1...100).contains(manifest.receipt.movedTaskIDs.count),
      manifest.receipt.movedTaskIDs.allSatisfy({
        (1...128).contains($0.count)
          && $0.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
            options: .regularExpression) != nil
      })
    else { throw ProjectCreationError.unsafeRecovery("Invalid project receipt.") }
    let expectedDashboard = supportDirectory
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(manifest.receipt.project.id, isDirectory: true)
      .appendingPathComponent("dashboard.json").standardizedFileURL
    let expectedOrder = QueueOrderStore(
      root: supportDirectory,
      projectID: manifest.receipt.project.id).storageURL.standardizedFileURL
    try validateManagedDestination(expectedDashboard, rootName: "projects")
    try validateManagedDestination(expectedOrder, rootName: "queue-order")
    guard manifest.receipt.dashboardPath == expectedDashboard.path,
      manifest.receipt.project.dashboardPath == expectedDashboard.path,
      manifest.files[0].targetPath == expectedDashboard.path,
      manifest.files[1].targetPath == expectedOrder.path,
      manifest.files[2].targetPath == configurationURL.path,
      manifest.files[0].backupPath == nil,
      manifest.files[0].originalHash == nil,
      manifest.files[1].backupPath == nil,
      manifest.files[1].originalHash == nil
    else { throw ProjectCreationError.unsafeRecovery("Project transaction targets changed.") }

    let expectedCandidateDirectory = transactionDirectory.appendingPathComponent(
      "candidates", isDirectory: true)
    let expectedBackupDirectory = transactionDirectory.appendingPathComponent(
      "backups", isDirectory: true)
    for (index, record) in manifest.files.enumerated() {
      let candidate = URL(fileURLWithPath: record.candidatePath).standardizedFileURL
      guard candidate.path
          == expectedCandidateDirectory.appendingPathComponent("\(index).data").standardizedFileURL.path,
        !isSymbolicLink(candidate)
      else { throw ProjectCreationError.unsafeRecovery("Project candidate path changed.") }
      if index >= 2 {
        let backup = try record.backupPath.map {
          URL(fileURLWithPath: $0).standardizedFileURL
        }.orThrow(ProjectCreationError.unsafeRecovery("Project backup is missing."))
        guard backup.path
            == expectedBackupDirectory.appendingPathComponent("\(index).data").standardizedFileURL.path,
          record.originalHash != nil,
          !isSymbolicLink(backup)
        else { throw ProjectCreationError.unsafeRecovery("Project backup path changed.") }
      }
    }
    let originalConfiguration = try files.read(
      from: expectedBackupDirectory.appendingPathComponent("2.data"))
    let configuration = try decodeConfiguration(originalConfiguration)
    let currentConfiguration = try readConfiguration()
    guard let source = configuration.projects.first(where: {
      $0.id.caseInsensitiveCompare(manifest.receipt.sourceProjectID) == .orderedSame
    }),
      let currentSource = currentConfiguration.projects.first(where: {
        $0.id.caseInsensitiveCompare(manifest.receipt.sourceProjectID) == .orderedSame
      }),
      URL(fileURLWithPath: currentSource.dashboardPath).standardizedFileURL
        == URL(fileURLWithPath: source.dashboardPath).standardizedFileURL,
      manifest.files[3].targetPath
        == URL(fileURLWithPath: source.dashboardPath).standardizedFileURL.path
    else { throw ProjectCreationError.unsafeRecovery("Source project target changed.") }
  }

  private func readConfiguration() throws -> AppConfiguration {
    try decodeConfiguration(files.read(from: configurationURL))
  }

  private func decodeConfiguration(_ data: Data) throws -> AppConfiguration {
    do { return try JSONDecoder().decode(AppConfiguration.self, from: data).validated() }
    catch { throw ProjectCreationError.invalidConfiguration }
  }

  private func decodeManifest(at url: URL) throws -> ProjectTransactionManifest {
    try JSONDecoder().decode(ProjectTransactionManifest.self, from: files.read(from: url))
  }

  private func writeManifest(_ manifest: ProjectTransactionManifest, to url: URL) throws {
    try files.write(try prettyEncoder.encode(manifest), to: url)
  }

  private func currentHash(at url: URL) throws -> String? {
    guard files.fileExists(at: url) else { return nil }
    return digest(try files.read(from: url))
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func isContained(_ candidate: URL, in root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private func encodeJSONObject(_ value: Any) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: value,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }

  private var prettyEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

private extension Optional {
  func orThrow(_ error: @autoclosure () -> any Error) throws -> Wrapped {
    guard let self else { throw error() }
    return self
  }
}

private struct PreparedTransaction {
  let manifest: ProjectTransactionManifest
  let manifestURL: URL
}

private struct ProjectTransactionManifest: Codable {
  let id: String
  var status: ProjectTransactionStatus
  let createdAt: String
  let files: [ProjectTransactionFileRecord]
  let receipt: ProjectCreationReceipt
}

private enum ProjectTransactionStatus: String, Codable {
  case prepared
  case committed
  case rolledBack = "rolled-back"
}

private struct ProjectTransactionFileRecord: Codable {
  let targetPath: String
  let candidatePath: String
  let backupPath: String?
  let originalHash: String?
  let intendedHash: String
}
