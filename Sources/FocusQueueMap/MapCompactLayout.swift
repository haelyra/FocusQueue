import Foundation

/// Declarative hierarchy used by the map template. All fan-out, including
/// overflow groups, stays <= 4. The normal view uses a 5 x 10 viewport; the
/// expanded view preserves the five-column depth and grows vertically.
public struct MapTree: Sendable {
    public var id: String
    public var node: MapNode
    public var role: String
    public var children: [MapTree] = []
    public var startsCollapsed = false
    public var previews: [MapNode] = []
    public var detailID: String?
    public init(_ node: MapNode, role: String, children: [MapTree] = [], startsCollapsed: Bool = false) {
        self.id = node.id; self.node = node; self.role = role; self.children = children; self.startsCollapsed = startsCollapsed
    }
    public func find(_ id: String) -> Self? {
        if self.id == id || node.id == id { return self }
        for child in children { if let match = child.find(id) { return match } }
        return nil
    }
    public func identified(prefix: String = "root") -> Self {
        var result = self
        result.id = MapNode.identity(prefix, node.id)
        result.children = children.map { $0.identified(prefix: result.id) }
        return result
    }
    public func grouped() -> Self {
        var result = self
        if children.count > 4 {
            let rest = Array(children.dropFirst(3))
            let overflow = MapNode(id: "more:" + node.id + ":" + rest[0].node.id, parentID: node.id, kind: .folder,
                label: "\(rest.count) more items", path: node.path, summary: "\(rest.count) additional items", evidence: "Presentation group")
            result.children = Array(children.prefix(3)) + [MapTree(overflow, role: "More", children: rest, startsCollapsed: true)]
        }
        result.children = result.children.map { $0.grouped() }
        return result
    }
}

public enum MapCompactLayout {
    public static let columns = 5, rows = 10, fanOut = 4
    public static func diagram(queue: MapNode, root: MapTree, options: WorkspaceMapOptions, limit: Int = 180) -> MapDiagram {
        let itemLimit = min(options.expandedView ? 180 : 50, limit)
        var diagram = MapDiagram(limit: itemLimit)
        diagram.add(queue, x: 16, y: 12, role: "Task")
        let grouped = root.grouped().identified()
        let tree: MapTree
        if let id = options.focusedBranchID, let focused = grouped.find(id), focused.id != grouped.id {
            // Drill into a representative, keeping the task workspace alongside it.
            var anchor = grouped; anchor.children = [focused]; anchor.startsCollapsed = false
            tree = anchor
        } else { tree = grouped }
        var cursor = 0.0
        var occupiedRows = 0
        var placedWorktree = false
        @discardableResult func visit(_ tree: MapTree, depth: Int, budget: Int, diagram: inout MapDiagram) -> Double {
            let node = tree.node
            let slot = diagram.items.count
            guard slot < diagram.limit else { return cursor }
            if node.kind == .workspace {
                if placedWorktree { cursor += 28 }
                placedWorktree = true
            }
            let hasChildren = !tree.children.isEmpty
            let requested = options.collapsed.contains(tree.id) || options.collapsed.contains(node.id) || (tree.startsCollapsed && !options.expanded.contains(tree.id) && !options.expanded.contains(node.id) && !options.expandedView && options.focusedBranchID != tree.id && options.focusedBranchID != node.id)
            let budgetCollapsed = depth >= columns - 1 || budget < tree.children.count || slot + tree.children.count >= diagram.limit
            let collapsed = requested || budgetCollapsed
            diagram.add(node, id: tree.id, x: 16 + Double(depth) * MapDiagram.column, y: 0, role: tree.role,
                expansion: hasChildren ? tree.id : nil, hidden: collapsed ? tree.children.count : 0)
            diagram.items[slot].isExpanded = hasChildren && !collapsed
            diagram.items[slot].focusOnExpand = hasChildren && budgetCollapsed
            diagram.items[slot].previews = tree.previews
            diagram.items[slot].detailID = tree.detailID
            let center: Double
            if !hasChildren || collapsed {
                center = cursor
                cursor += MapDiagram.row
                occupiedRows += 1
            }
            else {
                var centers: [Double] = [], remaining = budget
                for (i, child) in tree.children.enumerated() {
                    let quota = max(1, remaining / (tree.children.count - i))
                    let before = occupiedRows
                    centers.append(visit(child, depth: depth + 1, budget: quota, diagram: &diagram))
                    remaining -= occupiedRows - before
                    diagram.connect(tree.id, child.id, kind: child.role == "Output" || child.role == "Recent change" ? "output" : child.node.kind == .agent ? "assignment" : "hierarchy")
                }
                center = (centers.first! + centers.last!) / 2
            }
            diagram.items[slot].y = 12 + MapDiagram.row + center
            return center
        }
        visit(tree, depth: 0, budget: options.expandedView ? itemLimit - 2 : rows - 1, diagram: &diagram)
        if let rootIndex = diagram.items.firstIndex(where: { $0.id == tree.id }) {
            diagram.items[rootIndex].y = 12 + MapDiagram.row
        }
        diagram.finish()
        return diagram
    }
}
