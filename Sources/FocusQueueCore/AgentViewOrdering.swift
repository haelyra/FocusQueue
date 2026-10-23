import Foundation

/// Ordering for the queue's Agent view: tasks as cards holding their agents,
/// with the most recently active task and agent first.
public enum AgentViewOrdering {
    /// When an agent last produced output or stopped to ask for the user.
    /// Attention reports stamp only the heartbeat, so an open attention request
    /// counts its heartbeat as activity.
    public static func activityDate(
        lastOutputAt: Date?,
        resultAt: Date?,
        attention: AgentAttention?,
        lastHeartbeatAt: Date?
    ) -> Date? {
        let output = lastOutputAt ?? resultAt
        guard attention != nil, let lastHeartbeatAt else { return output }
        return max(output ?? .distantPast, lastHeartbeatAt)
    }

    /// Sorts each group's items newest first, then the groups by their newest
    /// item. Groups without items are dropped; ties keep the input order.
    public static func grouped<Group, Item>(
        _ groups: [(group: Group, items: [Item])],
        activity: (Item) -> Date?
    ) -> [(group: Group, items: [Item])] {
        let sortedGroups = groups.compactMap { entry -> (group: Group, items: [Item], latest: Date)? in
            guard !entry.items.isEmpty else { return nil }
            let items = newestFirst(entry.items, activity: activity)
            return (entry.group, items, items.compactMap(activity).max() ?? .distantPast)
        }
        return newestFirst(sortedGroups) { $0.latest }.map { ($0.group, $0.items) }
    }

    private static func newestFirst<T>(_ items: [T], activity: (T) -> Date?) -> [T] {
        items.enumerated().sorted {
            let lhs = activity($0.element) ?? .distantPast
            let rhs = activity($1.element) ?? .distantPast
            return lhs != rhs ? lhs > rhs : $0.offset < $1.offset
        }.map(\.element)
    }
}
