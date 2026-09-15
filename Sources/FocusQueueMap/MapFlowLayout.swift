import Foundation

/// Legacy v1 layout retained for source compatibility. The app uses the reusable
/// MapDiagram template through WorkspaceMapProjection.
/// Three compact regions per workspace: context hierarchy, agents, output
/// hierarchy. Shared context is drawn once; read/write files have two visual
/// instances backed by the same physical node. Parents share their children's
/// vertical span rather than consuming a blank row of their own.
public struct MapFlowLayout: Sendable {
    public static let nodeWidth = 172.0
    public static let nodeHeight = 62.0
    public static let columnStep = 202.0
    public static let rowStep = 78.0
    public struct Item: Identifiable, Sendable {
        public let id: String
        public let node: MapNode
        public let x: Double
        public let y: Double
        public let role: String
    }
    public struct Line: Sendable {
        public let from: String
        public let to: String
        public let kind: String
        public let agentID: String?
    }
    public struct Section: Identifiable, Sendable {
        public let id: String
        public let label: String
        public let y: Double
        public let height: Double
    }
    public let items: [Item]
    public let lines: [Line]
    public let sections: [Section]
    public let width: Double
    public let height: Double
    public let hiddenCount: Int

    public init(snapshot: MapSnapshot, showOtherFiles: Bool = false, expanded: Set<String> = [],
                search: String = "", attentionOnly: Bool = false, changesOnly: Bool = false, limit: Int = 150) {
        let index = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Item] = [], connections: [Line] = [], groups: [Section] = []
        var cursor = 104.0, maxX = 600.0
        let queue = snapshot.nodes.first { $0.kind == .queue }
        if let queue { result.append(Item(id: queue.id, node: queue, x: 12, y: 12, role: "queue")) }
        func matches(_ node: MapNode) -> Bool {
            search.isEmpty || [node.label, node.path ?? "", node.summary].joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
        func ancestors(_ ids: Set<String>) -> Set<String> {
            var all = ids
            for id in ids {
                var parent = index[id]?.parentID
                var visited = Set<String>()
                while let p = parent, visited.insert(p).inserted, index[p]?.kind != .queue {
                    all.insert(p); parent = index[p]?.parentID
                }
            }
            return all
        }
        // A local forest measures only leaf rows. Folder positions are the
        // midpoint of their descendants, eliminating the old diagonal staircase.
        func forest(_ ids: Set<String>, prefix: String, role: String, x: Double, y: Double) -> (Int, Double) {
            let included = ancestors(ids)
            let children = Dictionary(grouping: included.compactMap { index[$0] }, by: { $0.parentID ?? "queue" })
            let roots = included.compactMap { index[$0] }.filter { !included.contains($0.parentID ?? "") }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
            var leaf = 0, maxDepth = 0
            func visit(_ node: MapNode, depth: Int) -> Double {
                guard result.count < limit else { return Double(leaf) }
                let slot = result.count
                result.append(Item(id: prefix + node.id, node: node, x: x + Double(depth) * Self.columnStep, y: y, role: role))
                let descendants = (children[node.id] ?? []).sorted { ($0.label, $0.id) < ($1.label, $1.id) }
                let row: Double
                if descendants.isEmpty { row = Double(leaf); leaf += 1 }
                else {
                    let rows = descendants.map { visit($0, depth: depth + 1) }
                    row = ((rows.first ?? 0) + (rows.last ?? 0)) / 2
                }
                maxDepth = max(maxDepth, depth)
                let id = prefix + node.id
                result[slot] = Item(id: id, node: node, x: x + Double(depth) * Self.columnStep,
                                   y: y + row * Self.rowStep, role: role)
                for child in descendants where result.contains(where: { $0.id == prefix + child.id }) {
                    connections.append(Line(from: id, to: prefix + child.id, kind: "hierarchy", agentID: nil))
                }
                return row
            }
            for root in roots { _ = visit(root, depth: 0) }
            return (maxDepth + 1, Double(max(leaf, 1)) * Self.rowStep)
        }
        let allAgents = snapshot.nodes.filter { $0.kind == .agent }
        let agents = allAgents.filter { agent in
            let links = snapshot.relations.filter { $0.from == agent.id || $0.to == agent.id }
            return (!attentionOnly || agent.needsAttention()) &&
                (matches(agent) || links.contains { index[$0.from == agent.id ? $0.to : $0.from].map(matches) == true }) &&
                (!changesOnly || links.contains { index[$0.to]?.gitStatus != nil || index[$0.from]?.gitStatus != nil })
        }
        let grouped = Dictionary(grouping: agents, by: { $0.parentID ?? "queue" })
        for groupID in grouped.keys.sorted(by: { (index[$0]?.path ?? $0) < (index[$1]?.path ?? $1) }) {
            guard result.count < limit else { break }
            let groupAgents = (grouped[groupID] ?? []).sorted { ($0.label, $0.id) < ($1.label, $1.id) }
            let agentIDs = Set(groupAgents.map(\.id))
            let relations = snapshot.relations.filter { agentIDs.contains($0.from) || agentIDs.contains($0.to) }
            let inputs = Set(relations.filter { $0.kind == .input }.map(\.from))
            let outputs = Set(relations.filter { $0.kind == .output }.map(\.to))
            let top = cursor + 30
            let inputPrefix = groupID + ":input:", outputPrefix = groupID + ":output:"
            var agentSlots: [(Int, MapNode)] = []
            for agent in groupAgents where result.count < limit {
                agentSlots.append((result.count, agent))
                result.append(Item(id: agent.id, node: agent, x: 0, y: top, role: "Agent"))
            }
            let left = forest(inputs, prefix: inputPrefix, role: "Context", x: 12, y: top)
            let agentX = 12 + Double(max(left.0, 1)) * Self.columnStep + 26
            for (i, slot) in agentSlots.enumerated() {
                result[slot.0] = Item(id: slot.1.id, node: slot.1, x: agentX, y: top + Double(i) * Self.rowStep, role: "Agent")
            }
            let right = forest(outputs, prefix: outputPrefix, role: "Output", x: agentX + Self.columnStep + 26, y: top)
            let groupHeight = max(left.1, Double(groupAgents.count) * Self.rowStep, outputs.isEmpty ? 0 : right.1) + 44
            groups.append(Section(id: groupID, label: index[groupID]?.path ?? "Agents without a workspace", y: cursor, height: groupHeight))
            cursor += groupHeight + 12
            maxX = max(maxX, outputs.isEmpty ? agentX + Self.nodeWidth + 24 : agentX + Self.columnStep + 26 + Double(right.0) * Self.columnStep)
            for relation in relations {
                let agent = relation.kind == .input ? relation.to : relation.from
                connections.append(Line(from: relation.kind == .input ? inputPrefix + relation.from : agent,
                                        to: relation.kind == .input ? agent : outputPrefix + relation.to,
                                        kind: relation.kind.rawValue, agentID: agent))
            }
        }
        let referenced = Set(snapshot.relations.flatMap { [$0.from, $0.to] })
        if showOtherFiles || changesOnly || agents.isEmpty || !search.isEmpty {
            let browsing = MapLayout(snapshot: snapshot, expanded: expanded, search: search, changesOnly: changesOnly)
            let candidates: [MapNode] = browsing.items.map { $0.node }.filter { node in
                guard node.kind != .agent, node.kind != .queue else { return false }
                let eligible = showOtherFiles || changesOnly || !search.isEmpty || node.kind == .document || node.kind == .workspace
                return eligible && (!referenced.contains(node.id) || agents.isEmpty)
            }
            if !candidates.isEmpty {
                let other = forest(Set(candidates.map(\.id)), prefix: "browse:", role: "Files", x: 12, y: cursor + 30)
                groups.append(Section(id: "browse", label: showOtherFiles ? "Directory browser" : "Relevant task files", y: cursor, height: other.1 + 44))
                maxX = max(maxX, Double(other.0) * Self.columnStep + 24); cursor += other.1 + 56
            }
        }
        let visible = Set(result.map(\.id))
        items = result
        lines = connections.filter { visible.contains($0.from) && visible.contains($0.to) }
        sections = groups
        width = maxX; height = max(cursor, 190)
        hiddenCount = max(0, snapshot.nodes.count - Set(result.map { $0.node.id }).count)
    }

    public static func highlightedNodes(agentID: String, snapshot: MapSnapshot) -> Set<String> {
        let relevant = snapshot.relations.filter { $0.from == agentID || $0.to == agentID }
        var ids = Set(relevant.flatMap { [$0.from, $0.to] }); ids.insert(agentID)
        let index = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids {
            var parent = index[id]?.parentID
            var seen = Set<String>()
            while let p = parent, seen.insert(p).inserted { ids.insert(p); parent = index[p]?.parentID }
        }
        return ids
    }
}
