import Foundation

/// The only action accepted by the compatibility-isolated scheduled resume
/// store. Unknown actions fail decoding instead of becoming agent launches.
public enum ScheduledAgentResumeAction: String, Codable, Equatable, Sendable {
  case resumeExistingAgent
}

public enum ScheduledAgentResumeState: String, Codable, Equatable, Sendable {
  case pending
  case claimed
  case completed
  case failed
  case expired

  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .expired: true
    case .pending, .claimed: false
    }
  }
}

/// Immutable identity that a scheduled action must still own when it fires.
public struct ScheduledAgentResumeTarget: Codable, Equatable, Sendable {
  public var taskID: String
  public var agentID: String
  public var provider: AgentProvider
  public var sessionID: String
  public var workspacePath: String
  public var runtime: TmuxSessionReference

  public init(taskID: String, agentID: String, provider: AgentProvider,
              sessionID: String, workspacePath: String, runtime: TmuxSessionReference) {
    self.taskID = taskID
    self.agentID = agentID
    self.provider = provider
    self.sessionID = sessionID
    self.workspacePath = workspacePath
    self.runtime = runtime
  }
}

/// A one-shot prompt owed to one already-running provider conversation.
/// It can never be interpreted as a fresh launch because it lives outside
/// `scheduled-launches.json` and carries an explicit action discriminator.
public struct ScheduledAgentResume: Codable, Equatable, Sendable, Identifiable {
  public var action: ScheduledAgentResumeAction
  public var id: String
  public var createdAt: Date
  public var fireAt: Date
  /// Absolute latest delivery. Dispatch after this time is forbidden.
  public var expiresAt: Date
  public var title: String
  public var prompt: String
  public var target: ScheduledAgentResumeTarget
  public var state: ScheduledAgentResumeState
  public var claimedAt: Date?
  public var finishedAt: Date?
  public var outcomeDetail: String?

  public init(action: ScheduledAgentResumeAction = .resumeExistingAgent,
              id: String = UUID().uuidString, createdAt: Date = Date(),
              fireAt: Date, expiresAt: Date, title: String, prompt: String,
              target: ScheduledAgentResumeTarget,
              state: ScheduledAgentResumeState = .pending,
              claimedAt: Date? = nil, finishedAt: Date? = nil, outcomeDetail: String? = nil) {
    self.action = action
    self.id = id
    self.createdAt = createdAt
    self.fireAt = fireAt
    self.expiresAt = expiresAt
    self.title = title
    self.prompt = prompt
    self.target = target
    self.state = state
    self.claimedAt = claimedAt
    self.finishedAt = finishedAt
    self.outcomeDetail = outcomeDetail
  }

  public var isPending: Bool { state == .pending }
}

public struct ScheduledAgentResumeClaimBatch: Sendable, Equatable {
  public var claimed: [ScheduledAgentResume]
  public var expired: [ScheduledAgentResume]

  public init(claimed: [ScheduledAgentResume] = [], expired: [ScheduledAgentResume] = []) {
    self.claimed = claimed
    self.expired = expired
  }
}

public enum ScheduledAgentResumeStoreError: Error, LocalizedError, Equatable {
  case unsupportedSchema(Int)
  case invalidAction(String)
  case invalidSchedule(String)
  case duplicateID(String)
  case missing(String)
  case notPending(String, ScheduledAgentResumeState)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let version):
      "Scheduled agent resumes use unsupported schema version \(version). Update Focus Queue before changing them."
    case .invalidAction(let action):
      "Scheduled action \(action) is unsupported and was not dispatched."
    case .invalidSchedule(let detail): detail
    case .duplicateID(let id): "A scheduled agent resume already has id \(id)."
    case .missing(let id): "No scheduled agent resume has id \(id)."
    case .notPending(let id, let state):
      "Scheduled agent resume \(id) is \(state.rawValue) and can no longer be changed."
    }
  }
}

/// Versioned, locked persistence for existing-agent resume actions. Every
/// read-modify-write operation takes the same cross-process file lock.
public struct ScheduledAgentResumeStore: Sendable {
  public static let schemaVersion = 1
  public static let terminalRetention: TimeInterval = 2 * 86_400
  public static let maximumTerminalRecords = 300

  public let file: URL

  public init(supportDirectory: URL) {
    file = supportDirectory.appendingPathComponent("scheduled-agent-resumes.json")
  }

  public init(file: URL) { self.file = file }

  public func load() throws -> [ScheduledAgentResume] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try decode(Data(contentsOf: file)).actions.sorted(by: Self.sort)
  }

  @discardableResult
  public func add(_ action: ScheduledAgentResume) throws -> ScheduledAgentResume {
    try validate(action)
    return try mutate { actions in
      guard !actions.contains(where: { $0.id == action.id }) else {
        throw ScheduledAgentResumeStoreError.duplicateID(action.id)
      }
      actions.append(action)
      return action
    }
  }

  @discardableResult
  public func cancel(id: String) throws -> ScheduledAgentResume? {
    try mutate { actions in
      guard let index = actions.firstIndex(where: { $0.id == id }) else { return nil }
      guard actions[index].state == .pending else {
        throw ScheduledAgentResumeStoreError.notPending(id, actions[index].state)
      }
      return actions.remove(at: index)
    }
  }

  @discardableResult
  public func retime(id: String, fireAt: Date) throws -> ScheduledAgentResume? {
    try mutate { actions in
      guard let index = actions.firstIndex(where: { $0.id == id }) else { return nil }
      guard actions[index].state == .pending else {
        throw ScheduledAgentResumeStoreError.notPending(id, actions[index].state)
      }
      guard fireAt <= actions[index].expiresAt else {
        throw ScheduledAgentResumeStoreError.invalidSchedule(
          "The new fire time is after this resume's latest delivery time.")
      }
      actions[index].fireAt = fireAt
      return actions[index]
    }
  }

  /// Atomically marks every due action before returning any side effect work.
  /// A claimed action is never eligible again, including after a crash.
  public func claimDue(now: Date = Date()) throws -> ScheduledAgentResumeClaimBatch {
    try mutate(now: now) { actions in
      var batch = ScheduledAgentResumeClaimBatch()
      for index in actions.indices where actions[index].state == .pending && actions[index].fireAt <= now {
        if now > actions[index].expiresAt {
          actions[index].state = .expired
          actions[index].finishedAt = now
          actions[index].outcomeDetail = "Latest delivery passed before dispatch."
          batch.expired.append(actions[index])
        } else {
          actions[index].state = .claimed
          actions[index].claimedAt = now
          batch.claimed.append(actions[index])
        }
      }
      batch.claimed.sort(by: Self.sort)
      batch.expired.sort(by: Self.sort)
      return batch
    }
  }

  @discardableResult
  public func finishClaim(id: String, state: ScheduledAgentResumeState,
                          detail: String, at date: Date = Date()) throws -> ScheduledAgentResume {
    guard state == .completed || state == .failed else {
      throw ScheduledAgentResumeStoreError.invalidSchedule("A dispatch claim may finish only as completed or failed.")
    }
    return try mutate(now: date) { actions in
      guard let index = actions.firstIndex(where: { $0.id == id }) else {
        throw ScheduledAgentResumeStoreError.missing(id)
      }
      guard actions[index].state == .claimed else {
        throw ScheduledAgentResumeStoreError.notPending(id, actions[index].state)
      }
      actions[index].state = state
      actions[index].finishedAt = date
      actions[index].outcomeDetail = detail
      return actions[index]
    }
  }

  private struct Envelope: Codable {
    var schemaVersion: Int
    var actions: [ScheduledAgentResume]
  }

  private func decode(_ data: Data) throws -> Envelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(Envelope.self, from: data)
    guard envelope.schemaVersion == Self.schemaVersion else {
      throw ScheduledAgentResumeStoreError.unsupportedSchema(envelope.schemaVersion)
    }
    guard envelope.actions.allSatisfy({ $0.action == .resumeExistingAgent }) else {
      throw ScheduledAgentResumeStoreError.invalidAction("unknown")
    }
    return envelope
  }

  private func mutate<T>(now: Date = Date(), _ operation: (inout [ScheduledAgentResume]) throws -> T) throws -> T {
    try FocusQueueFileLock.withLocks(for: [file]) {
      var actions: [ScheduledAgentResume]
      if FileManager.default.fileExists(atPath: file.path) {
        actions = try decode(Data(contentsOf: file)).actions
      } else {
        actions = []
      }
      let result = try operation(&actions)
      actions = Self.pruned(actions, now: now).sorted(by: Self.sort)
      try write(actions)
      return result
    }
  }

  private func write(_ actions: [ScheduledAgentResume]) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Envelope(schemaVersion: Self.schemaVersion, actions: actions))
    try data.write(to: file, options: .atomic)
  }

  private func validate(_ action: ScheduledAgentResume) throws {
    guard action.action == .resumeExistingAgent, action.state == .pending,
          !action.id.isEmpty, !action.target.taskID.isEmpty, !action.target.agentID.isEmpty,
          !action.target.sessionID.isEmpty, !action.target.workspacePath.isEmpty,
          !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          action.fireAt <= action.expiresAt else {
      throw ScheduledAgentResumeStoreError.invalidSchedule(
        "A scheduled resume needs a pending action, pinned target, prompt, and latest delivery at or after its fire time.")
    }
  }

  private static func pruned(_ actions: [ScheduledAgentResume], now: Date) -> [ScheduledAgentResume] {
    let cutoff = now.addingTimeInterval(-terminalRetention)
    let active = actions.filter { !$0.state.isTerminal }
    let terminal = actions.filter { action in
      action.state.isTerminal && (action.finishedAt ?? action.createdAt) >= cutoff
    }.sorted(by: sort)
    return active + terminal.suffix(maximumTerminalRecords)
  }

  private static func sort(_ left: ScheduledAgentResume, _ right: ScheduledAgentResume) -> Bool {
    (left.fireAt, left.id) < (right.fireAt, right.id)
  }
}

public enum ScheduledAgentResumeDispatchError: Error, LocalizedError, Equatable {
  case missingTask(String)
  case missingAgent(String)
  case targetChanged(String)
  case ineligible(String)
  case providerNotLive(String)
  case providerIdentityChanged(String)
  case expired(Date)
  case deliveryUnknown(String)

  public var errorDescription: String? {
    switch self {
    case .missingTask(let id): "Task \(id) no longer has saved agent context."
    case .missingAgent(let id): "Agent \(id) no longer exists on the pinned task."
    case .targetChanged(let detail): "The scheduled agent target changed: \(detail)"
    case .ineligible(let detail): "The scheduled agent cannot resume: \(detail)"
    case .providerNotLive(let session): "The pinned provider session \(session) is not live."
    case .providerIdentityChanged(let detail): "The live provider identity changed: \(detail)"
    case .expired(let date): "The scheduled resume passed its latest delivery time at \(date)."
    case .deliveryUnknown(let detail):
      "Prompt delivery is unknown and will not be retried: \(detail)"
    }
  }
}

/// Validates the full saved owner and proves its provider process still owns
/// the pinned session immediately before sending. This path never launches,
/// reopens, or creates a terminal.
public struct ScheduledAgentResumeDispatcher: Sendable {
  private let store: TaskContextStore
  private let verifyRuntime: @Sendable (TmuxSessionReference) async throws -> TmuxSessionReference
  private let locateProvider: @Sendable (AgentProvider, String) async throws -> KnownProviderProcess?
  private let sendPrompt: @Sendable (ScheduledAgentResume) async throws -> Void
  private let now: @Sendable () -> Date

  public init(root: URL) {
    let store = TaskContextStore(root: root)
    let clock: @Sendable () -> Date = { Date() }
    let tmux = TmuxController()
    let locator: @Sendable (AgentProvider, String) async throws -> KnownProviderProcess? = { provider, sessionID in
      try await WezTermController().locateProviderProcess(provider: provider, sessionID: sessionID)
    }
    self.store = store
    self.now = clock
    self.verifyRuntime = { try await tmux.verify($0) }
    self.locateProvider = locator
    self.sendPrompt = { action in
      do {
        let submitted = try await tmux.submitPrompt(
          "\n\n" + action.prompt, to: action.target.runtime,
          ready: AgentPauseController.inputIsReady(for: action.target.provider), timeout: .seconds(15),
          authorizeSubmission: {
            try await Self.authorizeFinalSubmission(
              action, store: store, verifyRuntime: { try await tmux.verify($0) },
              locateProvider: locator, now: clock)
          })
        guard submitted else { throw AgentPauseController.PauseError.inputNotReady(action.title) }
      } catch let error as TmuxPromptDeliveryUnknown {
        throw ScheduledAgentResumeDispatchError.deliveryUnknown(error.localizedDescription)
      }
    }
  }

  public init(
    store: TaskContextStore,
    verifyRuntime: @escaping @Sendable (TmuxSessionReference) async throws -> TmuxSessionReference,
    locateProvider: @escaping @Sendable (AgentProvider, String) async throws -> KnownProviderProcess?,
    sendPrompt: @escaping @Sendable (ScheduledAgentResume) async throws -> Void,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.verifyRuntime = verifyRuntime
    self.locateProvider = locateProvider
    self.sendPrompt = sendPrompt
    self.now = now
  }

  public func dispatch(_ action: ScheduledAgentResume) async throws {
    guard action.state == .claimed else {
      throw ScheduledAgentResumeDispatchError.ineligible("action was not durably claimed")
    }
    try ensureWithinLatestDelivery(action)
    try await Self.validateSavedTarget(action, store: store)
    let verified = try await verifyRuntime(action.target.runtime)
    guard verified == action.target.runtime else {
      throw ScheduledAgentResumeDispatchError.targetChanged("tmux runtime identity")
    }
    guard let process = try await locateProvider(action.target.provider, action.target.sessionID) else {
      throw ScheduledAgentResumeDispatchError.providerNotLive(action.target.sessionID)
    }
    try Self.validateProvider(process, for: action)
    // Re-read after the external probes so a concurrent pause, retirement, or
    // reassignment wins before any prompt reaches the pane.
    try await Self.validateSavedTarget(action, store: store)
    try ensureWithinLatestDelivery(action)
    try await sendPrompt(action)
  }

  private func ensureWithinLatestDelivery(_ action: ScheduledAgentResume) throws {
    guard now() <= action.expiresAt else {
      throw ScheduledAgentResumeDispatchError.expired(action.expiresAt)
    }
  }

  /// The async checks immediately before paste and Enter. The saved target is
  /// read again after provider discovery because that probe can yield while a
  /// user pauses, retires, or reassigns the agent.
  static func authorizeFinalSubmission(
    _ action: ScheduledAgentResume,
    store: TaskContextStore,
    verifyRuntime: @Sendable (TmuxSessionReference) async throws -> TmuxSessionReference,
    locateProvider: @Sendable (AgentProvider, String) async throws -> KnownProviderProcess?,
    now: @Sendable () -> Date
  ) async throws {
    guard now() <= action.expiresAt else {
      throw ScheduledAgentResumeDispatchError.expired(action.expiresAt)
    }
    try await validateSavedTarget(action, store: store)
    let verified = try await verifyRuntime(action.target.runtime)
    guard verified == action.target.runtime else {
      throw ScheduledAgentResumeDispatchError.targetChanged("tmux runtime identity")
    }
    guard let process = try await locateProvider(action.target.provider, action.target.sessionID) else {
      throw ScheduledAgentResumeDispatchError.providerNotLive(action.target.sessionID)
    }
    try validateProvider(process, for: action)
    try await validateSavedTarget(action, store: store)
    guard now() <= action.expiresAt else {
      throw ScheduledAgentResumeDispatchError.expired(action.expiresAt)
    }
  }

  private static func validateSavedTarget(_ action: ScheduledAgentResume, store: TaskContextStore) async throws {
    guard let context = try await store.load(ticketID: action.target.taskID) else {
      throw ScheduledAgentResumeDispatchError.missingTask(action.target.taskID)
    }
    guard let agent = context.subtasks.first(where: { $0.id == action.target.agentID }) else {
      throw ScheduledAgentResumeDispatchError.missingAgent(action.target.agentID)
    }
    guard agent.provider == action.target.provider else {
      throw ScheduledAgentResumeDispatchError.targetChanged("provider")
    }
    guard let session = agent.sessionID,
          session.caseInsensitiveCompare(action.target.sessionID) == .orderedSame else {
      throw ScheduledAgentResumeDispatchError.targetChanged("session")
    }
    guard agent.tmux == action.target.runtime else {
      throw ScheduledAgentResumeDispatchError.targetChanged("tmux pane")
    }
    guard let workspace = agent.workspace?.path,
          Self.path(workspace) == Self.path(action.target.workspacePath) else {
      throw ScheduledAgentResumeDispatchError.targetChanged("workspace")
    }
    guard agent.status != .completed else {
      throw ScheduledAgentResumeDispatchError.ineligible("agent completed")
    }
    guard agent.pausedAt == nil else {
      throw ScheduledAgentResumeDispatchError.ineligible("agent is paused")
    }
    guard agent.agentRemovedAt == nil, agent.mergedIntoSubtaskID == nil,
          !agent.isAssignmentOnly, agent.isAgentVisible else {
      throw ScheduledAgentResumeDispatchError.ineligible("agent was retired, merged, or hidden")
    }
  }

  private static func validateProvider(_ process: KnownProviderProcess,
                                       for action: ScheduledAgentResume) throws {
    guard process.provider == action.target.provider,
          process.sessionID.caseInsensitiveCompare(action.target.sessionID) == .orderedSame,
          process.tty == action.target.runtime.tty else {
      throw ScheduledAgentResumeDispatchError.providerIdentityChanged("provider, session, or terminal")
    }
    guard path(process.cwd) == path(action.target.workspacePath) else {
      throw ScheduledAgentResumeDispatchError.providerIdentityChanged("workspace")
    }
  }

  private static func path(_ value: String) -> String {
    URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path
  }
}
