import FocusQueueCore
import Foundation

/// One QChat conversation tab. Each tab owns its transcript and its own tmux
/// session on the QChat server, so tabs run independently and in parallel.
struct QueueChatTab: Identifiable, Codable, Equatable, Sendable {
  static let mainID = "main"
  static let main = QueueChatTab(id: mainID, title: "Chat 1", titleIsAutomatic: true)
  static let titleLimit = 28

  let id: String
  var title: String
  /// True until the first message names the tab; a renamed tab keeps its name.
  var titleIsAutomatic: Bool

  /// A short tab name from the first request: its first words, clipped.
  static func title(from message: String) -> String? {
    let words = message.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(6)
    guard !words.isEmpty else { return nil }
    var title = ""
    for word in words {
      let next = title.isEmpty ? String(word) : title + " " + word
      if next.count > titleLimit { break }
      title = next
    }
    if title.isEmpty { title = String(words[0].prefix(titleLimit - 1)) + "…" }
    return title
  }

  /// "Chat N" for the Nth tab, skipping a number another tab already shows.
  static func nextDefaultTitle(existing: [QueueChatTab]) -> String {
    let used = Set(existing.map(\.title))
    var number = existing.count + 1
    while used.contains("Chat \(number)") { number += 1 }
    return "Chat \(number)"
  }
}

/// A chat transcript: a central QChat tab or a task's orchestrator chat.
enum QueueChatConversation: Hashable, Sendable {
  case tab(String)
  case task(String)

  var key: String {
    switch self {
    case .tab(let id): "tab:\(id)"
    case .task(let id): "task:\(id.uppercased())"
    }
  }

  init?(key: String) {
    let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[1].isEmpty else { return nil }
    switch parts[0] {
    case "tab": self = .tab(parts[1])
    case "task": self = .task(parts[1])
    default: return nil
    }
  }

  var ticketID: String? {
    if case .task(let id) = self { return id }
    return nil
  }

  var tmuxSessionName: String { QueueChatSessions.sessionName(conversation: key) }
}
