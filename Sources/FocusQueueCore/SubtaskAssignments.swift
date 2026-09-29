import Foundation

public enum AgentAttention: String, Codable, Sendable, CaseIterable {
    case approval, question, interrupted, incomplete, failed, quotaExhausted

    public var isProblem: Bool { [.interrupted, .incomplete, .failed, .quotaExhausted].contains(self) }
    public var label: String {
        switch self {
        case .approval: "Needs approval"
        case .question: "Needs an answer"
        case .interrupted: "Interrupted"
        case .incomplete: "Incomplete"
        case .failed: "Problem"
        case .quotaExhausted: "Quota exhausted"
        }
    }
    public var icon: String {
        switch self {
        case .approval: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .interrupted: "pause.circle.fill"
        case .incomplete, .failed: "exclamationmark.circle.fill"
        case .quotaExhausted: "bolt.slash.fill"
        }
    }
}

extension TaskContext {
    public func canonicalSubtaskID(_ id: String) -> String {
        var current = id
        var seen = Set<String>()
        while seen.insert(current).inserted,
              let next = subtasks.first(where: { $0.id == current })?.mergedIntoSubtaskID {
            current = next
        }
        return current
    }

    public func assignmentIDs(for agent: TaskSubtask) -> Set<String> {
        Set(([agent.parentSubtaskID ?? agent.id] + agent.associatedSubtaskIDs).map(canonicalSubtaskID))
    }

    /// Older contexts stored one record as both the work assignment and its
    /// provider runtime. Split those roles while retaining the runtime ID so
    /// existing CLI progress commands and saved sessions keep working.
    mutating func separateLegacyAgentAssignments() {
        guard schemaVersion < TaskContext.currentSchemaVersion else { return }
        var usedIDs = Set(subtasks.map(\.id))
        var separated: [TaskSubtask] = []
        separated.reserveCapacity(subtasks.count * 2)

        for var agent in subtasks {
            guard agent.parentSubtaskID == nil, agent.mergedIntoSubtaskID == nil,
                  !agent.isAssignmentOnly, agent.hasAgent else {
                separated.append(agent)
                continue
            }

            var assignmentID = "assignment-\(agent.id)"
            var suffix = 2
            while usedIDs.contains(assignmentID) {
                assignmentID = "assignment-\(agent.id)-\(suffix)"
                suffix += 1
            }
            usedIDs.insert(assignmentID)

            var assignment = TaskSubtask(
                id: assignmentID, title: agent.title,
                assignmentDescription: agent.assignmentDescription,
                provider: agent.provider, status: agent.status,
                progressSummary: agent.progressSummary,
                lastHeartbeatAt: agent.lastHeartbeatAt,
                lastOutputAt: agent.lastOutputAt,
                includeInitializationPrompt: agent.includeInitializationPrompt,
                runtimeMode: nil)
            assignment.workspace = agent.workspace
            assignment.initialPrompt = agent.initialPrompt
            assignment.tracksCompletion = agent.tracksCompletion
            assignment.completionOverrideAt = agent.completionOverrideAt
            assignment.isAssignmentOnly = true

            agent.parentSubtaskID = assignmentID
            agent.tracksCompletion = false
            separated.append(assignment)
            separated.append(agent)
        }

        let changed = separated != subtasks
        if changed { subtasks = separated }
        schemaVersion = TaskContext.currentSchemaVersion
        if changed { refreshAssignmentStatuses() }
    }

    /// Assignments survive runtime removal and have a stable order within each priority.
    public var focusSubtasks: [TaskSubtask] {
        subtasks.enumerated().filter { $0.element.parentSubtaskID == nil && $0.element.mergedIntoSubtaskID == nil }
            .sorted {
                let lhs = priority($0.element), rhs = priority($1.element)
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }.map(\.element)
    }

    /// The queue presents assignments and provider runtimes as one item type.
    /// Legacy split records stay readable, but their assignment metadata is
    /// folded into the visible runtime instead of producing a second UI row.
    public var taskItems: [TaskSubtask] {
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
        for root in focusSubtasks {
            let linked = agents(for: root.id)
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

    public func agents(for subtaskID: String, includingRemoved: Bool = false) -> [TaskSubtask] {
        var seen = Set<String>()
        return subtasks.sorted { ($0.lastHeartbeatAt ?? .distantPast) > ($1.lastHeartbeatAt ?? .distantPast) }.filter { agent in
            guard agent.hasAgent, assignmentIDs(for: agent).contains(canonicalSubtaskID(subtaskID)),
                  includingRemoved || agent.isAgentVisible || agent.completionUnread else { return false }
            let identity = agent.sessionID.map { agent.provider.rawValue + ":" + $0.lowercased() } ?? agent.id
            return seen.insert(identity).inserted
        }
    }

    public func canAutomaticallyRetire(_ agent: TaskSubtask) -> Bool {
        guard agent.hasAgent, agent.status == .completed, agent.agentRemovedAt == nil, agent.completedRuntimeOpenedAt == nil else { return false }
        guard let sessionID = agent.sessionID else { return true }
        return !subtasks.contains {
            $0.id != agent.id && $0.provider == agent.provider && $0.sessionID?.lowercased() == sessionID.lowercased()
                && $0.agentRemovedAt == nil && $0.status != .completed
        }
    }

    private func priority(_ subtask: TaskSubtask) -> Int {
        let agents = agents(for: subtask.id)
        if subtask.effectiveStatus() == .working || agents.contains(where: { $0.effectiveStatus() == .working }) { return 0 }
        if subtask.status == .blocked || agents.contains(where: { $0.attention != nil }) { return 1 }
        if subtask.effectiveStatus() == .idle { return 2 }
        if subtask.status == .queued { return 3 }
        return 4
    }

    mutating func refreshAssignmentStatuses() {
        for index in subtasks.indices where subtasks[index].parentSubtaskID == nil && subtasks[index].mergedIntoSubtaskID == nil {
            guard subtasks[index].completionOverrideAt == nil else { continue }
            let hasLinkedRecords = subtasks.contains {
                $0.id != subtasks[index].id && assignmentIDs(for: $0).contains(subtasks[index].id)
            }
            guard hasLinkedRecords else { continue }
            let children = agents(for: subtasks[index].id, includingRemoved: true)
            if subtasks[index].workspace == nil { subtasks[index].workspace = children.first(where: { $0.workspace != nil })?.workspace }
            // Removed unfinished attempts remain history; they cannot block a replacement.
            let active = children.filter { $0.agentRemovedAt == nil || $0.status == .completed }
            guard !active.isEmpty else {
                if subtasks[index].status != .completed { subtasks[index].status = .queued }
                continue
            }
            if active.allSatisfy({ $0.status == .completed }) { subtasks[index].status = .completed }
            else if active.contains(where: { $0.status == .working }) { subtasks[index].status = .working }
            else if active.contains(where: { $0.status == .blocked }) { subtasks[index].status = .blocked }
            else if active.contains(where: { $0.status == .idle }) { subtasks[index].status = .idle }
            else { subtasks[index].status = .queued }
        }
    }

    mutating func mergeSharedAgentSubtasks() {
        let agents = subtasks.filter(\.hasAgent)
        let grouped = Dictionary(grouping: agents) {
            $0.sessionID?.lowercased() ?? "record:" + $0.id
        }
        // Include provider in the identity. Equal IDs from different providers do not link work.
        for group in grouped.values {
            for provider in AgentProvider.allCases {
                let records = group.filter { $0.provider == provider }
                let ids = records.reduce(into: Set<String>()) { $0.formUnion(assignmentIDs(for: $1)) }
                let indices = subtasks.indices.filter { ids.contains(subtasks[$0].id) && subtasks[$0].parentSubtaskID == nil && subtasks[$0].mergedIntoSubtaskID == nil }
                guard let primary = indices.first, indices.count > 1 else { continue }
                let canonicalID = subtasks[primary].id
                let titles = indices.map { subtasks[$0].title }
                let prompts = indices.map { subtasks[$0].initialPrompt ?? subtasks[$0].title }
                var seenTitles = Set<String>()
                subtasks[primary].title = titles.filter { seenTitles.insert($0).inserted }.joined(separator: " + ")
                subtasks[primary].initialPrompt = prompts.joined(separator: "\n\n")
                if indices.contains(where: { subtasks[$0].status != .completed }) {
                    subtasks[primary].status = indices.contains(where: { subtasks[$0].status == .working }) ? .working : .queued
                    subtasks[primary].completionOverrideAt = nil
                }
                for index in indices.dropFirst() { subtasks[index].mergedIntoSubtaskID = canonicalID }
            }
        }
        refreshAssignmentStatuses()
    }
}
