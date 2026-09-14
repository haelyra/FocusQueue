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

public enum EmbeddedDocumentPolicy {
  /// Only deliberate link activation may leave the static local document.
  public static func allowsLink(_ url: URL) -> Bool {
    ["file", "https", "http", "vscode", "obsidian"].contains(url.scheme?.lowercased() ?? "")
  }
}
