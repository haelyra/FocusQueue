import Foundation

/// Ordering for the queue's Agent view: tasks as cards holding their agents,
/// with the task and agent the person most recently heard from or prompted first.
public enum AgentViewOrdering {
    /// When an agent last produced output, stopped to ask for the user, or was
    /// prompted by the user. Attention reports stamp only the heartbeat, so an
    /// open attention request counts its heartbeat as activity. Progress alone
    /// never counts, so a working agent does not climb past fresh results.
    public static func activityDate(
        lastOutputAt: Date?,
        resultAt: Date?,
        lastPromptAt: Date? = nil,
        attention: AgentAttention?,
        lastHeartbeatAt: Date?
    ) -> Date? {
        let waiting = attention != nil ? lastHeartbeatAt : nil
        return [lastOutputAt ?? resultAt, lastPromptAt, waiting].compactMap { $0 }.max()
    }

    /// Sorts each group's items newest first, then the groups by their newest
    /// item or their own activity, such as a task prompt not tied to one agent.
    /// Groups without items are dropped; ties keep the input order.
    public static func grouped<Group, Item>(
        _ groups: [(group: Group, items: [Item])],
        groupActivity: (Group) -> Date? = { _ in nil },
        activity: (Item) -> Date?
    ) -> [(group: Group, items: [Item])] {
        let sortedGroups = groups.compactMap { entry -> (group: Group, items: [Item], latest: Date)? in
            guard !entry.items.isEmpty else { return nil }
            let items = newestFirst(entry.items, activity: activity)
            let latest = (items.compactMap(activity) + [groupActivity(entry.group)].compactMap { $0 }).max()
            return (entry.group, items, latest ?? .distantPast)
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
