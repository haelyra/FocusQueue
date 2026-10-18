import Foundation

public enum QueueTaskKind: String, CaseIterable, Identifiable, Sendable {
  case task, longRunning, subtask, customerConcern
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .task: "Task"
    case .longRunning: "Long running"
    case .subtask: "Subtask"
    case .customerConcern: "Human review"
    }
  }
  public var icon: String {
    switch self {
    case .task: "checklist"
    case .longRunning: "arrow.triangle.2.circlepath"
    case .subtask: "arrow.turn.down.right"
    case .customerConcern: "person.crop.circle.badge.exclamationmark"
    }
  }
}

public extension DashboardTicket {
  var queueTaskKind: QueueTaskKind {
    let kind = (taskType ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
    switch kind {
    case "subtask", "sub-task": return .subtask
    case "customer", "customer-concern", "human-review", "support": return .customerConcern
    case "recurring", "long-running", "pull-request-resolution": return .longRunning
    default:
      if isRecurringPullRequestTask { return .longRunning }
      if ["customer", "customer-concern", "support"].contains(category?.lowercased() ?? "") {
        return .customerConcern
      }
      return .task
    }
  }

  /// An extract of source text, never an inferred or model-generated task description.
  var briefSummary: String {
    let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return title }
    var sentences: [String] = []
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) {
      sentence, _, _, stop in
      if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines)) }
      if sentences.count == 3 { stop = true }
    }
    let excerpt = sentences.isEmpty ? text : sentences.joined(separator: " ")
    guard excerpt.count > 600 else { return excerpt }
    let prefix = String(excerpt.prefix(600))
    let boundary = prefix.lastIndex(where: \.isWhitespace) ?? prefix.endIndex
    return String(prefix[..<boundary]) + "…"
  }

  var planLinks: [DashboardLink] {
    links.filter { $0.type?.lowercased() == "plan" || $0.label.localizedCaseInsensitiveContains("plan canvas") }
  }
}

public enum TaskTriagePolicy {
  public static func date(from value: String?) -> Date? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    if let date = ISO8601DateFormatter().date(from: value) { return date }
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = TimeZone(secondsFromGMT: 0)
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: value)
  }

  public static func dateOnlyString(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  public static func hasHardDeadline(_ ticket: DashboardTicket) -> Bool {
    !(ticket.dueDate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  public static func hardDeadline(for ticket: DashboardTicket) -> Date? {
    date(from: ticket.dueDate)
  }

  public static func latestActivity(
    for ticket: DashboardTicket,
    lastPromptAt: Date? = nil,
    lastOutputAt: Date? = nil
  ) -> Date? {
    [date(from: ticket.updatedAt), date(from: ticket.createdAt), lastPromptAt, lastOutputAt]
      .compactMap { $0 }.max()
  }

  public static func relativeDeadline(
    for ticket: DashboardTicket,
    lastPromptAt: Date? = nil,
    lastOutputAt: Date? = nil,
    calendar: Calendar = .current
  ) -> Date? {
    guard ticket.isOpen, !hasHardDeadline(ticket), ticket.queueTaskKind != .longRunning,
      let anchor = latestActivity(for: ticket, lastPromptAt: lastPromptAt, lastOutputAt: lastOutputAt)
    else { return nil }
    let days = switch ticket.priority.lowercased() {
    case "critical": 1
    case "high": 2
    case "low": 7
    default: 4
    }
    return calendar.date(byAdding: .day, value: days, to: anchor)
  }

  public static func effectiveDeadline(
    for ticket: DashboardTicket,
    lastPromptAt: Date? = nil,
    lastOutputAt: Date? = nil
  ) -> Date? {
    hardDeadline(for: ticket) ?? relativeDeadline(for: ticket, lastPromptAt: lastPromptAt, lastOutputAt: lastOutputAt)
  }

  public static func deadlineOrdered(
    _ tickets: [DashboardTicket],
    lastPromptAtByTicketID: [String: Date] = [:],
    lastOutputAtByTicketID: [String: Date] = [:]
  ) -> [DashboardTicket] {
    tickets.enumerated().sorted { left, right in
      let leftTicket = left.element
      let rightTicket = right.element
      let leftDeadline = effectiveDeadline(
        for: leftTicket,
        lastPromptAt: lastPromptAtByTicketID[leftTicket.id],
        lastOutputAt: lastOutputAtByTicketID[leftTicket.id])
      let rightDeadline = effectiveDeadline(
        for: rightTicket,
        lastPromptAt: lastPromptAtByTicketID[rightTicket.id],
        lastOutputAt: lastOutputAtByTicketID[rightTicket.id])
      if leftDeadline != rightDeadline {
        return (leftDeadline ?? .distantFuture) < (rightDeadline ?? .distantFuture)
      }
      if leftTicket.priorityRank != rightTicket.priorityRank {
        return leftTicket.priorityRank < rightTicket.priorityRank
      }
      let leftActivity = latestActivity(
        for: leftTicket,
        lastPromptAt: lastPromptAtByTicketID[leftTicket.id],
        lastOutputAt: lastOutputAtByTicketID[leftTicket.id])
      let rightActivity = latestActivity(
        for: rightTicket,
        lastPromptAt: lastPromptAtByTicketID[rightTicket.id],
        lastOutputAt: lastOutputAtByTicketID[rightTicket.id])
      if leftActivity != rightActivity {
        return (leftActivity ?? .distantPast) > (rightActivity ?? .distantPast)
      }
      if leftTicket.id != rightTicket.id { return leftTicket.id < rightTicket.id }
      return left.offset < right.offset
    }.map(\.element)
  }

  public static func hardDeadlineIsOverdue(for ticket: DashboardTicket, now: Date = Date(), calendar: Calendar = .current) -> Bool {
    guard let deadline = hardDeadline(for: ticket) else { return false }
    return calendar.startOfDay(for: deadline) < calendar.startOfDay(for: now)
  }
}

public enum EmbeddedDocumentPolicy {
  /// Only deliberate link activation may leave the static local document.
  public static func allowsLink(_ url: URL) -> Bool {
    ["file", "https", "http", "vscode", "obsidian"].contains(url.scheme?.lowercased() ?? "")
  }
}
