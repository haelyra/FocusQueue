import Foundation
import Testing
@testable import FocusQueueCore

/// Guards the queue's render-path cost and the state writes that used to run
/// on every poll. The legacy projections below are the per-call scans the
/// index replaced; the indexed results must stay identical to them.
@Suite("Queue responsiveness")
struct QueueResponsivenessTests {
    @Test("Indexed agent projections match the legacy per-call scans", arguments: 0..<40)
    func indexedProjectionsMatchLegacyScans(seed: Int) {
        let now = Date()
        var generator = SeededGenerator(seed: UInt64(seed) &+ 1)
        let context = Self.randomContext(using: &generator, now: now)
        let probeIDs = context.subtasks.map(\.id) + ["missing-\(seed)"]

        #expect(context.focusSubtasks == LegacyProjection.focusSubtasks(context, now: now))
        #expect(context.taskItems == LegacyProjection.taskItems(context, now: now))
        for id in probeIDs {
            #expect(context.canonicalSubtaskID(id) == LegacyProjection.canonical(context, id))
            #expect(context.agents(for: id) == LegacyProjection.agents(context, id))
            #expect(context.agents(for: id, includingRemoved: true)
                == LegacyProjection.agents(context, id, includingRemoved: true))
        }
        for subtask in context.subtasks {
            #expect(context.assignmentIDs(for: subtask) == LegacyProjection.assignmentIDs(context, subtask))
        }

        var refreshed = context
        refreshed.refreshAssignmentStatuses()
        var legacy = context
        LegacyProjection.refreshAssignmentStatuses(&legacy)
        #expect(refreshed == legacy)
    }

    @Test("Rendering a large task's agents stays far below a frame budget")
    func largeContextProjectionsAreFast() {
        let now = Date()
        var context = Self.emptyContext()
        for root in 0..<200 {
            var assignment = TaskSubtask(id: "root-\(root)", title: "Assignment \(root)",
                status: root.isMultiple(of: 3) ? .working : .queued)
            assignment.isAssignmentOnly = true
            context.subtasks.append(assignment)
        }
        for agent in 0..<400 {
            var runtime = TaskSubtask(id: "agent-\(agent)", title: "Agent \(agent)",
                sessionID: "session-\(agent)", status: agent.isMultiple(of: 2) ? .working : .idle,
                lastHeartbeatAt: now.addingTimeInterval(-Double(agent % 50)))
            runtime.parentSubtaskID = "root-\(agent % 200)"
            runtime.associatedSubtaskIDs = ["root-\((agent + 7) % 200)"]
            context.subtasks.append(runtime)
        }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = context.focusSubtasks
            _ = context.taskItems
        }
        // The quadratic per-comparison scans took minutes at this size.
        #expect(elapsed < .seconds(1))
        #expect(context.taskItems.count == 400)
    }

    @Test("Re-registering an unchanged agent session leaves saved state identical")
    func unchangedRegistrationIsNoOp() {
        let sessions = (0..<4).map { index in
            TaskAgentSession(ticketID: "ECC-90\(index)", provider: .codex,
                sessionID: UUID().uuidString, tabTitle: "Task \(index)",
                workingDirectory: "/tmp/task-\(index)")
        }
        var state = LocalState()
        for session in sessions { state.upsertAgentSession(session) }
        let saved = state

        // Hooks resend every registration. The saved order must not rotate.
        for session in sessions.reversed() { state.upsertAgentSession(session) }
        #expect(state == saved)

        let moved = TaskAgentSession(ticketID: "ECC-999", provider: .codex,
            sessionID: sessions[1].sessionID.lowercased(), tabTitle: "Moved",
            workingDirectory: "/tmp/moved")
        state.upsertAgentSession(moved)
        #expect(state.agentSessions.count == 4)
        #expect(state.agentSessions[1].ticketID == "ECC-999")
        #expect(state.agentSessions[1].id == saved.agentSessions[1].id)
        #expect(state.agentSessions.map(\.id) == saved.agentSessions.map(\.id))
    }

    @Test("Duplicate saved sessions collapse into the first position")
    func duplicateSessionsCollapse() {
        let shared = UUID().uuidString
        let first = TaskAgentSession(ticketID: "ECC-901", provider: .claude,
            sessionID: shared, tabTitle: "First", workingDirectory: "/tmp/a")
        let other = TaskAgentSession(ticketID: "ECC-902", provider: .claude,
            sessionID: UUID().uuidString, tabTitle: "Other", workingDirectory: "/tmp/b")
        let duplicate = TaskAgentSession(ticketID: "ECC-901", provider: .claude,
            sessionID: shared.lowercased(), tabTitle: "Duplicate", workingDirectory: "/tmp/c")
        var state = LocalState(agentSessions: [first, other, duplicate])

        state.upsertAgentSession(duplicate)
        #expect(state.agentSessions.map(\.id) == [first.id, other.id])
        #expect(state.agentSessions[0].workingDirectory == "/tmp/c")
    }

    @Test("Volatile-only context changes compare equal; meaningful changes do not")
    func volatileFieldsAreIgnored() {
        var context = Self.emptyContext()
        context.subtasks = [TaskSubtask(id: "agent", title: "Agent", sessionID: "s1",
            status: .working, lastHeartbeatAt: Date(timeIntervalSince1970: 100))]
        var heartbeat = context
        heartbeat.updatedAt = Date(timeIntervalSince1970: 999)
        heartbeat.subtasks[0].lastHeartbeatAt = Date(timeIntervalSince1970: 500)
        heartbeat.subtasks[0].observedEventID = "event"
        heartbeat.subtasks[0].observedEventAt = Date(timeIntervalSince1970: 500)
        #expect(heartbeat != context)
        #expect(heartbeat.withoutVolatileFields == context.withoutVolatileFields)

        var blocked = heartbeat
        blocked.subtasks[0].status = .blocked
        #expect(blocked.withoutVolatileFields != context.withoutVolatileFields)
    }

    // MARK: - Fixtures

    static func emptyContext() -> TaskContext {
        TaskContext(ticketID: "ECC-950", title: "Task", summary: "", successCriteria: "",
            planPath: "/tmp/tasks/ECC-950/plan.md", updatedAt: Date())
    }

    /// Small ID and session pools force duplicates, merge chains, cycles, and
    /// shared provider sessions. Heartbeats stay well away from the 300 second
    /// working window so wall-clock drift cannot change a priority.
    static func randomContext(using generator: inout SeededGenerator, now: Date) -> TaskContext {
        var context = emptyContext()
        let count = Int.random(in: 4...36, using: &generator)
        let ids = (0..<max(3, count - 2)).map { "s\($0)" }
        let sessions = ["A", "a", "B", "C", "D"]
        let statuses: [TaskSubtaskStatus] = [.queued, .working, .idle, .blocked, .completed]
        let attentions: [AgentAttention?] = [nil, nil, nil, .question, .failed]
        let heartbeats: [Date?] = [nil, now.addingTimeInterval(-30), now.addingTimeInterval(-30),
            now.addingTimeInterval(-90), now.addingTimeInterval(-3_600), now.addingTimeInterval(-7_200)]
        for index in 0..<count {
            let id = index < ids.count && Bool.random(using: &generator)
                ? ids[index] : ids.randomElement(using: &generator)!
            var subtask = TaskSubtask(id: id, title: "Subtask \(index)",
                provider: Bool.random(using: &generator) ? .codex : .claude,
                sessionID: Int.random(in: 0..<3, using: &generator) == 0
                    ? nil : sessions.randomElement(using: &generator),
                status: statuses.randomElement(using: &generator)!,
                lastHeartbeatAt: heartbeats.randomElement(using: &generator)!,
                completionUnread: Int.random(in: 0..<5, using: &generator) == 0)
            subtask.isAssignmentOnly = Int.random(in: 0..<4, using: &generator) == 0
            if Int.random(in: 0..<2, using: &generator) == 0 {
                subtask.parentSubtaskID = ids.randomElement(using: &generator)
            }
            if Int.random(in: 0..<3, using: &generator) == 0 {
                subtask.associatedSubtaskIDs = [ids.randomElement(using: &generator)!,
                    ids.randomElement(using: &generator)!]
            }
            if Int.random(in: 0..<6, using: &generator) == 0 {
                subtask.mergedIntoSubtaskID = ids.randomElement(using: &generator)
            }
            if Int.random(in: 0..<6, using: &generator) == 0 { subtask.agentRemovedAt = now.addingTimeInterval(-60) }
            if Int.random(in: 0..<8, using: &generator) == 0 { subtask.completedRuntimeOpenedAt = now }
            if Int.random(in: 0..<8, using: &generator) == 0 { subtask.completionOverrideAt = now }
            if Int.random(in: 0..<5, using: &generator) == 0 { subtask.tmux = nil; subtask.terminalPaneID = 7 }
            subtask.attention = attentions.randomElement(using: &generator)!
            context.subtasks.append(subtask)
        }
        return context
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// The pre-index implementations, kept verbatim as the behavioral reference.
private enum LegacyProjection {
    static func canonical(_ context: TaskContext, _ id: String) -> String {
        var current = id
        var seen = Set<String>()
        while seen.insert(current).inserted,
              let next = context.subtasks.first(where: { $0.id == current })?.mergedIntoSubtaskID {
            current = next
        }
        return current
    }

    static func assignmentIDs(_ context: TaskContext, _ agent: TaskSubtask) -> Set<String> {
        Set(([agent.parentSubtaskID ?? agent.id] + agent.associatedSubtaskIDs).map { canonical(context, $0) })
    }

    static func agents(_ context: TaskContext, _ subtaskID: String, includingRemoved: Bool = false) -> [TaskSubtask] {
        var seen = Set<String>()
        return context.subtasks.sorted {
            ($0.lastHeartbeatAt ?? .distantPast) > ($1.lastHeartbeatAt ?? .distantPast)
        }.filter { agent in
            guard agent.hasAgent, assignmentIDs(context, agent).contains(canonical(context, subtaskID)),
                  includingRemoved || agent.isAgentVisible || agent.completionUnread else { return false }
            let identity = agent.sessionID.map { agent.provider.rawValue + ":" + $0.lowercased() } ?? agent.id
            return seen.insert(identity).inserted
        }
    }

    static func priority(_ context: TaskContext, _ subtask: TaskSubtask, now: Date) -> Int {
        let agents = agents(context, subtask.id)
        if subtask.effectiveStatus(now: now) == .working
            || agents.contains(where: { $0.effectiveStatus(now: now) == .working }) { return 0 }
        if subtask.status == .blocked || agents.contains(where: { $0.attention != nil }) { return 1 }
        if subtask.effectiveStatus(now: now) == .idle { return 2 }
        if subtask.status == .queued { return 3 }
        return 4
    }

    static func focusSubtasks(_ context: TaskContext, now: Date) -> [TaskSubtask] {
        context.subtasks.enumerated()
            .filter { $0.element.parentSubtaskID == nil && $0.element.mergedIntoSubtaskID == nil }
            .sorted {
                let lhs = priority(context, $0.element, now: now)
                let rhs = priority(context, $1.element, now: now)
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }.map(\.element)
    }

    static func taskItems(_ context: TaskContext, now: Date) -> [TaskSubtask] {
        var items: [TaskSubtask] = []
        var seenRecords = Set<String>()
        var seenSessions = Set<String>()
        func append(_ item: TaskSubtask) {
            guard item.agentRemovedAt == nil else { return }
            guard seenRecords.insert(item.id).inserted else { return }
            if let sessionID = item.sessionID?.lowercased() {
                guard seenSessions.insert(item.provider.rawValue + ":" + sessionID).inserted else { return }
            }
            items.append(item)
        }
        for root in focusSubtasks(context, now: now) {
            let linked = agents(context, root.id)
            if root.isAssignmentOnly, !linked.isEmpty {
                for var agent in linked {
                    if agent.assignmentDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        agent.assignmentDescription = root.workDescription
                    }
                    if agent.title.hasPrefix(agent.provider.displayName + " ·")
                        || agent.title.hasPrefix("Subagent ·") {
                        agent.title = root.title
                    }
                    append(agent)
                }
            } else {
                append(root)
                for agent in linked where agent.id != root.id { append(agent) }
            }
        }
        return items
    }

    static func refreshAssignmentStatuses(_ context: inout TaskContext) {
        for index in context.subtasks.indices
        where context.subtasks[index].parentSubtaskID == nil && context.subtasks[index].mergedIntoSubtaskID == nil {
            guard context.subtasks[index].completionOverrideAt == nil else { continue }
            let snapshot = context
            let hasLinkedRecords = snapshot.subtasks.contains {
                $0.id != snapshot.subtasks[index].id
                    && assignmentIDs(snapshot, $0).contains(snapshot.subtasks[index].id)
            }
            guard hasLinkedRecords else { continue }
            let children = agents(snapshot, snapshot.subtasks[index].id, includingRemoved: true)
            if context.subtasks[index].workspace == nil {
                context.subtasks[index].workspace = children.first(where: { $0.workspace != nil })?.workspace
            }
            let active = children.filter { $0.agentRemovedAt == nil || $0.status == .completed }
            guard !active.isEmpty else {
                if context.subtasks[index].status != .completed { context.subtasks[index].status = .queued }
                continue
            }
            if active.allSatisfy({ $0.status == .completed }) { context.subtasks[index].status = .completed }
            else if active.contains(where: { $0.status == .working }) { context.subtasks[index].status = .working }
            else if active.contains(where: { $0.status == .blocked }) { context.subtasks[index].status = .blocked }
            else if active.contains(where: { $0.status == .idle }) { context.subtasks[index].status = .idle }
            else { context.subtasks[index].status = .queued }
        }
    }
}
