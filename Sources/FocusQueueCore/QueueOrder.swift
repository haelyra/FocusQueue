import Darwin
import Foundation

public enum QueuePlacement: Sendable {
    case top, bottom, before(String), after(String)
}

/// A manual adjustment to one automatic queue snapshot. It remains applicable
/// only while the same sort mode produces the same automatic order.
public struct QueueOrderDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var orderedIDs: [String]
    public var automaticBaselineIDs: [String]
    public var sortMode: QueueActivitySortMode

    public init(
        schemaVersion: Int = QueueOrderDocument.currentSchemaVersion,
        orderedIDs: [String],
        automaticBaselineIDs: [String],
        sortMode: QueueActivitySortMode
    ) {
        self.schemaVersion = schemaVersion
        self.orderedIDs = orderedIDs
        self.automaticBaselineIDs = automaticBaselineIDs
        self.sortMode = sortMode
    }

    public func applies(to automaticIDs: [String], sortMode: QueueActivitySortMode) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && self.sortMode == sortMode
            && automaticBaselineIDs == automaticIDs
    }
}

/// Shared by the app and its agent helper. A separate file prevents unrelated
/// cached app state from overwriting an agent's queue changes.
public struct QueueOrderStore: Sendable {
    /// Posted after a saved order changes outside the app, so the queue shows
    /// the new order immediately instead of on its next poll.
    public static let changeNotificationName = "com.haelyra.ecc-focus-queue.queue-order"

    public let directory: URL
    private let projectID: String?
    private var legacyFile: URL { directory.appendingPathComponent("order.json") }
    private var file: URL {
        guard let projectID else { return legacyFile }
        let encoded = Data(projectID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent("order-\(encoded).json")
    }

    public var storageURL: URL { file }

    public init(root: URL, projectID: String? = nil) {
        directory = root.appendingPathComponent("queue-order", isDirectory: true)
        self.projectID = projectID
    }

    public func load() throws -> [String]? {
        guard let source = sourceURL() else { return nil }
        let data = try Data(contentsOf: source)
        if let document = try? JSONDecoder().decode(QueueOrderDocument.self, from: data) {
            return document.orderedIDs
        }
        return try JSONDecoder().decode([String].self, from: data)
    }

    /// Versioned overrides are presentation state, unlike legacy arrays. Old
    /// arrays remain readable by `load()` for migration and transactions, but
    /// are intentionally not applied to the dynamic queue.
    public func loadOverride() throws -> QueueOrderDocument? {
        guard let source = sourceURL() else { return nil }
        let data = try Data(contentsOf: source)
        if let document = try? JSONDecoder().decode(QueueOrderDocument.self, from: data) {
            return document
        }
        if (try? JSONDecoder().decode([String].self, from: data)) != nil { return nil }
        return try JSONDecoder().decode(QueueOrderDocument.self, from: data)
    }

    /// Returns the override only for the automatic snapshot it was created
    /// from. A stale versioned override is removed while holding the order lock
    /// so it cannot become active again after another refresh.
    public func applicableOrder(
        automaticIDs: [String], sortMode: QueueActivitySortMode
    ) throws -> [String]? {
        try locked {
            guard let source = sourceURL() else { return nil }
            let data = try Data(contentsOf: source)
            guard let document = try? JSONDecoder().decode(QueueOrderDocument.self, from: data) else {
                if (try? JSONDecoder().decode([String].self, from: data)) != nil { return nil }
                return try JSONDecoder().decode(QueueOrderDocument.self, from: data).orderedIDs
            }
            // A newer build owns future schemas. Ignore them without erasing
            // data this version cannot safely classify as stale.
            guard document.schemaVersion == QueueOrderDocument.currentSchemaVersion else {
                return nil
            }
            guard document.applies(to: automaticIDs, sortMode: sortMode) else {
                if source == file { try FileManager.default.removeItem(at: source) }
                return nil
            }
            return document.orderedIDs
        }
    }

    /// Saved tasks retain their positions; new tasks append in priority order.
    /// Missing, completed, and duplicate IDs never produce phantom rows.
    public static func orderedTickets(_ tickets: [DashboardTicket], savedIDs: [String]) -> [DashboardTicket] {
        let canonical = DashboardOrdering.openTickets(in: tickets)
        var remaining = Dictionary(canonical.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let saved = savedIDs.compactMap { remaining.removeValue(forKey: $0) }
        return saved + canonical.filter { remaining.removeValue(forKey: $0.id) != nil }
    }

    /// Tasks created or touched by an agent within this window lead the
    /// recent-activity queue.
    public static let recentActivityWindow: TimeInterval = 2 * 24 * 60 * 60

    public static func prioritizingActivity(
        _ tickets: [DashboardTicket],
        mode: QueueActivitySortMode,
        lastPromptAtByTicketID: [String: Date],
        lastOutputAtByTicketID: [String: Date],
        now: Date = Date()
    ) -> [DashboardTicket] {
        switch mode {
        case .manual, .phase:
            // Phase order starts from the priority baseline; `prioritizingPins`
            // with a process then groups by phase and dependency.
            return tickets
        case .recentActivity:
            // Ticket edits are excluded: dashboard syncs touch updatedAt without
            // any agent working on the task.
            let cutoff = now.addingTimeInterval(-recentActivityWindow)
            let ranked = tickets.enumerated().map { index, ticket in
                let activity = [lastPromptAtByTicketID[ticket.id], lastOutputAtByTicketID[ticket.id],
                    TaskTriagePolicy.date(from: ticket.createdAt)].compactMap { $0 }.max() ?? .distantPast
                return (index: index, ticket: ticket, activity: activity)
            }
            let recent = ranked.filter { $0.activity >= cutoff }.sorted {
                if $0.activity != $1.activity { return $0.activity > $1.activity }
                return $0.index < $1.index
            }
            // Within a priority, newer activity breaks ties before any saved order.
            let rest = ranked.filter { $0.activity < cutoff }.sorted {
                if $0.ticket.priorityRank != $1.ticket.priorityRank {
                    return $0.ticket.priorityRank < $1.ticket.priorityRank
                }
                if $0.activity != $1.activity { return $0.activity > $1.activity }
                return $0.index < $1.index
            }
            return (recent + rest).map(\.ticket)
        case .triage:
            return TaskTriagePolicy.deadlineOrdered(
                tickets,
                lastPromptAtByTicketID: lastPromptAtByTicketID,
                lastOutputAtByTicketID: lastOutputAtByTicketID)
        case .recentInteraction, .recentOutput:
            let recent = tickets.enumerated().compactMap { index, ticket -> (Int, DashboardTicket, Date)? in
                let activity = mode == .recentInteraction
                    ? lastPromptAtByTicketID[ticket.id]
                    : lastOutputAtByTicketID[ticket.id]
                guard let activity else { return nil }
                return (index, ticket, activity)
            }.sorted {
                if $0.2 != $1.2 { return $0.2 > $1.2 }
                return $0.0 < $1.0
            }
            let recentIDs = Set(recent.map { $0.1.id })
            let remaining = tickets.filter { !recentIDs.contains($0.id) }
            return recent.map(\.1) + TaskTriagePolicy.deadlineOrdered(
                remaining,
                lastPromptAtByTicketID: lastPromptAtByTicketID,
                lastOutputAtByTicketID: lastOutputAtByTicketID)
        }
    }

    /// Pinned tasks form a durable top tier ordered by the newest pin first.
    /// The automatic order remains the stable tie-breaker and controls all
    /// unpinned tasks.
    /// With `phases`, pins lead only within their phase: the phase and
    /// dependency order wins over a pin.
    public static func prioritizingPins(
        _ tickets: [DashboardTicket], pinnedAtByTicketID: [String: Date],
        phases: DevelopmentProcess? = nil
    ) -> [DashboardTicket] {
        let pinned = pinningFirst(tickets, pinnedAtByTicketID: pinnedAtByTicketID)
        guard let phases else { return pinned }
        return phaseOrdered(pinned, process: phases)
    }

    /// The queue's phase groups, in display order. Tasks not yet linked by the
    /// steward come after the phases; tasks marked outside the process come last.
    public enum PhaseGroup: Hashable, Comparable, Sendable {
        case phase(DevelopmentPhase)
        case unphased
        case outsideProcess

        public init(taskID: String, process: DevelopmentProcess) {
            switch process.links[taskID.uppercased()] {
            case .none: self = .unphased
            case .some(let link) where link.step == nil: self = .outsideProcess
            case .some(let link): self = .phase(link.phase)
            }
        }

        var rank: Int {
            switch self {
            case .phase(let phase): DevelopmentPhase.allCases.firstIndex(of: phase) ?? 0
            case .unphased: DevelopmentPhase.allCases.count
            case .outsideProcess: DevelopmentPhase.allCases.count + 1
            }
        }

        public static func < (left: Self, right: Self) -> Bool { left.rank < right.rank }

        public var title: String {
            switch self {
            case .phase(let phase): phase.title
            case .unphased: "No phase yet"
            case .outsideProcess: "Outside the process"
            }
        }
    }

    /// Groups tasks by phase, then orders each phase so a task follows the
    /// tasks it depends on. Ties keep the incoming order, so an order that
    /// already satisfies both rules is returned unchanged; manual moves within
    /// a phase therefore stick. Dependencies across phases or on tasks not in
    /// the list never reorder anything. A cycle (only possible in a
    /// hand-edited file) falls back to the incoming order for its members.
    public static func phaseOrdered(
        _ tickets: [DashboardTicket], process: DevelopmentProcess
    ) -> [DashboardTicket] {
        let groups = tickets.map { PhaseGroup(taskID: $0.id, process: process) }
        let order = tickets.indices.sorted {
            groups[$0] != groups[$1] ? groups[$0] < groups[$1] : $0 < $1
        }
        var result: [DashboardTicket] = []
        var start = 0
        while start < order.count {
            var end = start
            while end < order.count, groups[order[end]] == groups[order[start]] { end += 1 }
            let members = Array(order[start..<end])
            result += dependencyOrdered(members.map { tickets[$0] }, process: process)
            start = end
        }
        return result
    }

    /// Kahn's algorithm, always taking the earliest ready task.
    static func dependencyOrdered(
        _ tickets: [DashboardTicket], process: DevelopmentProcess
    ) -> [DashboardTicket] {
        let indexByID = Dictionary(tickets.enumerated().map { ($0.element.id.uppercased(), $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        var waiting = Array(repeating: 0, count: tickets.count)
        var dependents = Array(repeating: [Int](), count: tickets.count)
        for (index, ticket) in tickets.enumerated() {
            let prerequisites = Set(process.prerequisites(of: ticket.id).compactMap { indexByID[$0] })
            for prerequisite in prerequisites where prerequisite != index {
                waiting[index] += 1
                dependents[prerequisite].append(index)
            }
        }
        var emitted = Array(repeating: false, count: tickets.count)
        var result: [DashboardTicket] = []
        while result.count < tickets.count {
            let next = tickets.indices.first { !emitted[$0] && waiting[$0] == 0 }
                ?? tickets.indices.first { !emitted[$0] }!
            emitted[next] = true
            result.append(tickets[next])
            for dependent in dependents[next] { waiting[dependent] -= 1 }
        }
        return result
    }

    private static func pinningFirst(
        _ tickets: [DashboardTicket], pinnedAtByTicketID: [String: Date]
    ) -> [DashboardTicket] {
        tickets.enumerated().sorted { left, right in
            let leftPin = pinnedAtByTicketID[left.element.id]
            let rightPin = pinnedAtByTicketID[right.element.id]
            switch (leftPin, rightPin) {
            case let (.some(leftDate), .some(rightDate)):
                if leftDate != rightDate { return leftDate > rightDate }
                return left.offset < right.offset
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left.offset < right.offset
            }
        }.map(\.element)
    }

    /// Shared automatic projection for queue helpers and project creation.
    /// Manual placement is deliberately absent; callers apply a matching
    /// temporary override only after this baseline is complete.
    public static func automaticTickets(
        _ tickets: [DashboardTicket],
        deferredTicketIDs: [String],
        mode: QueueActivitySortMode,
        contexts: [TaskContext],
        phases: DevelopmentProcess? = nil,
        now: Date = Date()
    ) -> [DashboardTicket] {
        let promptDates = Dictionary(contexts.compactMap { context in
            context.latestInteractionAt.map { (context.ticketID, $0) }
        }, uniquingKeysWith: max)
        let outputDates = Dictionary(contexts.compactMap { context in
            context.subtasks.compactMap { $0.lastOutputAt ?? $0.resultAt }.max()
                .map { (context.ticketID, $0) }
        }, uniquingKeysWith: max)
        let pinnedDates = Dictionary(contexts.compactMap { context in
            context.pinnedAt.map { (context.ticketID, $0) }
        }, uniquingKeysWith: max)
        let baseline = DashboardOrdering.openTickets(
            in: tickets, deferredTicketIDs: deferredTicketIDs)
        let activity = prioritizingActivity(
            baseline,
            mode: mode,
            lastPromptAtByTicketID: promptDates,
            lastOutputAtByTicketID: outputDates,
            now: now)
        return prioritizingPins(activity, pinnedAtByTicketID: pinnedDates,
                                phases: mode == .phase ? phases : nil)
    }

    @discardableResult
    public func move(_ ticketID: String, to placement: QueuePlacement,
                     tickets: [DashboardTicket], fallbackIDs: [String], visibleIDs: Set<String>? = nil,
                     currentIDs: [String]? = nil, expectedStoredIDs: [String]? = nil,
                     automaticBaselineIDs: [String]? = nil,
                     sortMode: QueueActivitySortMode? = nil) throws -> [String] {
        try locked {
            let versioned = automaticBaselineIDs != nil && sortMode != nil
            let document = try loadOverride()
            let storedIDs = try load()
            let savedIDs = if let automaticBaselineIDs, let sortMode,
                              let document,
                              document.applies(to: automaticBaselineIDs, sortMode: sortMode) {
                document.orderedIDs
            } else if versioned, let currentIDs {
                currentIDs
            } else if let currentIDs, storedIDs == expectedStoredIDs {
                currentIDs
            } else {
                storedIDs ?? fallbackIDs
            }
            let allIDs = Self.orderedTickets(
                tickets, savedIDs: savedIDs).map(\.id)
            var ids = allIDs.filter { visibleIDs?.contains($0) ?? true }
            guard ids.contains(ticketID) else {
                throw TaskContextError.commandFailed("No open task named \(ticketID) exists in this queue.")
            }
            switch placement {
            case .before(let target), .after(let target):
                guard ids.contains(target) else {
                    throw TaskContextError.commandFailed("No open task named \(target) exists in this queue.")
                }
                if target == ticketID { return allIDs }
            default: break
            }
            ids.removeAll { $0 == ticketID }
            switch placement {
            case .top: ids.insert(ticketID, at: 0)
            case .bottom: ids.append(ticketID)
            case .before(let target): ids.insert(ticketID, at: ids.firstIndex(of: target)!)
            case .after(let target): ids.insert(ticketID, at: ids.firstIndex(of: target)! + 1)
            }
            var iterator = ids.makeIterator()
            let result = allIDs.map { id in
                (visibleIDs?.contains(id) ?? true) ? iterator.next()! : id
            }
            if let automaticBaselineIDs, let sortMode {
                try write(QueueOrderDocument(
                    orderedIDs: result,
                    automaticBaselineIDs: automaticBaselineIDs,
                    sortMode: sortMode))
            } else {
                try write(result)
            }
            return result
        }
    }

    /// An explicit empty order restores priority sorting and supersedes legacy deferrals.
    public func reset() throws {
        try locked { try write([]) }
    }

    /// Replaces the saved order with the given IDs. Open tasks the caller
    /// omitted keep their relative order at the end, so a partial list never
    /// drops tasks from the queue.
    @discardableResult
    public func setOrder(_ ids: [String], tickets: [DashboardTicket], fallbackIDs: [String],
                         currentIDs: [String]? = nil, expectedStoredIDs: [String]? = nil,
                         automaticBaselineIDs: [String]? = nil,
                         sortMode: QueueActivitySortMode? = nil) throws -> [String] {
        try locked {
            let versioned = automaticBaselineIDs != nil && sortMode != nil
            let document = try loadOverride()
            let storedIDs = try load()
            let savedIDs = if let automaticBaselineIDs, let sortMode,
                              let document,
                              document.applies(to: automaticBaselineIDs, sortMode: sortMode) {
                document.orderedIDs
            } else if versioned, let currentIDs {
                currentIDs
            } else if let currentIDs, storedIDs == expectedStoredIDs {
                currentIDs
            } else {
                storedIDs ?? fallbackIDs
            }
            let allIDs = Self.orderedTickets(tickets, savedIDs: savedIDs).map(\.id)
            let known = Set(allIDs)
            var seen = Set<String>()
            var requested: [String] = []
            for id in ids {
                guard known.contains(id) else {
                    throw TaskContextError.commandFailed("No open task named \(id) exists in this queue.")
                }
                if seen.insert(id).inserted { requested.append(id) }
            }
            let result = requested + allIDs.filter { !seen.contains($0) }
            if let automaticBaselineIDs, let sortMode {
                try write(QueueOrderDocument(
                    orderedIDs: result,
                    automaticBaselineIDs: automaticBaselineIDs,
                    sortMode: sortMode))
            } else {
                try write(result)
            }
            return result
        }
    }

    public func reset(tickets: [DashboardTicket], visibleIDs: Set<String>, fallbackIDs: [String]) throws -> [String] {
        try locked {
            let all = Self.orderedTickets(tickets, savedIDs: try load() ?? fallbackIDs).map(\.id)
            var sorted = DashboardOrdering.openTickets(in: tickets).filter { visibleIDs.contains($0.id) }.map(\.id).makeIterator()
            let result = all.map { visibleIDs.contains($0) ? sorted.next()! : $0 }
            try write(result)
            return result
        }
    }

    private func write(_ ids: [String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(ids).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func write(_ document: QueueOrderDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func sourceURL() -> URL? {
        if FileManager.default.fileExists(atPath: file.path) { return file }
        if projectID != nil, FileManager.default.fileExists(atPath: legacyFile.path) { return legacyFile }
        return nil
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        let directoryAlreadyExisted = FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !directoryAlreadyExisted {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let descriptor = Darwin.open(directory.appendingPathComponent("order.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
