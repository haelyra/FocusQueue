import Foundation

/// Flat agent-list ordering for the queue's Agent view. Mirrors the inputs of
/// the agent status indicator: effective status, attention, unread completion,
/// and any session error. Lower ranks sort first.
public enum AgentViewOrdering {
    public static func rank(
        status: TaskSubtaskStatus,
        attention: AgentAttention?,
        completionUnread: Bool,
        sessionError: String?
    ) -> Int {
        if attention == .question || attention == .approval { return 0 }
        if completionUnread { return 1 }
        if status == .working { return 2 }
        if sessionError != nil || attention?.isProblem == true { return 3 }
        if status == .completed || status == .idle { return 4 }
        return 5
    }

    /// Rank ascending; most recent activity first within a rank.
    public static func ordered<T>(
        _ items: [T],
        rank: (T) -> Int,
        activity: (T) -> Date?
    ) -> [T] {
        items.sorted {
            let lhsRank = rank($0), rhsRank = rank($1)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (activity($0) ?? .distantPast) > (activity($1) ?? .distantPast)
        }
    }
}
