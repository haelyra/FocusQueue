import CryptoKit
import Foundation

public struct TaskMaintenanceReceipt: Codable, Equatable, Sendable {
    public var ticketID: String
    public var agentStates: [String: String]
    public var notes: [String]
    public init(ticketID: String, agentStates: [String: String] = [:], notes: [String] = []) {
        self.ticketID = ticketID; self.agentStates = agentStates; self.notes = notes
    }
}

/// One bounded, task-locked pass. Missing ownership data is a retain decision,
/// never evidence of completion. No model calls, priority edits, or remote writes.
public actor TaskMaintenance {
    public struct Lease: Sendable {
        private let descriptor: Int32
        init(_ lock: TmuxOrganizerLock) { descriptor = lock.descriptor }
        public func release() { TmuxOrganizerLock(descriptor: descriptor).release() }
    }
    private let root: URL
    private let inspect: @Sendable (TaskSubtask) async throws -> Bool
    private let cleanup: @Sendable (String, TaskSubtask) async throws -> TaskWorktreeCleanupResult

    /// A tick-wide process snapshot keeps maintenance from rerunning ps/lsof
    /// per agent per ticket. Without one, ownership inspects fresh processes.
    public init(root: URL,
        processes: [KnownProviderProcess]? = nil,
        inspect: (@Sendable (TaskSubtask) async throws -> Bool)? = nil,
        cleanup: (@Sendable (String, TaskSubtask) async throws -> TaskWorktreeCleanupResult)? = nil) {
        self.root = root
        self.inspect = inspect ?? { agent in
            // A wrapper preparing an exact resume is already an active owner,
            // even before the native provider lock or tmux pane exists.
            let launches = AgentIntakeStore.load(root: root).filter {
                $0.phase != "blocked" && (($0.sessionID != nil && $0.sessionID?.lowercased() == agent.sessionID?.lowercased())
                    || $0.agentID == agent.id || $0.cwd == agent.workspace?.path)
            }
            if !launches.isEmpty {
                let parents = try await AgentIntakeStore.processParents()
                if launches.contains(where: { receipt in
                    guard let pid = receipt.processID, let started = receipt.processStartedAt else { return false }
                    return parents[pid]?.startedAt == started
                }) { return true }
            }
            if let runtime = agent.tmux {
                do { _ = try await TmuxController().verify(runtime); return true }
                catch TmuxError.stopped { }
            }
            let running: [KnownProviderProcess]
            if let processes { running = processes }
            else { running = try await WezTermController().knownProviderProcesses(requireComplete: true) }
            return running.contains { process in
                (process.provider == agent.provider && process.sessionID.caseInsensitiveCompare(agent.sessionID ?? "") == .orderedSame)
                    || agent.workspace.map { ExternalAgentRegistry.contains(directory: $0.path, path: process.cwd) } == true
            }
        }
        self.cleanup = cleanup ?? { task, agent in
            try await TaskWorktreeManager().cleanupAgent(ticketID: task, subtask: agent, store: TaskContextStore(root: root))
        }
    }

    public static func lease(ticketID: String, root: URL) async throws -> Lease {
        let key = SHA256.hash(data: Data((root.standardizedFileURL.path + ":" + ticketID.uppercased()).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return try await Lease(TmuxOrganizerLock.acquire(name: "task-maintenance-" + String(key.prefix(48))))
    }

    /// True when a live process still owns this agent. Callers must treat a
    /// thrown error as "retain"; only a definitive false authorizes cleanup.
    public func ownsLiveProcess(_ agent: TaskSubtask) async throws -> Bool {
        try await inspect(agent)
    }

    public func requireInactive(_ agent: TaskSubtask) async throws {
        guard agent.completionTerminalRetained != true else {
            throw TaskContextError.unsafeWorktree("Workspace retained for the completed conversation and its resume command.")
        }
        guard try await !inspect(agent) else {
            throw TaskContextError.unsafeWorktree("A live agent still owns this workspace; retained.")
        }
    }

    public func run(ticket: DashboardTicket, allowCleanup: Bool = true) async throws -> TaskMaintenanceReceipt {
        let lease = try await Self.lease(ticketID: ticket.id, root: root)
        defer { lease.release() }
        let store = TaskContextStore(root: root)
        let context = try await store.ensureContext(ticket: ticket)
        let path = context.contextDirectory.appendingPathComponent("maintenance.json")
        let previous = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(TaskMaintenanceReceipt.self, from: $0) }
        var receipt = TaskMaintenanceReceipt(ticketID: context.ticketID, agentStates: [:], notes: [])
        if context.successCriteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            receipt.notes.append("Success criteria are unfilled; safe work can continue. Clarify before final verification.")
        }
        for agent in context.subtasks where !agent.isAssignmentOnly && agent.agentRemovedAt == nil {
            let state: String
            if agent.sessionID.flatMap(UUID.init(uuidString:)) == nil {
                state = "Tracked; provider identity pending."
            } else if agent.status != .completed {
                state = agent.effectiveStatus() == .working ? "Working" : agent.resultID != nil ? "Response ready; assignment remains open." : "Awaiting activity"
            } else if agent.workspace?.managed != true {
                state = "Verified; workspace retained because automatic cleanup ownership is absent."
            } else if let path = agent.workspace?.path, !FileManager.default.fileExists(atPath: path) {
                state = previous?.agentStates[agent.id]?.hasPrefix("Cleaned;") == true
                    ? "Cleaned; branch and task documents retained." : "Workspace missing; task record retained for review or restore."
            } else if !allowCleanup {
                state = "Verified; cleanup inspection only."
            } else {
                do {
                    if try await inspect(agent) { state = "Verified; live agent retains its workspace." }
                    else {
                        let result = try await cleanup(context.ticketID, agent)
                        state = result.removed ? "Cleaned; branch and task documents retained." : result.message
                    }
                } catch { state = "Retained: \(error.localizedDescription)" }
            }
            receipt.agentStates[agent.id] = state
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(receipt)
        if (try? Data(contentsOf: path)) != data {
            try data.write(to: path, options: .atomic)
            // A stable receipt suppresses repeated nags and records only changed findings.
            let audit = context.contextDirectory.appendingPathComponent("maintenance-history")
            try FileManager.default.createDirectory(at: audit, withIntermediateDirectories: true)
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try data.write(to: audit.appendingPathComponent(fingerprint + ".json"), options: .atomic)
        }
        return receipt
    }
}
