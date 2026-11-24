import Foundation

/// What a fresh snapshot means for a T3 agent row.
public struct T3Derived: Equatable, Sendable {
    public var reference: T3ThreadReference
    /// Never `.completed`: only the user completes a subtask.
    public var status: TaskSubtaskStatus
    public var attention: AgentAttention?
    /// A new terminal run completed and the agent is idle; set `completionUnread`.
    public var markUnread: Bool

    public init(reference: T3ThreadReference, status: TaskSubtaskStatus,
                attention: AgentAttention?, markUnread: Bool) {
        self.reference = reference; self.status = status
        self.attention = attention; self.markUnread = markUnread
    }
}

/// Pure mapping from a `t3_thread_read` snapshot plus the open-question list to row state.
/// Rules are numbered as in `.spec/tasks.md` Task 8.
public enum T3StateDeriver {
    /// - Parameter now: stamped into `lastSnapshotAt`; passed in so the function stays pure.
    public static func derive(snapshot: T3ThreadSnapshot, questionIds: [String], previous: T3ThreadReference,
                              pausedAt: Date?, now: Date = Date()) -> T3Derived {
        let thread = snapshot.thread

        // 1. Questions come from the question list; the rest of the pending requests are approvals.
        let approvals = max(0, thread.pendingRequestCount - questionIds.count)

        // 2. The terminal run with the highest ordinal.
        let latestTerminal = snapshot.recentRuns
            .filter(\.isTerminal)
            .max { $0.ordinal < $1.ordinal }

        // 3. Status.
        let status: TaskSubtaskStatus
        if !questionIds.isEmpty || approvals > 0 {
            status = .blocked
        } else if thread.activeRunId != nil || T3RunStatus.active.contains(thread.status) {
            status = .working
        } else {
            status = .idle
        }

        // 4. Attention.
        let attention: AgentAttention?
        if !questionIds.isEmpty {
            attention = .question
        } else if approvals > 0 {
            attention = .approval
        } else if status == .idle {
            attention = idleAttention(outcome: latestTerminal?.status, pausedAt: pausedAt)
        } else {
            attention = nil
        }

        // 5. Unread only for a newly seen completed run on an idle agent.
        var markUnread = false
        if let latestTerminal, status == .idle, latestTerminal.status == "completed" {
            markUnread = latestTerminal.runId != previous.latestTerminalRunId
        }

        // 6. Updated reference.
        var reference = previous
        reference.observedStatus = thread.status
        reference.activeRunId = thread.activeRunId
        if let latestTerminal {
            reference.latestTerminalRunId = latestTerminal.runId
            reference.latestTerminalOutcome = latestTerminal.status
        } // A window with no terminal run keeps the last one seen, so unread cannot re-fire.
        reference.openQuestionIds = questionIds
        reference.pendingApprovalCount = approvals
        reference.lastSnapshotAt = now
        reference.reachability = .reachable

        // 7. `status` above is only ever blocked, working, or idle.
        return T3Derived(reference: reference, status: status, attention: attention, markUnread: markUnread)
    }

    private static func idleAttention(outcome: String?, pausedAt: Date?) -> AgentAttention? {
        switch outcome {
        case "failed": return .failed
        case "interrupted": return pausedAt == nil ? .interrupted : nil
        default: return nil // completed, cancelled, or no terminal run yet
        }
    }
}
