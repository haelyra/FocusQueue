import Foundation

extension TaskSubtask {
    /// Inactivity window after which an unowned agent becomes a cleanup candidate.
    public static let staleAgentInactivityThreshold: TimeInterval = 5 * 24 * 60 * 60

    /// Most recent recorded activity: the later of the last heartbeat or result.
    /// Records without either fall back to their earliest known timestamp so they
    /// can still age out; agents with no timestamps at all are never stale.
    public var staleAgentLastActivity: Date? {
        if let latest = [lastHeartbeatAt, resultAt].compactMap({ $0 }).max() { return latest }
        return [observedEventAt, completionOverrideAt].compactMap { $0 }.min()
    }

    /// Record-only staleness test for manual and automatic cleanup. Process
    /// ownership is verified separately by the caller (TaskMaintenance); a live
    /// owner always retains its agent. Archiving is recallable, never destructive.
    ///
    /// A candidate must be visible, unretained, and quiet: no unread result, not
    /// queued or working, and either interrupted or idle with its output seen.
    public func isStaleAgentCandidate(
        now: Date = Date(),
        inactivityThreshold: TimeInterval = TaskSubtask.staleAgentInactivityThreshold
    ) -> Bool {
        guard hasAgent, agentRemovedAt == nil else { return false }
        guard completedRuntimeOpenedAt == nil else { return false }
        guard !completionUnread else { return false }
        let currentStatus = effectiveStatus(now: now)
        guard currentStatus != .queued, currentStatus != .working else { return false }
        guard attention == .interrupted || currentStatus == .idle else { return false }
        guard let lastActivity = staleAgentLastActivity else { return false }
        return now.timeIntervalSince(lastActivity) > inactivityThreshold
    }
}
