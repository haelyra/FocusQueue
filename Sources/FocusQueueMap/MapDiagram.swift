import Foundation

/// Reusable presentation template. A collector supplies facts; a projection
/// chooses visible nodes; this value handles packing independently of task UI.
/// Edges may contain cycles. Only containment passed to forest() must be a tree.
public struct MapDiagram: Codable, Sendable {
    public static let nodeWidth = 176.0, nodeHeight = 58.0, column = 208.0, row = 72.0
    public struct Item: Identifiable, Codable, Sendable {
        public var id: String
        public var node: MapNode
        public var x: Double
        public var y: Double
        public var role: String
        public var expansionID: String?
        public var hiddenChildren: Int
    }
    public struct Edge: Codable, Sendable {
        public var from: String
        public var to: String
        public var kind: String
    }
    public struct Container: Identifiable, Codable, Sendable {
        public var id: String
        public var label: String
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }
    public var items: [Item] = []
    public var edges: [Edge] = []
    public var containers: [Container] = []
    public var limit: Int = 180
    public var width: Double { max(240, items.map { $0.x + Self.nodeWidth + 16 }.max() ?? 0, containers.map { $0.x + $0.width + 12 }.max() ?? 0) }
    public var height: Double { max(300, items.map { $0.y + Self.nodeHeight + 16 }.max() ?? 0, containers.map { $0.y + $0.height + 12 }.max() ?? 0) }
    public init(limit: Int = 180) { self.limit = max(4, limit) }

    @discardableResult public mutating func add(_ node: MapNode, id: String? = nil, x: Double, y: Double,
                                               role: String, expansion: String? = nil, hidden: Int = 0) -> String {
        let key = id ?? node.id
        guard items.count < limit, !items.contains(where: { $0.id == key }) else { return key }
        items.append(Item(id: key, node: node, x: x, y: y, role: role, expansionID: expansion, hiddenChildren: hidden))
        return key
    }
    public mutating func connect(_ from: String, _ to: String, kind: String) {
        guard from != to, !edges.contains(where: { $0.from == from && $0.to == to && $0.kind == kind }) else { return }
        edges.append(Edge(from: from, to: to, kind: kind))
    }
    public mutating func finish() {
        let ids = Set(items.map(\.id)); edges.removeAll { !ids.contains($0.from) || !ids.contains($0.to) }
    }

    /// Returns occupied height and column count. Parents consume their children's
    /// span, making expansion local and deterministic instead of a global force layout.
    public mutating func forest(nodes: [MapNode], roots: [String], prefix: String, x: Double, y: Double,
                                role: String, hidden: [String: Int] = [:]) -> (Double, Int) {
        let index = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let children = Dictionary(grouping: nodes, by: { $0.parentID ?? "" })
        var row = 0, depthMax = 0, visited = Set<String>()
        func visit(_ id: String, depth: Int, diagram: inout MapDiagram) -> Double? {
            guard depth < 30, diagram.items.count < diagram.limit,
                  let node = index[id], visited.insert(id).inserted else { return nil }
            let key = prefix + id, slot = diagram.items.count
            diagram.add(node, id: key, x: x, y: y, role: role, expansion: hidden[id] != nil ? id : nil, hidden: hidden[id] ?? 0)
            let descendants = (children[id] ?? []).sorted { ($0.label, $0.id) < ($1.label, $1.id) }
            var positions: [Double] = []
            for child in descendants {
                if let position = visit(child.id, depth: depth + 1, diagram: &diagram) {
                    positions.append(position); diagram.connect(key, prefix + child.id, kind: "hierarchy")
                }
            }
            let position: Double
            if positions.isEmpty { position = Double(row); row += 1 }
            else { position = (positions.first! + positions.last!) / 2 }
            depthMax = max(depthMax, depth)
            diagram.items[slot].x = x + Double(depth) * Self.column
            diagram.items[slot].y = y + position * Self.row
            return position
        }
        for root in roots { _ = visit(root, depth: 0, diagram: &self) }
        return (Double(max(1, row)) * Self.row, depthMax + 1)
    }
}

public enum WorkspaceMapMode: String, CaseIterable, Sendable { case typical, context, agent }
public struct WorkspaceMapOptions: Sendable {
    public var mode: WorkspaceMapMode = .typical
    public var agentID: String?
    public var expanded = Set<String>()
    public var expandedView = false
    public var includeOlderScope = false
    public var showOtherFiles = false
    public var search = ""
    public var attentionOnly = false
    public var changesOnly = false
    public var scopeLifetime: TimeInterval = 1800
    public init() {}
}
