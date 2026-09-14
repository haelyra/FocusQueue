import Foundation
import FocusQueueCore

struct PlanEditDraft: Codable, Equatable, Sendable {
  var markdown: String
  let baseline: String
}

/// Bounded local transcripts allow app restarts without losing the user's decisions.
actor QueueConversationStore {
  private let root: URL
  private let durableLibrary: DurableLibraryStore
  private var saveRevisions: [String: Int] = [:]
  init(root: URL) {
    self.root = root
    self.durableLibrary = DurableLibraryStore(root: root)
  }

  func loadPlanDraft(ticketID: String) throws -> PlanEditDraft? {
    let url = try location(ticketID).deletingLastPathComponent().appendingPathComponent("plan-draft.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(PlanEditDraft.self, from: Data(contentsOf: url))
  }

  func savePlanDraft(_ draft: PlanEditDraft?, ticketID: String) throws {
    let url = try location(ticketID).deletingLastPathComponent().appendingPathComponent("plan-draft.json")
    if let draft {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(draft).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } else if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  func load(ticketID: String?) throws -> [QueueChatMessage]? {
    let url = try location(ticketID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode([QueueChatMessage].self, from: Data(contentsOf: url))
  }

  func save(_ messages: [QueueChatMessage], ticketID: String?) async throws {
    let url = try location(ticketID)
    let key = ticketID ?? "queue"
    let revision = (saveRevisions[key] ?? 0) + 1
    saveRevisions[key] = revision
    let completeData = try JSONEncoder().encode(messages)
    do {
      try await durableLibrary.captureConversation(data: completeData, ticketID: ticketID)
    } catch {
      // Keep every supplied message in the canonical file if archiving fails.
      // The visible error must never be accompanied by silent suffix truncation.
      if saveRevisions[key] == revision { try write(completeData, to: url) }
      throw ConversationArchiveError(detail: error.localizedDescription)
    }
    guard saveRevisions[key] == revision else { return }
    try write(JSONEncoder().encode(Array(messages.suffix(500))), to: url)
  }

  private func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func location(_ ticketID: String?) throws -> URL {
    guard let ticketID else { return root.appendingPathComponent("queue-conversation.json") }
    guard ticketID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    return root.appendingPathComponent("tasks").appendingPathComponent(ticketID.uppercased())
      .appendingPathComponent("conversation.json")
  }
}

struct ConversationArchiveError: LocalizedError {
  let detail: String
  var errorDescription: String? {
    "Conversation saved locally, but durable history needs attention: \(detail)"
  }
}
