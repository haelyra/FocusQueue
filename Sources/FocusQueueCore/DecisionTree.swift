import Darwin
import Foundation

// Decision trees: one per agent, recorded when the agent's work departs from the
// user's instruction, the master plan, or the task plan. Each node keeps a git
// checkpoint of the agent's worktree (a commit under refs/focus-queue/decisions/,
// pushed to the remote) and a snapshot of the provider conversation, so the user,
// or the agent when Settings allow it, can rewind both to the decision and take
// another option.
//
// A tree lives at tasks/<TASK-ID>/decisions/<AGENT-ID>.json with conversation
// snapshots in tasks/<TASK-ID>/decisions/<AGENT-ID>/. The app and the CLI
// read-modify-write a tree under an exclusive flock on <AGENT-ID>.lock.

/// What a decision departs from.
public enum DecisionDivergence: String, Codable, CaseIterable, Sendable {
    case userInstruction = "user-instruction"
    case masterPlan = "master-plan"
    case taskPlan = "task-plan"
    case other

    public var label: String {
        switch self {
        case .userInstruction: "User instruction"
        case .masterPlan: "Master plan"
        case .taskPlan: "Task plan"
        case .other: "Other"
        }
    }

    public init?(argument: String) {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user", "instruction", "user-instruction", "user_instruction": self = .userInstruction
        case "master", "master-plan", "master_plan", "project-plan": self = .masterPlan
        case "task", "task-plan", "task_plan", "plan": self = .taskPlan
        case "other": self = .other
        default: return nil
        }
    }
}

/// Who settled a decision or started a path.
public enum DecisionActor: String, Codable, CaseIterable, Sendable {
    case user, agent, auto
    /// The user answered "continue", which means the recommended option.
    case `continue`

    /// For the user, in the app.
    public var label: String {
        switch self {
        case .user: "you"
        case .agent: "the agent"
        case .auto: "auto-decide"
        case .continue: "you (continue)"
        }
    }

    /// For logs and agents, which read it in the third person.
    public var logLabel: String {
        switch self {
        case .user: "the user"
        case .agent: "the agent"
        case .auto: "auto-decide"
        case .continue: "the user (continue)"
        }
    }
}

public struct DecisionOption: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String?

    public init(id: String, label: String, detail: String? = nil) {
        self.id = id; self.label = label; self.detail = detail
    }
}

/// A commit holding the whole worktree (tracked and untracked, minus ignored
/// files) at one moment, parented on the branch head of that moment. The branch,
/// index, and working tree are never touched to make it.
public struct DecisionCheckpoint: Codable, Equatable, Sendable {
    public var commit: String
    public var parent: String?
    public var branch: String?
    public var ref: String
    public var workspace: String
    public var remote: String?
    public var pushedAt: String?
    public var pushError: String?

    public init(commit: String, parent: String?, branch: String?, ref: String, workspace: String,
                remote: String? = nil, pushedAt: String? = nil, pushError: String? = nil) {
        self.commit = commit; self.parent = parent; self.branch = branch; self.ref = ref
        self.workspace = workspace; self.remote = remote; self.pushedAt = pushedAt; self.pushError = pushError
    }

    public var pushed: Bool { pushedAt != nil }
    public var shortCommit: String { String(commit.prefix(10)) }
}

/// The provider conversation as it stood at a node.
public struct DecisionConversation: Codable, Equatable, Sendable {
    public var provider: String
    public var sessionID: String?
    /// A copy of the transcript up to the decision, resumable as a fresh session.
    public var snapshotPath: String?
    public var transcriptPath: String?
    public var entries: Int?
    /// Why the conversation could not be saved, when it could not.
    public var note: String?

    public init(provider: String, sessionID: String?, snapshotPath: String? = nil,
                transcriptPath: String? = nil, entries: Int? = nil, note: String? = nil) {
        self.provider = provider; self.sessionID = sessionID; self.snapshotPath = snapshotPath
        self.transcriptPath = transcriptPath; self.entries = entries; self.note = note
    }

    public var forkable: Bool { snapshotPath != nil }
}

/// One path taken from a node. Rewinding abandons the active path and starts another.
public struct DecisionAttempt: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case active, abandoned }

    public var optionID: String
    public var state: State
    public var startedAt: String
    public var startedBy: DecisionActor
    public var endedAt: String?
    /// Why the path was abandoned.
    public var reason: String?
    /// For a path a rewind started: the worktree just before the rewind, so the
    /// abandoned work stays recoverable.
    public var rewoundFrom: DecisionCheckpoint?
    /// The provider session this path runs in when a rewind forked it.
    public var sessionID: String?

    public init(optionID: String, state: State = .active, startedAt: String, startedBy: DecisionActor,
                endedAt: String? = nil, reason: String? = nil, rewoundFrom: DecisionCheckpoint? = nil,
                sessionID: String? = nil) {
        self.optionID = optionID; self.state = state; self.startedAt = startedAt; self.startedBy = startedBy
        self.endedAt = endedAt; self.reason = reason; self.rewoundFrom = rewoundFrom
        self.sessionID = sessionID
    }
}

public struct DecisionNode: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, decided }

    public var id: String
    public var parentID: String?
    /// The parent's option this node was made under; nil while the parent was undecided.
    public var parentOptionID: String?
    public var title: String
    public var divergence: DecisionDivergence
    public var detail: String?
    /// In recommendation order: the first is recommended, the second is the fallback.
    public var options: [DecisionOption]
    public var status: Status
    public var chosenOptionID: String?
    public var decidedBy: DecisionActor?
    public var decidedAt: String?
    public var createdAt: String
    public var checkpoint: DecisionCheckpoint?
    public var checkpointError: String?
    public var conversation: DecisionConversation?
    public var attempts: [DecisionAttempt]

    public init(id: String, parentID: String?, parentOptionID: String?, title: String,
                divergence: DecisionDivergence, detail: String?, options: [DecisionOption],
                createdAt: String) {
        self.id = id; self.parentID = parentID; self.parentOptionID = parentOptionID; self.title = title
        self.divergence = divergence; self.detail = detail; self.options = options
        self.status = .pending; self.createdAt = createdAt; self.attempts = []
    }

    public var recommendedOptionID: String? { options.first?.id }

    public func option(_ id: String?) -> DecisionOption? {
        guard let id else { return nil }
        return options.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    public var activeAttempt: DecisionAttempt? { attempts.last { $0.state == .active } }

    /// The first option in recommendation order that no path from this node has tried.
    public var nextUntriedOptionID: String? {
        options.first { option in !attempts.contains { $0.optionID == option.id } }?.id
    }
}

/// Where the agent works now: a node, and the option it is following there.
public struct DecisionHead: Codable, Equatable, Sendable {
    public var nodeID: String
    public var optionID: String?

    public init(nodeID: String, optionID: String?) { self.nodeID = nodeID; self.optionID = optionID }
}

/// A restart an agent asked for on itself; a detached process performs it.
public struct DecisionPendingRestart: Codable, Equatable, Sendable {
    public var nodeID: String
    public var prompt: String
    public var requestedAt: String

    public init(nodeID: String, prompt: String, requestedAt: String) {
        self.nodeID = nodeID; self.prompt = prompt; self.requestedAt = requestedAt
    }
}

public struct DecisionTree: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var taskID: String
    public var agentID: String
    public var agentTitle: String?
    public var provider: String?
    public var head: DecisionHead?
    public var nodes: [DecisionNode]
    public var pendingRestart: DecisionPendingRestart?
    public var createdAt: String
    public var updatedAt: String

    public init(taskID: String, agentID: String, agentTitle: String?, provider: String?, now: String) {
        self.schemaVersion = Self.schemaVersion; self.taskID = taskID; self.agentID = agentID
        self.agentTitle = agentTitle; self.provider = provider; self.nodes = []
        self.createdAt = now; self.updatedAt = now
    }

    public func node(_ id: String) -> DecisionNode? {
        nodes.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    public func index(of id: String) -> Int? {
        nodes.firstIndex { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    public var pendingNodes: [DecisionNode] { nodes.filter { $0.status == .pending } }

    /// The newest pending node, which "continue" settles.
    public var latestPending: DecisionNode? { pendingNodes.last }

    public func children(of nodeID: String?, option optionID: String?) -> [DecisionNode] {
        nodes.filter { $0.parentID == nodeID && $0.parentOptionID == optionID }
    }

    /// The node IDs from `nodeID` up to the root, `nodeID` first.
    public func ancestry(of nodeID: String) -> [String] {
        var chain: [String] = []
        var current = node(nodeID)
        while let node = current, !chain.contains(node.id) {
            chain.append(node.id)
            current = node.parentID.flatMap { self.node($0) }
        }
        return chain
    }

    public var nextNodeID: String {
        let used = nodes.compactMap { Int($0.id.dropFirst()) }
        return "D\((used.max() ?? 0) + 1)"
    }

    // MARK: Mutations

    /// Appends a pending node under the head. The caller fills its checkpoint and conversation.
    @discardableResult
    public mutating func addNode(title: String, divergence: DecisionDivergence, detail: String?,
                                 options: [DecisionOption], now: String) -> DecisionNode {
        let node = DecisionNode(id: nextNodeID, parentID: head?.nodeID, parentOptionID: head?.optionID,
                                title: title, divergence: divergence, detail: detail, options: options,
                                createdAt: now)
        nodes.append(node)
        head = DecisionHead(nodeID: node.id, optionID: nil)
        updatedAt = now
        return node
    }

    /// Settles a pending node. Choosing the option a decided node already follows is a no-op.
    public mutating func choose(nodeID: String, optionID: String, by actor: DecisionActor, now: String) throws {
        guard let index = index(of: nodeID) else { throw DecisionTreeError.unknownNode(nodeID) }
        guard let option = nodes[index].option(optionID) else {
            throw DecisionTreeError.unknownOption(optionID, nodes[index].id)
        }
        if nodes[index].status == .decided {
            guard nodes[index].chosenOptionID == option.id else {
                throw DecisionTreeError.alreadyDecided(nodes[index].id, nodes[index].chosenOptionID ?? "?")
            }
            return
        }
        nodes[index].status = .decided
        nodes[index].chosenOptionID = option.id
        nodes[index].decidedBy = actor
        nodes[index].decidedAt = now
        nodes[index].attempts.append(DecisionAttempt(optionID: option.id, startedAt: now, startedBy: actor))
        if head?.nodeID == nodes[index].id || head == nil {
            head = DecisionHead(nodeID: nodes[index].id, optionID: option.id)
        }
        updatedAt = now
    }

    /// Moves the head to `optionID` at `nodeID`. Active paths that leave the new
    /// path are abandoned; ancestors switch to the branch that leads to the node.
    /// `rewoundFrom` is the worktree as it stood before the rewind.
    public mutating func rewind(to nodeID: String, optionID: String, by actor: DecisionActor, reason: String?,
                                rewoundFrom: DecisionCheckpoint?, sessionID: String?, now: String) throws {
        guard let target = index(of: nodeID) else { throw DecisionTreeError.unknownNode(nodeID) }
        guard let option = nodes[target].option(optionID) else {
            throw DecisionTreeError.unknownOption(optionID, nodes[target].id)
        }
        let targetID = nodes[target].id
        let targetPath = ancestry(of: targetID)
        func abandonActive(at position: Int) {
            for attempt in nodes[position].attempts.indices where nodes[position].attempts[attempt].state == .active {
                nodes[position].attempts[attempt].state = .abandoned
                nodes[position].attempts[attempt].endedAt = now
                nodes[position].attempts[attempt].reason = reason
            }
        }
        // Paths below the point where the old and new paths part.
        for id in head.map({ ancestry(of: $0.nodeID) }) ?? [] where !targetPath.contains(id) {
            if let position = index(of: id) { abandonActive(at: position) }
        }
        // Ancestors follow the option that leads to the target.
        for (childID, parentID) in zip(targetPath, targetPath.dropFirst()) {
            guard let child = node(childID), let wanted = child.parentOptionID, let position = index(of: parentID),
                  nodes[position].activeAttempt?.optionID != wanted else { continue }
            abandonActive(at: position)
            nodes[position].status = .decided
            nodes[position].chosenOptionID = wanted
            nodes[position].decidedBy = actor
            nodes[position].decidedAt = now
            nodes[position].attempts.append(DecisionAttempt(optionID: wanted, startedAt: now, startedBy: actor))
        }
        abandonActive(at: target)
        nodes[target].status = .decided
        nodes[target].chosenOptionID = option.id
        nodes[target].decidedBy = actor
        nodes[target].decidedAt = now
        nodes[target].attempts.append(DecisionAttempt(optionID: option.id, startedAt: now, startedBy: actor,
                                                      rewoundFrom: rewoundFrom, sessionID: sessionID))
        head = DecisionHead(nodeID: targetID, optionID: option.id)
        updatedAt = now
    }
}

public enum DecisionTreeError: Error, LocalizedError, Equatable {
    case noTree(String)
    case unknownNode(String)
    case unknownOption(String, String)
    case alreadyDecided(String, String)
    case noPending
    case noOptions
    case nothingToRewind(String)
    case noUntriedOption(String)
    case notAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .noTree(let agent): "Agent \(agent) has no decision tree yet. Record a decision with `focus-queue-session decision add` first."
        case .unknownNode(let node): "No decision named \(node) exists in this tree."
        case .unknownOption(let option, let node): "Decision \(node) has no option \(option)."
        case .alreadyDecided(let node, let option): "Decision \(node) already follows option \(option). Rewind to it to take another option."
        case .noPending: "No decision is waiting for a choice."
        case .noOptions: "Give at least one option with --option \"<recommended>\"; list them in recommendation order."
        case .nothingToRewind(let node): "Decision \(node) has no checkpoint, so its worktree cannot be restored."
        case .noUntriedOption(let node): "Every option of decision \(node) has been tried. Name one with --option."
        case .notAllowed(let reason): reason
        }
    }
}

/// When Focus Queue settles an unanswered decision and whether agents may rewind on their own.
public struct DecisionAutomationSettings: Codable, Equatable, Sendable {
    public static let defaultMinutes = 60
    public static let minutesRange = 1...10_080

    public var autoDecide: Bool
    public var autoDecideMinutes: Int
    public var autoRewind: Bool

    public init(autoDecide: Bool = true, autoDecideMinutes: Int = Self.defaultMinutes, autoRewind: Bool = true) {
        self.autoDecide = autoDecide
        self.autoDecideMinutes = min(max(autoDecideMinutes, Self.minutesRange.lowerBound), Self.minutesRange.upperBound)
        self.autoRewind = autoRewind
    }

    public var interval: TimeInterval { TimeInterval(autoDecideMinutes * 60) }

    private struct Knobs: Decodable {
        var decisionAutoDecide: Bool?
        var decisionAutoDecideMinutes: Int?
        var decisionAutoRewind: Bool?
    }

    /// The saved settings, read from config.json by these keys alone, so an
    /// unrelated field the decoder rejects never turns automation back on.
    public static func load(supportDirectory: URL) -> DecisionAutomationSettings {
        guard let data = try? Data(contentsOf: supportDirectory.appendingPathComponent("config.json")),
              let knobs = try? JSONDecoder().decode(Knobs.self, from: data) else { return DecisionAutomationSettings() }
        return DecisionAutomationSettings(autoDecide: knobs.decisionAutoDecide ?? true,
                                          autoDecideMinutes: knobs.decisionAutoDecideMinutes ?? defaultMinutes,
                                          autoRewind: knobs.decisionAutoRewind ?? true)
    }

    /// "1 hour", "90 minutes", "2 hours".
    public var windowDescription: String {
        let minutes = autoDecideMinutes
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// When a pending node settles itself, or nil when auto-decide is off.
    public func dueDate(for node: DecisionNode) -> Date? {
        guard autoDecide, node.status == .pending, let created = DecisionTreeStore.date(node.createdAt) else { return nil }
        return created.addingTimeInterval(interval)
    }
}

public struct DecisionTreeStore: Sendable {
    /// Posted (distributed) after a tree changes; userInfo carries `task`, `agent`, and `root`.
    public static let notificationName = "com.ecc.focusqueue.decision-tree.changed"
    public static let refPrefix = "refs/focus-queue/decisions"

    public let root: URL

    public init(root: URL) { self.root = root }

    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func validated(_ identifier: String) throws -> String {
        guard !identifier.isEmpty, identifier.count <= 128, identifier.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }) else { throw TaskContextError.invalidIdentifier }
        return identifier
    }

    public func directory(taskID: String) throws -> URL {
        root.appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(try Self.validated(taskID).uppercased(), isDirectory: true)
            .appendingPathComponent("decisions", isDirectory: true)
    }

    /// The tree file for one agent.
    public func treeURL(taskID: String, agentID: String) throws -> URL {
        try directory(taskID: taskID).appendingPathComponent("\(try Self.validated(agentID).uppercased()).json")
    }

    /// Where an agent's conversation snapshots live.
    public func snapshotDirectory(taskID: String, agentID: String) throws -> URL {
        try directory(taskID: taskID).appendingPathComponent(try Self.validated(agentID).uppercased(), isDirectory: true)
    }

    public static func ref(taskID: String, agentID: String, name: String) -> String {
        "\(refPrefix)/\(taskID.uppercased())/\(agentID.uppercased())/\(name)"
    }

    // MARK: Reading

    public func load(taskID: String, agentID: String) throws -> DecisionTree? {
        let url = try treeURL(taskID: taskID, agentID: agentID)
        guard let data = try treeData(at: url) else { return nil }
        return try JSONDecoder().decode(DecisionTree.self, from: data)
    }

    /// Whether an agent has a tree file, without decoding it (cheap enough for menus).
    public func exists(taskID: String, agentID: String) -> Bool {
        guard let url = try? treeURL(taskID: taskID, agentID: agentID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Every readable tree in a task, oldest agent first.
    public func trees(taskID: String) -> [DecisionTree] {
        guard let directory = try? directory(taskID: taskID),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? treeData(at: url))?.flatMap { try? JSONDecoder().decode(DecisionTree.self, from: $0) } }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Every task folder that holds at least one tree.
    public func taskIDsWithTrees() -> [String] {
        let tasks = root.appendingPathComponent("tasks", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: tasks.path)) ?? []
        return folders.filter { folder in
            let decisions = tasks.appendingPathComponent(folder).appendingPathComponent("decisions")
            return ((try? FileManager.default.contentsOfDirectory(atPath: decisions.path)) ?? [])
                .contains { $0.hasSuffix(".json") }
        }.sorted()
    }

    private func treeData(at url: URL) throws -> Data? {
        do { return try SafeFileRead.data(at: url, limit: FileReadLimits.metadataBytes) }
        catch let error as SafeFileReadError { throw error }
        catch { return nil }
    }

    // MARK: Writing

    /// Reads, mutates, and atomically rewrites one tree under its lock. A tree
    /// that cannot be decoded throws rather than being replaced.
    @discardableResult
    public func update<T>(taskID: String, agentID: String, _ body: (inout DecisionTree?) throws -> T) throws -> T {
        let url = try treeURL(taskID: taskID, agentID: agentID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = url.deletingPathExtension().appendingPathExtension("lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        var tree = try treeData(at: url).map { try JSONDecoder().decode(DecisionTree.self, from: $0) }
        let before = tree
        let result = try body(&tree)
        if let tree, tree != before {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(tree).write(to: url, options: .atomic)
        }
        return result
    }

    public func notify(taskID: String, agentID: String, event: String = "change") {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Self.notificationName), object: nil,
            userInfo: ["task": taskID.uppercased(), "agent": agentID.uppercased(), "event": event, "root": root.path],
            deliverImmediately: true)
    }
}
