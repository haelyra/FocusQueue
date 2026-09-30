import Darwin
import Foundation

public struct QueueRouterRuntime: Codable, Equatable, Sendable {
  public let tmuxName: String
  public let tmuxExecutable: String
  public let confirmedReference: TmuxSessionReference?
  public let startedAt: Date
  public let capability: String
  public let objectiveSHA256: String
  public var objective: String?
  public var claimedRouteID: String?

  public init(
    tmux: TmuxSessionReference, startedAt: Date,
    capability: String = UUID().uuidString.lowercased(), objectiveSHA256: String = "",
    objective: String? = nil,
    claimedRouteID: String? = nil
  ) {
    tmuxName = tmux.name
    tmuxExecutable = tmux.executable
    confirmedReference = tmux
    self.startedAt = startedAt
    self.capability = capability
    self.objectiveSHA256 = objectiveSHA256
    self.objective = objective
    self.claimedRouteID = claimedRouteID
  }

  public init(
    tmuxName: String, tmuxExecutable: String, startedAt: Date,
    capability: String = UUID().uuidString.lowercased(), objectiveSHA256: String = "",
    objective: String? = nil,
    claimedRouteID: String? = nil
  ) throws {
    try TmuxController.validateName(tmuxName)
    guard tmuxExecutable.hasPrefix("/"), UUID(uuidString: capability) != nil else {
      throw TmuxError.unavailable("The saved router has no absolute tmux executable.")
    }
    self.tmuxName = tmuxName
    self.tmuxExecutable = tmuxExecutable
    confirmedReference = nil
    self.startedAt = startedAt
    self.capability = capability.lowercased()
    self.objectiveSHA256 = objectiveSHA256
    self.objective = objective
    self.claimedRouteID = claimedRouteID
  }

  private enum CodingKeys: String, CodingKey {
    case tmuxName, tmuxExecutable, confirmedReference, startedAt
    case capability, objectiveSHA256, objective, claimedRouteID
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    tmuxName = try values.decode(String.self, forKey: .tmuxName)
    tmuxExecutable = try values.decode(String.self, forKey: .tmuxExecutable)
    confirmedReference = try values.decodeIfPresent(
      TmuxSessionReference.self, forKey: .confirmedReference)
    startedAt = try values.decode(Date.self, forKey: .startedAt)
    capability = try values.decode(String.self, forKey: .capability)
    objectiveSHA256 = try values.decode(String.self, forKey: .objectiveSHA256)
    objective = try values.decodeIfPresent(String.self, forKey: .objective)
    claimedRouteID = try values.decodeIfPresent(String.self, forKey: .claimedRouteID)
    try validate()
  }

  public func encode(to encoder: any Encoder) throws {
    try validate()
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(tmuxName, forKey: .tmuxName)
    try values.encode(tmuxExecutable, forKey: .tmuxExecutable)
    try values.encodeIfPresent(confirmedReference, forKey: .confirmedReference)
    try values.encode(startedAt, forKey: .startedAt)
    try values.encode(capability.lowercased(), forKey: .capability)
    try values.encode(objectiveSHA256, forKey: .objectiveSHA256)
    try values.encodeIfPresent(objective, forKey: .objective)
    try values.encodeIfPresent(claimedRouteID?.lowercased(), forKey: .claimedRouteID)
  }

  private func validate() throws {
    try TmuxController.validateName(tmuxName)
    guard tmuxExecutable.hasPrefix("/"), !tmuxExecutable.contains("\0"),
          UUID(uuidString: capability) != nil,
          objectiveSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          objective.map({
            !$0.isEmpty && $0.utf8.count <= 100_000
              && $0.trimmingCharacters(in: .whitespacesAndNewlines) == $0
              && AgentStartupReceipt.promptDigest($0) == objectiveSHA256
          }) ?? true,
          claimedRouteID.map({ UUID(uuidString: $0) != nil }) ?? true,
          confirmedReference.map({
            $0.name == tmuxName && $0.executable == tmuxExecutable
              && $0.serverPID > 0 && $0.panePID > 0
              && $0.paneID.range(of: "^%[0-9]+$", options: .regularExpression) != nil
              && $0.tty.hasPrefix("/dev/")
          }) ?? true else {
      throw TaskContextError.commandFailed("The saved queue-router recovery identity is invalid.")
    }
  }
}

/// Tracks every live one-shot queue router. Each router owns a record under
/// `agent-routes/routers/<router tmux name>.json`, keyed by its tmux session
/// name so concurrent routers never cross-talk. Up to
/// `maximumActiveRouters` routers may run at once; the legacy single record
/// `active-queue-router.json` still counts as one active router so an
/// in-flight router from an older app version resolves normally.
public struct QueueRouterRuntimeStore: Sendable {
  public static let maximumActiveRouters = 4

  public let root: URL

  public init(root: URL) { self.root = root }

  private var directory: URL {
    root.appendingPathComponent("agent-routes", isDirectory: true)
  }

  /// The legacy single-router record, kept as the recovery locator and honored
  /// as one active router while it exists.
  public var url: URL {
    directory.appendingPathComponent("active-queue-router.json")
  }

  private var routersDirectory: URL {
    directory.appendingPathComponent("routers", isDirectory: true)
  }

  public func url(routerID: String) throws -> URL {
    try TmuxController.validateName(routerID)
    return routersDirectory.appendingPathComponent(routerID + ".json")
  }

  public func save(_ runtime: QueueRouterRuntime) throws {
    let destination = try url(routerID: runtime.tmuxName)
    try FileManager.default.createDirectory(
      at: routersDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try withLock {
      var merged = runtime
      var migratedLegacy = false
      var saved = try load(routerID: runtime.tmuxName)
      if saved == nil, let legacy = try loadLegacy(), legacy.tmuxName == runtime.tmuxName {
        saved = legacy
        migratedLegacy = true
      }
      if let saved {
        guard saved.capability == runtime.capability else {
          throw TaskContextError.commandFailed(
            "Another queue router owns the active recovery record.")
        }
        if let claimedRouteID = saved.claimedRouteID {
          merged.claimedRouteID = claimedRouteID
        }
        guard saved.objective == nil || runtime.objective == nil
                || saved.objective == runtime.objective else {
          throw TaskContextError.commandFailed(
            "The queue router's authorized objective changed.")
        }
        merged.objective = saved.objective ?? runtime.objective
        if let confirmed = saved.confirmedReference {
          guard runtime.confirmedReference == nil
                  || runtime.confirmedReference == confirmed else {
            throw TaskContextError.commandFailed(
              "The queue router's confirmed terminal identity changed.")
          }
          merged = QueueRouterRuntime(
            tmux: confirmed, startedAt: saved.startedAt,
            capability: saved.capability,
            objectiveSHA256: saved.objectiveSHA256,
            objective: merged.objective,
            claimedRouteID: merged.claimedRouteID)
        }
      }
      try saveUnlocked(merged, to: destination)
      if migratedLegacy {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  /// Reserves one router slot. Returns the conflicting record when this exact
  /// tmux identity is already reserved, and throws once
  /// `maximumActiveRouters` concurrent routers are active.
  public func reserve(_ runtime: QueueRouterRuntime) throws -> QueueRouterRuntime? {
    try FileManager.default.createDirectory(
      at: routersDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return try withLock {
      if let saved = try load(matching: runtime.tmuxName) { return saved }
      guard try activeRoutersUnlocked().count < Self.maximumActiveRouters else {
        throw TaskContextError.commandFailed(
          "Focus Queue already runs \(Self.maximumActiveRouters) routers. Wait for one to finish before routing another objective.")
      }
      try saveUnlocked(runtime, to: url(routerID: runtime.tmuxName))
      return nil
    }
  }

  /// The single active router, for callers from before parallel routers: the
  /// legacy record when present, otherwise the only per-router record.
  public func load() throws -> QueueRouterRuntime? {
    if let legacy = try loadLegacy() { return legacy }
    let records = try perRouterRecords()
    return records.count == 1 ? records[0] : nil
  }

  /// The record for one router identity: its per-router record, or the legacy
  /// record while an older app's router with that tmux name is still tracked.
  public func load(routerID: String) throws -> QueueRouterRuntime? {
    let source = try url(routerID: routerID)
    guard let data = try secureAgentRoutingData(at: source) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(QueueRouterRuntime.self, from: data)
    guard record.tmuxName == routerID else {
      throw TaskContextError.commandFailed("The router recovery record is misfiled.")
    }
    return record
  }

  public func load(matching tmuxName: String) throws -> QueueRouterRuntime? {
    if let record = try load(routerID: tmuxName) { return record }
    if let legacy = try loadLegacy(), legacy.tmuxName == tmuxName { return legacy }
    return nil
  }

  /// Every active router: per-router records plus the legacy record when no
  /// per-router record owns the same tmux identity. Unreadable records fail
  /// closed so a damaged reservation blocks new routing instead of being lost.
  public func activeRouters() throws -> [QueueRouterRuntime] {
    try withLock { try activeRoutersUnlocked() }
  }

  public func clear(matching tmuxName: String) throws {
    try withLock {
      if let destination = try? url(routerID: tmuxName),
         FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      if let legacy = try loadLegacy(), legacy.tmuxName == tmuxName {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  public func claimRoute(
    capability: String, sourceTmuxName: String, prompt: String, routeID: String
  ) throws -> String {
    guard UUID(uuidString: capability) != nil, UUID(uuidString: routeID) != nil else {
      throw TaskContextError.commandFailed("The queue router capability is invalid.")
    }
    return try withLock {
      guard let located = try locatedRecord(
        capability: capability, sourceTmuxName: sourceTmuxName) else {
        throw TaskContextError.commandFailed(
          "This queue router is not authorized for the submitted objective.")
      }
      var runtime = located.record
      let authoritativePrompt = runtime.objective ?? prompt
      guard runtime.objectiveSHA256 == AgentStartupReceipt.promptDigest(authoritativePrompt),
            runtime.objective != nil
              || runtime.objectiveSHA256 == AgentStartupReceipt.promptDigest(prompt) else {
        throw TaskContextError.commandFailed(
          "This queue router is not authorized for the submitted objective.")
      }
      guard runtime.claimedRouteID == nil else {
        throw TaskContextError.commandFailed(
          "This queue router already inspected its one allowed route.")
      }
      runtime.claimedRouteID = routeID.lowercased()
      try saveUnlocked(runtime, to: located.destination)
      return authoritativePrompt
    }
  }

  public func authorizeStart(
    capability: String, sourceTmuxName: String, routeID: String
  ) throws {
    guard let located = try locatedRecord(
      capability: capability, sourceTmuxName: sourceTmuxName),
          located.record.claimedRouteID == routeID.lowercased() else {
      throw TaskContextError.commandFailed(
        "This route start is not authorized by the active queue router.")
    }
  }

  public func releaseClaim(capability: String, routeID: String) throws {
    try withLock {
      for record in try allRecordsUnlocked() where record.record.claimedRouteID == routeID.lowercased()
        && record.record.capability.caseInsensitiveCompare(capability) == .orderedSame {
        var runtime = record.record
        runtime.claimedRouteID = nil
        try saveUnlocked(runtime, to: record.destination)
      }
    }
  }

  private func loadLegacy() throws -> QueueRouterRuntime? {
    guard let data = try secureAgentRoutingData(at: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(QueueRouterRuntime.self, from: data)
  }

  private func perRouterRecords() throws -> [QueueRouterRuntime] {
    guard FileManager.default.fileExists(atPath: routersDirectory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: routersDirectory, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "json" }
      .map { source in
        let routerID = source.deletingPathExtension().lastPathComponent
        guard let record = try load(routerID: routerID) else {
          throw TaskContextError.commandFailed("The router recovery record is unreadable.")
        }
        return record
      }
      .sorted { $0.startedAt < $1.startedAt }
  }

  private func activeRoutersUnlocked() throws -> [QueueRouterRuntime] {
    var records = try perRouterRecords()
    if let legacy = try loadLegacy(),
       !records.contains(where: { $0.tmuxName == legacy.tmuxName }) {
      records.append(legacy)
    }
    return records.sorted { $0.startedAt < $1.startedAt }
  }

  private func allRecordsUnlocked() throws -> [(record: QueueRouterRuntime, destination: URL)] {
    var records = try perRouterRecords().map {
      (record: $0, destination: try url(routerID: $0.tmuxName))
    }
    if let legacy = try loadLegacy(),
       !records.contains(where: { $0.record.tmuxName == legacy.tmuxName }) {
      records.append((record: legacy, destination: url))
    }
    return records
  }

  private func locatedRecord(
    capability: String, sourceTmuxName: String
  ) throws -> (record: QueueRouterRuntime, destination: URL)? {
    guard UUID(uuidString: capability) != nil else { return nil }
    for record in try allRecordsUnlocked()
    where record.record.tmuxName == sourceTmuxName
      && record.record.capability.caseInsensitiveCompare(capability) == .orderedSame {
      return record
    }
    return nil
  }

  private func withLock<T>(_ body: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let lock = directory.appendingPathComponent("active-queue-router.lock")
    let descriptor = Darwin.open(
      lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }

  private func saveUnlocked(_ runtime: QueueRouterRuntime, to destination: URL) throws {
    let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values?.isSymbolicLink != true else {
      throw TaskContextError.commandFailed("The router recovery record is an unsafe symbolic link.")
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(runtime).write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }
}

public struct QueueRouterLaunchUnconfirmedError: Error, LocalizedError, Sendable {
  public let runtime: QueueRouterRuntime
  public let detail: String

  public var errorDescription: String? {
    "The router may be running, but its terminal identity is not confirmed. Focus Queue retained recovery session \(runtime.tmuxName) and will not start a duplicate. \(detail)"
  }
}

public enum QueueRouterOutcome: Equatable, Sendable {
  case waiting(routeID: String?, recoveryPath: String?)
  case registered(routeID: String, taskID: String, subtaskID: String)
  case failed(routeID: String, recoveryPath: String?, message: String)
}

public protocol QueueObjectiveRouting: Sendable {
  func launch(
    objective: String,
    repositoryPath: String,
    supportDirectory: URL,
    tmuxExecutable: String,
    shellPath: String?
  ) async throws -> QueueRouterRuntime

  func launch(
    objective: String,
    repositoryPath: String,
    supportDirectory: URL,
    tmuxExecutable: String,
    shellPath: String?,
    provider: AgentProvider,
    model: String?
  ) async throws -> QueueRouterRuntime

  func waitForOutcome(
    _ runtime: QueueRouterRuntime,
    supportDirectory: URL,
    timeoutSeconds: Double
  ) async throws -> QueueRouterOutcome

  func recoveryReference(
    _ runtime: QueueRouterRuntime,
    supportDirectory: URL
  ) async throws -> TmuxSessionReference
}

public extension QueueObjectiveRouting {
  func launch(
    objective: String,
    repositoryPath: String,
    supportDirectory: URL,
    tmuxExecutable: String,
    shellPath: String?,
    provider _: AgentProvider,
    model _: String?
  ) async throws -> QueueRouterRuntime {
    try await launch(
      objective: objective, repositoryPath: repositoryPath,
      supportDirectory: supportDirectory, tmuxExecutable: tmuxExecutable,
      shellPath: shellPath)
  }

  func recoveryReference(
    _ runtime: QueueRouterRuntime,
    supportDirectory _: URL
  ) async throws -> TmuxSessionReference {
    guard let reference = runtime.confirmedReference else {
      throw TmuxError.unavailable("The router terminal is not confirmed yet.")
    }
    return reference
  }
}

/// Starts a short-lived, unassigned router in a detached tmux session. The
/// router's existing global contract owns inspection and the single successor
/// launch; this type never creates a task or agent record itself.
public actor QueueObjectiveRouter: QueueObjectiveRouting {
  private let runner: any ProcessRunning
  private let tmuxServerName: String
  private let identifier: @Sendable () -> UUID
  private let confirmationAttempts: Int
  private let confirmationDelayMilliseconds: Int

  public init(
    runner: any ProcessRunning = FoundationProcessRunner(),
    tmuxServerName: String = TmuxController.serverName,
    identifier: @escaping @Sendable () -> UUID = UUID.init,
    confirmationAttempts: Int = 120,
    confirmationDelayMilliseconds: Int = 250
  ) {
    self.runner = runner
    self.tmuxServerName = tmuxServerName
    self.identifier = identifier
    self.confirmationAttempts = confirmationAttempts
    self.confirmationDelayMilliseconds = confirmationDelayMilliseconds
  }

  public static func command(
    objective: String,
    repositoryPath: String,
    supportDirectory: URL,
    capability: String = UUID().uuidString.lowercased(),
    shellPath: String? = nil,
    provider: AgentProvider = .codex,
    model: String? = nil
  ) -> [String] {
    let cleared = [
      "FOCUS_QUEUE_TASK_ID", "FOCUS_QUEUE_SUBTASK_ID", "FOCUS_QUEUE_RUNTIME_MODE",
      "FOCUS_QUEUE_AGENT_CONTEXT", "FOCUS_QUEUE_AGENT_ROLE", "FOCUS_QUEUE_LAUNCH_ID",
      "FOCUS_QUEUE_ROUTER_CAPABILITY",
    ].flatMap { ["-u", $0] }
    let environment = [
      "FOCUS_QUEUE_SUPPORT_DIR=\(supportDirectory.path)",
      "FOCUS_QUEUE_ROUTER=1",
      "FOCUS_QUEUE_ROUTER_SOURCE=queue-composer",
      "FOCUS_QUEUE_ROUTER_CAPABILITY=\(capability)",
    ]
    var providerArguments: [String] = []
    if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
      providerArguments += ["--model", model]
    }
    providerArguments += provider == .kimi ? ["--prompt", objective] : [objective]
    return ["/usr/bin/env"] + cleared + environment + InteractiveAgentShell.command(
      provider: provider, arguments: providerArguments, shellPath: shellPath,
      workingDirectory: repositoryPath)
  }

  public func launch(
    objective: String,
    repositoryPath: String,
    supportDirectory: URL,
    tmuxExecutable: String,
    shellPath: String?
  ) async throws -> QueueRouterRuntime {
    try await launch(
      objective: objective, repositoryPath: repositoryPath,
      supportDirectory: supportDirectory, tmuxExecutable: tmuxExecutable,
      shellPath: shellPath, provider: .codex, model: nil)
  }

  public func launch(
    objective: String,
    repositoryPath: String,
    supportDirectory: URL,
    tmuxExecutable: String,
    shellPath: String? = nil,
    provider: AgentProvider = .codex,
    model: String? = nil
  ) async throws -> QueueRouterRuntime {
    let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !objective.isEmpty else {
      throw TaskContextError.commandFailed("Describe the work before starting the router.")
    }
    guard objective.utf8.count <= 100_000 else {
      throw TaskContextError.commandFailed("The router objective must be 100 KB or less.")
    }
    let repository = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
    guard repository.hasPrefix("/") else {
      throw TaskContextError.unsafeWorktree("Choose an absolute project repository before routing work.")
    }
    let routerID = identifier().uuidString.lowercased()
    let name = try TmuxController.sessionName(subtaskID: "router-\(routerID)")
    let startedAt = Date()
    let capability = UUID().uuidString.lowercased()
    let pending = try QueueRouterRuntime(
      tmuxName: name, tmuxExecutable: tmuxExecutable, startedAt: startedAt,
      capability: capability, objectiveSHA256: AgentStartupReceipt.promptDigest(objective),
      objective: objective)
    let store = QueueRouterRuntimeStore(root: supportDirectory)
    if let existing = try store.reserve(pending) {
      throw QueueRouterLaunchUnconfirmedError(
        runtime: existing,
        detail: "Another Focus Queue window already reserved this router.")
    }
    let controller = TmuxController(
      runner: runner, serverName: tmuxServerName,
      confirmationAttempts: confirmationAttempts,
      confirmationDelayMilliseconds: confirmationDelayMilliseconds)
    do {
      let tmux = try await controller.start(
        name: name,
        directory: repository,
        command: Self.command(
          objective: objective, repositoryPath: repository,
          supportDirectory: supportDirectory, capability: capability, shellPath: shellPath,
          provider: provider, model: model),
        executable: tmuxExecutable)
      let confirmed = QueueRouterRuntime(
        tmux: tmux, startedAt: startedAt, capability: capability,
        objectiveSHA256: pending.objectiveSHA256, objective: objective)
      do { try store.save(confirmed) }
      catch {
        throw QueueRouterLaunchUnconfirmedError(
          runtime: confirmed, detail: error.localizedDescription)
      }
      return confirmed
    } catch let error as QueueRouterLaunchUnconfirmedError {
      throw error
    } catch let launchError {
      do {
        let recovered = try await controller.inspect(name: name, executable: tmuxExecutable)
        let runtime = QueueRouterRuntime(
          tmux: recovered, startedAt: startedAt, capability: capability,
          objectiveSHA256: pending.objectiveSHA256, objective: objective)
        try store.save(runtime)
        return runtime
      } catch TmuxError.stopped {
        try? store.clear(matching: name)
        throw launchError
      } catch {
        throw QueueRouterLaunchUnconfirmedError(
          runtime: pending, detail: launchError.localizedDescription)
      }
    }
  }

  public func waitForOutcome(
    _ runtime: QueueRouterRuntime,
    supportDirectory: URL,
    timeoutSeconds: Double = 120
  ) async throws -> QueueRouterOutcome {
    let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
    while true {
      let outcome = try await currentOutcome(runtime, supportDirectory: supportDirectory)
      if case .waiting = outcome, Date() < deadline {
        try await Task.sleep(for: .milliseconds(250))
        continue
      }
      if case .registered(let routeID, let taskID, _) = outcome {
        do {
          try await closeRegisteredRouter(runtime, supportDirectory: supportDirectory)
        } catch {
          return .failed(
            routeID: routeID,
            recoveryPath: Self.recoveryPath(runtime, supportDirectory: supportDirectory),
            message: "Assigned to \(taskID), but the router terminal \(runtime.tmuxName) could not be closed safely. Its reservation was cleared so routing continues; close that tmux session manually if it still runs. \(error.localizedDescription)")
        }
      }
      return outcome
    }
  }

  private static func recoveryPath(
    _ runtime: QueueRouterRuntime, supportDirectory: URL
  ) -> String {
    let store = QueueRouterRuntimeStore(root: supportDirectory)
    return (try? store.url(routerID: runtime.tmuxName).path) ?? store.url.path
  }

  public func currentOutcome(
    _ runtime: QueueRouterRuntime,
    supportDirectory: URL
  ) async throws -> QueueRouterOutcome {
    let routeStore = AgentRouteStore(root: supportDirectory)
    guard let intent = try routeStore.latest(
      sourceTmuxName: runtime.tmuxName, createdAfter: runtime.startedAt)
    else { return .waiting(routeID: nil, recoveryPath: nil) }
    let routePath = try routeStore.intentURL(routeID: intent.routeID).path
    guard let taskID = intent.taskID, let subtaskID = intent.subtaskID else {
      return .waiting(routeID: intent.routeID, recoveryPath: routePath)
    }
    let receipts = AgentStartupReceiptStore(root: supportDirectory)
    let receiptPath = try receipts.url(taskID: taskID, subtaskID: subtaskID).path
    guard let receipt = try receipts.load(taskID: taskID, subtaskID: subtaskID) else {
      return .waiting(routeID: intent.routeID, recoveryPath: routePath)
    }
    switch receipt.status {
    case .registered where receipt.handoffCompletedAt != nil:
      return .registered(
        routeID: intent.routeID, taskID: taskID, subtaskID: subtaskID)
    case .registered:
      // A router that exited before finalizing its receipt still completes
      // once the successor's registration is observable.
      if await completeObservedHandoff(receipt, supportDirectory: supportDirectory) {
        return .registered(
          routeID: intent.routeID, taskID: taskID, subtaskID: subtaskID)
      }
      return .waiting(routeID: intent.routeID, recoveryPath: receiptPath)
    case .failed:
      return .failed(
        routeID: intent.routeID, recoveryPath: receiptPath,
        message: "The router could not start the assigned agent.")
    case .starting, .launched:
      return .waiting(routeID: intent.routeID, recoveryPath: receiptPath)
    }
  }

  private func completeObservedHandoff(
    _ receipt: AgentStartupReceipt, supportDirectory: URL
  ) async -> Bool {
    guard await AgentStartupObserver(root: supportDirectory).observes(receipt) else {
      return false
    }
    return (try? AgentStartupReceiptStore(root: supportDirectory).completeObservedHandoff(
      taskID: receipt.taskID, subtaskID: receipt.subtaskID,
      sessionID: receipt.providerSessionID)) ?? false
  }

  public func recoveryReference(
    _ runtime: QueueRouterRuntime,
    supportDirectory: URL
  ) async throws -> TmuxSessionReference {
    let controller = TmuxController(runner: runner, serverName: tmuxServerName)
    let runtime = try currentStoredRuntime(runtime, supportDirectory: supportDirectory)
    do {
      let reference: TmuxSessionReference
      if let confirmed = runtime.confirmedReference {
        reference = try await controller.verify(confirmed)
      } else {
        reference = try await controller.inspect(
          name: runtime.tmuxName, executable: runtime.tmuxExecutable)
        try QueueRouterRuntimeStore(root: supportDirectory).save(
          QueueRouterRuntime(
            tmux: reference, startedAt: runtime.startedAt,
            capability: runtime.capability, objectiveSHA256: runtime.objectiveSHA256,
            objective: runtime.objective,
            claimedRouteID: runtime.claimedRouteID))
      }
      return reference
    } catch TmuxError.stopped {
      let outcome = try await currentOutcome(runtime, supportDirectory: supportDirectory)
      switch outcome {
      case .waiting(nil, _):
        try QueueRouterRuntimeStore(root: supportDirectory).clear(
          matching: runtime.tmuxName)
      case .waiting(let routeID?, _):
        let routeStore = AgentRouteStore(root: supportDirectory)
        if let intent = try routeStore.load(routeID: routeID), intent.startedAt == nil,
           intent.taskID == nil, intent.subtaskID == nil {
          try routeStore.retireUnstarted(
            routeID: routeID, sourceTmuxName: runtime.tmuxName)
          try QueueRouterRuntimeStore(root: supportDirectory).clear(
            matching: runtime.tmuxName)
        }
      case .registered, .failed:
        break
      }
      throw TmuxError.stopped
    }
  }

  private func closeRegisteredRouter(
    _ runtime: QueueRouterRuntime,
    supportDirectory: URL
  ) async throws {
    let controller = TmuxController(runner: runner, serverName: tmuxServerName)
    let runtime = try currentStoredRuntime(runtime, supportDirectory: supportDirectory)
    do {
      let reference = if let confirmed = runtime.confirmedReference {
        try await controller.verify(confirmed)
      } else {
        try await controller.inspect(
          name: runtime.tmuxName, executable: runtime.tmuxExecutable)
      }
      try await controller.stop(reference)
    } catch TmuxError.stopped { }
    catch {
      // A stuck terminal must never hold a router slot: free the reservation
      // and let the caller surface the orphan session for manual recovery.
      try? QueueRouterRuntimeStore(root: supportDirectory).clear(matching: runtime.tmuxName)
      throw error
    }
    try QueueRouterRuntimeStore(root: supportDirectory).clear(matching: runtime.tmuxName)
  }

  private func currentStoredRuntime(
    _ runtime: QueueRouterRuntime,
    supportDirectory: URL
  ) throws -> QueueRouterRuntime {
    guard let saved = try QueueRouterRuntimeStore(root: supportDirectory)
      .load(matching: runtime.tmuxName) else {
      guard runtime.confirmedReference != nil else { throw TmuxError.changed }
      return runtime
    }
    guard saved.capability == runtime.capability else {
      throw TmuxError.changed
    }
    return saved
  }
}
