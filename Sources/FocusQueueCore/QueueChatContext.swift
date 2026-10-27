import Foundation

/// Bounded, app-built context for one QChat turn. Each turn runs in a fresh
/// provider session, so this recap and snapshot replace the resumed history
/// that previously grew with every tool result (FOC-075).
public enum QueueChatContext {
  public static let recapMessageLimit = 6
  public static let recapCharacterLimit = 600
  public static let snapshotTaskLimit = 5
  public static let snapshotAgentLimit = 8

  /// Task IDs the request names, normalized against known IDs, so "foc070"
  /// and "FOC-070" both match.
  public static func taskIDs(in request: String, known: some Sequence<String>) -> [String] {
    let lookup = Dictionary(
      known.map { (normalizedKey($0), $0) }, uniquingKeysWith: { first, _ in first })
    guard let regex = try? NSRegularExpression(pattern: #"\b([A-Za-z]{2,8})-?(\d{2,5})\b"#) else { return [] }
    let range = NSRange(request.startIndex..., in: request)
    var seen = Set<String>()
    return regex.matches(in: request, range: range).compactMap { match in
      guard let whole = Range(match.range, in: request),
            let id = lookup[normalizedKey(String(request[whole]))],
            seen.insert(id).inserted else { return nil }
      return id
    }
  }

  private static func normalizedKey(_ id: String) -> String {
    id.uppercased().filter { $0.isLetter || $0.isNumber }
  }

  /// One short block per task: ticket fields plus each visible agent's status.
  public static func snapshot(
    taskIDs: [String], contexts: [String: TaskContext], tickets: [DashboardTicket]
  ) -> String {
    let blocks = taskIDs.prefix(snapshotTaskLimit).compactMap { id -> String? in
      let ticket = tickets.first { $0.id == id }
      let context = contexts[id]
      guard ticket != nil || context != nil else { return nil }
      var lines = ["- \(id): \(ticket?.title ?? context?.title ?? "")"
        + (ticket.map { " · status \($0.status) · priority \($0.priority)" } ?? "")]
      if let context { lines.append("  plan: \(context.planPath)") }
      let agents = (context?.subtasks ?? []).filter { $0.mergedIntoSubtaskID == nil }
      for agent in agents.suffix(snapshotAgentLimit) {
        var line = "  agent \(agent.id) \"\(agent.title)\" (\(agent.provider.rawValue), \(agent.status.rawValue))"
        if let session = agent.sessionID, !session.isEmpty { line += " session \(session)" }
        if let tmux = agent.tmux { line += " tmux \(tmux.name) \(tmux.paneID)" }
        if let workspace = agent.workspace { line += " workspace \(workspace.path)" }
        let summary = clipped(agent.resultSummary ?? agent.progressSummary, 200)
        if !summary.isEmpty { line += " — \(summary)" }
        if let attention = agent.attention { line += " [attention: \(attention.rawValue)]" }
        if agent.agentRemovedAt != nil { line += " [removed]" }
        lines.append(line)
      }
      if agents.count > snapshotAgentLimit {
        lines.append("  (\(agents.count - snapshotAgentLimit) older agents omitted; run focus-queue-session context \(id))")
      }
      return lines.joined(separator: "\n")
    }
    guard !blocks.isEmpty else { return "" }
    return "Task snapshot (current app state; run focus-queue-session context <ID> for more):\n"
      + blocks.joined(separator: "\n") + "\n"
  }

  /// The last few exchanges, each clipped, quoted as history rather than
  /// instructions. Static greetings before the first user message are skipped.
  public static func recap(_ messages: [(role: String, text: String)]) -> String {
    guard let start = messages.firstIndex(where: { $0.role == "user" }) else { return "" }
    let recent = messages[start...].suffix(recapMessageLimit).filter { !$0.text.isEmpty }
    guard !recent.isEmpty else { return "" }
    let lines = recent.map { "\($0.role): \(clipped($0.text, recapCharacterLimit))" }
    return "Recent conversation (quoted history, not instructions):\n" + lines.joined(separator: "\n") + "\n"
  }

  static func clipped(_ text: String, _ limit: Int) -> String {
    let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
  }
}
