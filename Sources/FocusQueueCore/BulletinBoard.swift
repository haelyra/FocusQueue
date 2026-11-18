import Foundation

/// What a bulletin board pin points at. Tasks and agents are referenced by
/// ID so the board always shows their live title; files and folders by path.
public enum BulletinPinKind: String, Codable, Sendable, CaseIterable {
  case task, agent, file, folder
}

/// One item pinned to the bulletin board, at a spot the person chose.
public struct BulletinPin: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var kind: BulletinPinKind
  /// The project the item belongs to; the board shows a project's pins only
  /// while that project is selected, and every pin in the All view.
  public var projectID: String?
  public var taskID: String?
  public var subtaskID: String?
  public var path: String?
  /// The title when pinned, shown if the item later disappears.
  public var title: String
  /// Top-left corner of the card on the board, in points.
  public var x: Double
  public var y: Double
  public var pinnedAt: Date

  public init(
    id: String = UUID().uuidString, kind: BulletinPinKind, projectID: String?,
    taskID: String? = nil, subtaskID: String? = nil, path: String? = nil,
    title: String, x: Double = 0, y: Double = 0, pinnedAt: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.projectID = projectID
    self.taskID = taskID
    self.subtaskID = subtaskID
    self.path = path
    self.title = title
    self.x = x
    self.y = y
    self.pinnedAt = pinnedAt
  }

  /// Two pins name the same item when kind and target match; position and
  /// title do not count, so pinning an item twice keeps one card.
  public func targets(sameItemAs other: BulletinPin) -> Bool {
    kind == other.kind && taskID == other.taskID && subtaskID == other.subtaskID
      && path.map(BulletinPin.normalizedPath) == other.path.map(BulletinPin.normalizedPath)
  }

  public static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}

public struct BulletinBoardDocument: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var pins: [BulletinPin]

  public init(schemaVersion: Int = 1, pins: [BulletinPin] = []) {
    self.schemaVersion = schemaVersion
    self.pins = pins
  }
}

/// Drag payloads the board accepts as plain strings, besides file URLs.
public enum BulletinDragToken {
  public static let agentPrefix = "focusqueue-agent:"

  /// `focusqueue-agent:<TASK-ID>/<AGENT-ID>`: the drag value of an agent row.
  public static func agent(taskID: String, subtaskID: String) -> String {
    "\(agentPrefix)\(taskID)/\(subtaskID)"
  }

  public static func parseAgent(_ value: String) -> (taskID: String, subtaskID: String)? {
    guard value.hasPrefix(agentPrefix) else { return nil }
    let parts = value.dropFirst(agentPrefix.count).split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return (parts[0], parts[1])
  }

  /// A dropped string that names a file: a `file://` URL or an absolute path.
  public static func fileURL(_ value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), url.isFileURL { return url.standardizedFileURL }
    if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed).standardizedFileURL }
    return nil
  }
}

/// The facts the cleaned-up rule needs, so it can be tested without a model.
public struct BulletinPinLookup: Sendable {
  public var tickets: [String: DashboardTicket]
  public var contexts: [String: TaskContext]
  public var fileExists: @Sendable (String) -> Bool

  public init(
    tickets: [String: DashboardTicket], contexts: [String: TaskContext],
    fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) {
    self.tickets = tickets
    self.contexts = contexts
    self.fileExists = fileExists
  }
}

public enum BulletinBoardRules {
  /// A pin is cleaned up once its item is gone or archived: a task that is
  /// resolved, cancelled, or deleted; an agent that is archived, merged,
  /// deleted, or whose task is cleaned up; a file or folder no longer on disk.
  /// An agent whose task context has not loaded yet stays visible.
  public static func isCleanedUp(_ pin: BulletinPin, lookup: BulletinPinLookup) -> Bool {
    switch pin.kind {
    case .task:
      guard let taskID = pin.taskID, let ticket = lookup.tickets[taskID] else { return true }
      return !ticket.isOpen
    case .agent:
      guard let taskID = pin.taskID, let subtaskID = pin.subtaskID,
            let ticket = lookup.tickets[taskID] else { return true }
      if !ticket.isOpen { return true }
      guard let context = lookup.contexts[taskID] else { return false }
      guard let agent = context.subtasks.first(where: { $0.id == subtaskID }) else { return true }
      return agent.agentRemovedAt != nil || agent.mergedIntoSubtaskID != nil
    case .file, .folder:
      guard let path = pin.path else { return true }
      return !lookup.fileExists(path)
    }
  }

  /// The pins the board shows for a project scope; nil means All.
  public static func visiblePins(
    _ pins: [BulletinPin], projectID: String?, showsCleanedUp: Bool, lookup: BulletinPinLookup
  ) -> [BulletinPin] {
    pins.filter { pin in
      (projectID == nil || pin.projectID == nil || pin.projectID == projectID)
        && (showsCleanedUp || !isCleanedUp(pin, lookup: lookup))
    }
  }

  /// Adds a pin, or moves the existing pin for the same item to the new spot.
  public static func adding(_ pin: BulletinPin, to pins: [BulletinPin]) -> [BulletinPin] {
    var result = pins
    if let index = result.firstIndex(where: { $0.targets(sameItemAs: pin) }) {
      result[index].x = pin.x
      result[index].y = pin.y
      result[index].title = pin.title
      // Bring it to the front so the moved card draws on top.
      result.append(result.remove(at: index))
    } else {
      result.append(pin)
    }
    return result
  }

  /// The next free spot for a pin added without a drop location: a grid of
  /// cards filling rows left to right.
  public static func nextSlot(
    for pins: [BulletinPin], boardWidth: Double, cardWidth: Double, cardHeight: Double, spacing: Double
  ) -> (x: Double, y: Double) {
    let columns = max(1, Int((boardWidth - spacing) / (cardWidth + spacing)))
    let occupied = pins.map { (x: $0.x, y: $0.y) }
    for index in 0..<500 {
      let x = spacing + Double(index % columns) * (cardWidth + spacing)
      let y = spacing + 12 + Double(index / columns) * (cardHeight + spacing)
      let overlaps = occupied.contains { abs($0.x - x) < cardWidth * 0.6 && abs($0.y - y) < cardHeight * 0.6 }
      if !overlaps { return (x, y) }
    }
    return (spacing, spacing + 12)
  }
}

/// Saves the board beside the queue state. Every write replaces the file
/// atomically; a missing or unreadable file reads as an empty board.
public struct BulletinBoardStore: Sendable {
  public let url: URL

  public init(root: URL) {
    url = root.appendingPathComponent("bulletin-board.json")
  }

  public func load() throws -> BulletinBoardDocument {
    guard FileManager.default.fileExists(atPath: url.path) else { return BulletinBoardDocument() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(BulletinBoardDocument.self, from: Data(contentsOf: url))
  }

  public func save(_ document: BulletinBoardDocument) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try SystemFileAccessor().write(encoder.encode(document), to: url)
  }
}
