import Darwin
import Foundation

/// Append-only JSON Lines logs that explain how agents were registered and
/// why an agent could not be opened. Each call appends one line; a failure to
/// log never fails the operation being logged.
public enum AgentEventLog {
  public static func registrationURL(supportDirectory: URL) -> URL {
    supportDirectory.appendingPathComponent("logs/agent-registration.jsonl")
  }

  public static func openURL(supportDirectory: URL) -> URL {
    supportDirectory.appendingPathComponent("logs/agent-open.jsonl")
  }

  /// One process seen while resolving an agent's identity.
  public struct Process: Codable, Equatable, Sendable {
    public var pid: Int32
    public var cwd: String?
    public var tty: String?
    public var sessionID: String?

    public init(pid: Int32, cwd: String?, tty: String?, sessionID: String? = nil) {
      self.pid = pid
      self.cwd = cwd
      self.tty = tty
      self.sessionID = sessionID
    }
  }

  /// A registration event: attach, hook registration, duplicate created or
  /// merged, runtime repair, or workspace assignment.
  public struct Registration: Codable, Equatable, Sendable {
    public var time: Date
    public var event: String
    public var outcome: String
    public var reason: String?
    public var task: String?
    public var subtask: String?
    public var provider: String?
    public var session: String?
    public var pane: String?
    public var cwd: String?
    public var details: [String: String]?

    public init(event: String, outcome: String, reason: String? = nil, task: String? = nil,
                subtask: String? = nil, provider: String? = nil, session: String? = nil,
                pane: String? = nil, cwd: String? = nil, details: [String: String]? = nil,
                time: Date = Date()) {
      self.time = time
      self.event = event
      self.outcome = outcome
      self.reason = reason
      self.task = task
      self.subtask = subtask
      self.provider = provider
      self.session = session
      self.pane = pane
      self.cwd = cwd
      self.details = details
    }
  }

  /// A failed agent open, with the processes the identity lookup saw.
  public struct OpenFailure: Codable, Equatable, Sendable {
    public var time: Date
    public var source: String
    public var task: String?
    public var subtask: String?
    public var provider: String?
    public var session: String?
    public var step: String
    public var reason: String
    public var candidates: [Process]
    public var unresolved: [Process]

    public init(source: String, task: String?, subtask: String?, provider: String?, session: String?,
                step: String, reason: String, candidates: [Process] = [], unresolved: [Process] = [],
                time: Date = Date()) {
      self.time = time
      self.source = source
      self.task = task
      self.subtask = subtask
      self.provider = provider
      self.session = session
      self.step = step
      self.reason = reason
      self.candidates = candidates
      self.unresolved = unresolved
    }
  }

  public static func record(_ entry: Registration, supportDirectory: URL) {
    append(entry, to: registrationURL(supportDirectory: supportDirectory))
  }

  /// Records the failure and returns the log path for the user-facing message.
  @discardableResult
  public static func record(_ entry: OpenFailure, supportDirectory: URL) -> String {
    let url = openURL(supportDirectory: supportDirectory)
    append(entry, to: url)
    return url.path
  }

  /// The open-failure entry for `error`, with the identity lookup's
  /// processes when the error carries them.
  public static func openFailure(
    source: String, task: String?, subtask: String?, provider: AgentProvider?, session: String?,
    step: String, error: Error
  ) -> OpenFailure {
    var entry = OpenFailure(source: source, task: task, subtask: subtask, provider: provider?.rawValue,
      session: session, step: step, reason: error.localizedDescription)
    if let identity = error as? ProviderIdentityError {
      entry.step = "identity"
      entry.candidates = identity.candidates.map {
        Process(pid: $0.processID, cwd: $0.cwd, tty: $0.tty, sessionID: $0.sessionID) }
      entry.unresolved = identity.blockers.map { Process(pid: $0.processID, cwd: $0.cwd, tty: $0.tty) }
    }
    return entry
  }

  /// Appends `reason` with the log location, for alerts that must say where
  /// the details are.
  public static func message(_ reason: String, logPath: String) -> String {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let sentence = trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    return "\(sentence) Details: \(logPath)"
  }

  private static func append<T: Encodable>(_ entry: T, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard var data = try? encoder.encode(entry) else { return }
    data.append(0x0A)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // O_APPEND makes each single write land whole at the end, even with
    // several processes logging at once.
    let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
  }
}
