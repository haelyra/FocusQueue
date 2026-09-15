import CryptoKit
import Foundation

public enum MapNodeKind: String, Codable, Sendable {
    case queue, workspace, folder, file, agent, document, context, section, link, resource
}

public struct MapNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var parentID: String?
    public var kind: MapNodeKind
    public var label: String
    public var path: String?
    public var allowedRoot: String?
    public var summary: String
    public var evidence: String
    public var observedAt: Date?
    public var reportedState: String?
    public var provider: String?
    public var sessionID: String?
    public var subtaskID: String?
    public var gitStatus: String?
    public var destination: String?
    public var durable: Bool?

    public init(id: String, parentID: String?, kind: MapNodeKind, label: String,
                path: String? = nil, allowedRoot: String? = nil, summary: String = "",
                evidence: String, observedAt: Date? = nil, reportedState: String? = nil,
                provider: String? = nil, sessionID: String? = nil, subtaskID: String? = nil,
                gitStatus: String? = nil, destination: String? = nil, durable: Bool? = nil) {
        self.id = id; self.parentID = parentID; self.kind = kind; self.label = label
        self.path = path; self.allowedRoot = allowedRoot; self.summary = summary
        self.evidence = evidence; self.observedAt = observedAt; self.reportedState = reportedState
        self.provider = provider; self.sessionID = sessionID; self.subtaskID = subtaskID
        self.gitStatus = gitStatus; self.destination = destination; self.durable = durable
    }

    public func state(at now: Date = Date()) -> String? {
        guard let reportedState else { return nil }
        guard reportedState == "working" else { return reportedState }
        guard let observedAt, now.timeIntervalSince(observedAt) >= -60,
              now.timeIntervalSince(observedAt) <= 300 else { return "stale" }
        return "working"
    }

    public func needsAttention(at now: Date = Date()) -> Bool {
        ["blocked", "stale", "unknown"].contains(state(at: now) ?? "")
    }

    public static func identity(_ components: String...) -> String {
        SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public struct MapSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var taskID: String
    public var generatedAt: Date
    public var nodes: [MapNode]
    public var warnings: [String]
    public var omittedPaths: Int
    public var relations: [MapRelation] = []

    public init(taskID: String, generatedAt: Date, nodes: [MapNode],
                warnings: [String] = [], omittedPaths: Int = 0, relations: [MapRelation] = []) {
        self.taskID = taskID; self.generatedAt = generatedAt; self.nodes = nodes
        self.warnings = warnings; self.omittedPaths = omittedPaths
        self.relations = relations
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, taskID, generatedAt, nodes, warnings, omittedPaths, relations }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        taskID = try values.decode(String.self, forKey: .taskID)
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        nodes = try values.decode([MapNode].self, forKey: .nodes)
        warnings = try values.decode([String].self, forKey: .warnings)
        omittedPaths = try values.decode(Int.self, forKey: .omittedPaths)
        relations = try values.decodeIfPresent([MapRelation].self, forKey: .relations) ?? []
    }

    public func validated() throws -> Self {
        guard [1, 2].contains(schemaVersion) else { throw MapError.invalidSnapshot("Unsupported map version.") }
        let ids = Set(nodes.map(\.id))
        guard ids.count == nodes.count, nodes.filter({ $0.kind == .queue }).count == 1,
              nodes.first(where: { $0.kind == .queue })?.parentID == nil else {
            throw MapError.invalidSnapshot("Duplicate nodes or missing queue root.")
        }
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        guard Set(relations.map(\.id)).count == relations.count,
              relations.allSatisfy({ ids.contains($0.from) && ids.contains($0.to) &&
                  ($0.kind == .input ? index[$0.to]?.kind == .agent : $0.kind == .output ? index[$0.from]?.kind == .agent : true) }) else {
            throw MapError.invalidSnapshot("Invalid input/output relationship.")
        }
        for node in nodes {
            if node.kind != .queue, node.parentID == nil {
                throw MapError.invalidSnapshot("An item is disconnected from the queue.")
            }
            var seen: Set<String> = [node.id]
            var parent = node.parentID
            while let id = parent {
                guard let ancestor = index[id], seen.insert(id).inserted else {
                    throw MapError.invalidSnapshot("Missing parent or cyclic map.")
                }
                parent = ancestor.parentID
            }
        }
        return self
    }

    public func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data).validated()
    }
}

public enum MapError: Error, LocalizedError {
    case invalidSnapshot(String), unavailable(String), unsafePath(String)
    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot(let reason), .unavailable(let reason), .unsafePath(let reason): reason
        }
    }
}

/// Deterministic columns and a bounded visible tree. The complete collected snapshot
/// stays separate from the expansion and search state of the view.
public struct MapLayout: Sendable {
    public struct Item: Identifiable, Sendable {
        public let node: MapNode
        public let depth: Int
        public let row: Int
        public var id: String { node.id }
    }
    public let items: [Item]
    public let hiddenCount: Int

    public init(snapshot: MapSnapshot, expanded: Set<String>, search: String = "",
                attentionOnly: Bool = false, changesOnly: Bool = false, now: Date = Date(), limit: Int = 100) {
        let index = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let filtering = !search.isEmpty || attentionOnly || changesOnly
        var included = Set<String>()
        if filtering {
            for node in snapshot.nodes where (search.isEmpty ||
                [node.label, node.path ?? "", node.summary, node.provider ?? ""].joined(separator: " ")
                    .localizedCaseInsensitiveContains(search)) && (!attentionOnly || node.needsAttention(at: now)) &&
                    (!changesOnly || node.gitStatus != nil) {
                var current: MapNode? = node
                while let n = current, included.insert(n.id).inserted { current = n.parentID.flatMap { index[$0] } }
            }
        }
        let children = Dictionary(grouping: snapshot.nodes.filter { $0.parentID != nil }, by: { $0.parentID! })
        var result: [Item] = []
        var seen = Set<String>()
        func visit(_ node: MapNode, depth: Int) {
            guard seen.insert(node.id).inserted,
                  !filtering || included.contains(node.id) || node.kind == .queue else { return }
            guard result.count < max(1, limit) else { return }
            result.append(Item(node: node, depth: depth, row: result.count))
            guard filtering || expanded.contains(node.id) || node.kind == .queue else { return }
            let ordered = (children[node.id] ?? []).sorted {
                let lhs = $0.kind == .agent ? "0" : "1", rhs = $1.kind == .agent ? "0" : "1"
                return (lhs, $0.label, $0.id) < (rhs, $1.label, $1.id)
            }
            for child in ordered { visit(child, depth: depth + 1) }
        }
        if let root = snapshot.nodes.first(where: { $0.kind == .queue }) { visit(root, depth: 0) }
        items = result; hiddenCount = max(0, snapshot.nodes.count - result.count)
    }
}
