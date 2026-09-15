import Foundation

/// Task-specific selection policy over the reusable MapDiagram template. Future
/// project views can combine snapshots and supply another projection unchanged.
public enum WorkspaceMapProjection {
    private struct Tree {
        var nodes: [MapNode]
        var roots: [String]
        var hidden: [String: Int]
        var represented: [String: String]
    }
    private static func tree(targets: Set<String>, snapshot: MapSnapshot, options: WorkspaceMapOptions,
                             shallow: Bool = false, includeSections: Bool = true) -> Tree {
        let index = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        var included = targets
        if includeSections {
            for node in snapshot.nodes where node.kind == .section && targets.contains(node.parentID ?? "") {
                included.insert(node.id)
                if options.expanded.contains(node.id) {
                    included.formUnion(snapshot.nodes.filter { $0.parentID == node.id }.map(\.id))
                }
            }
        }
        for id in Array(included) {
            var parent = index[id]?.parentID, seen = Set<String>()
            while let p = parent, seen.insert(p).inserted, let node = index[p], ![.queue, .workspace, .context].contains(node.kind) {
                included.insert(p); parent = node.parentID
            }
        }
        included = included.filter { index[$0].map { ![.queue, .workspace, .context, .agent].contains($0.kind) } == true }
        let children = Dictionary(grouping: included.compactMap { index[$0] }, by: { $0.parentID ?? "" })
        var hidden: [String: Int] = [:]
        for (parent, siblings) in children where index[parent]?.kind == .folder {
            let files = siblings.filter { [.file, .document].contains($0.kind) }
            guard !files.isEmpty else { continue }
            if !options.expanded.contains(parent) && (shallow || files.count > 5) {
                hidden[parent] = files.count
                for file in files {
                    included.remove(file.id)
                    for child in snapshot.nodes where child.parentID == file.id {
                        included.remove(child.id)
                        included.subtract(snapshot.nodes.filter { $0.parentID == child.id }.map(\.id))
                    }
                }
            } else if files.count > 5 || shallow { hidden[parent] = 0 }
        }
        for node in snapshot.nodes where node.kind == .section && included.contains(node.id) {
            let count = snapshot.nodes.filter { $0.parentID == node.id }.count
            if count > 0 { hidden[node.id] = options.expanded.contains(node.id) ? 0 : count }
        }
        var represented: [String: String] = [:]
        for id in targets {
            var current: String? = id, seen = Set<String>()
            while let value = current, seen.insert(value).inserted {
                if included.contains(value) { represented[id] = value; break }
                current = index[value]?.parentID
            }
        }
        var nodes = included.compactMap { index[$0] }
        // Compress unbranched directory paths into a single breadcrumb card.
        // Preserve the deepest folder's identity, including its expansion control.
        var changed = true
        while changed {
            changed = false
            for folder in nodes where folder.kind == .folder && hidden[folder.id] == nil {
                let children = nodes.filter { $0.parentID == folder.id }
                guard children.count == 1, children[0].kind == .folder,
                      let offset = nodes.firstIndex(where: { $0.id == children[0].id }) else { continue }
                nodes[offset].label = folder.label + "/" + nodes[offset].label
                nodes[offset].parentID = folder.parentID
                for (key, value) in represented where value == folder.id { represented[key] = children[0].id }
                nodes.removeAll { $0.id == folder.id }; changed = true; break
            }
        }
        let ids = Set(nodes.map(\.id))
        return Tree(nodes: nodes, roots: nodes.filter { !ids.contains($0.parentID ?? "") }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }.map(\.id),
                    hidden: hidden, represented: represented)
    }

    public static func diagram(snapshot: MapSnapshot, options: WorkspaceMapOptions, now: Date = Date(), limit: Int = 180) -> MapDiagram {
        var diagram = MapDiagram(limit: limit)
        guard let queue = snapshot.nodes.first(where: { $0.kind == .queue }) else { return diagram }
        let index = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        let context = snapshot.nodes.first { $0.kind == .context }
        let contextID = context?.id ?? "context-workspace"
        diagram.add(queue, x: 16, y: 12, role: "Task")
        let central = snapshot.nodes.first { $0.label == "Central plan" }
        let evidence = snapshot.nodes.first { $0.label == "Task context and evidence links" }
        let taskMap = snapshot.nodes.first { $0.label == "Task map" }
        let slots = [central, evidence, taskMap]
        for (i, slot) in slots.enumerated() {
            let node = slot ?? MapNode(id: "slot:\(i)", parentID: contextID, kind: .document,
                label: ["Central plan", "Task context and evidence links", "Task map"][i], summary: "Not yet recorded", evidence: "Task context")
            diagram.add(node, x: 16, y: 120 + Double(i) * MapDiagram.row, role: "Context workspace")
        }
        diagram.containers.append(.init(id: contextID, label: "\(snapshot.taskID) Context workspace", x: 4, y: 88, width: 200, height: 250))
        let workspaceTarget = evidence?.id ?? "slot:1"
        let activeRelations = snapshot.relations.filter { relation in
            guard !options.includeOlderScope, relation.kind == .input || relation.kind == .output,
                  relation.evidence.hasPrefix("Declared"), let date = relation.observedAt else { return true }
            return now.timeIntervalSince(date) <= options.scopeLifetime && now.timeIntervalSince(date) >= -60
        }
        func matches(_ node: MapNode) -> Bool {
            (options.search.isEmpty || [node.label, node.path ?? "", node.summary].joined(separator: " ").localizedCaseInsensitiveContains(options.search)) &&
            (!options.changesOnly || node.gitStatus != nil)
        }
        if options.mode == .context {
            let allInputs = Set(activeRelations.filter { $0.kind == .input }.map(\.from))
            var inputs = Set(snapshot.nodes.filter { (allInputs.contains($0.id) || $0.kind == .document) && matches($0) }.map(\.id))
            inputs.subtract(slots.compactMap { $0?.id })
            let projected = tree(targets: inputs.union(central.map { [$0.id] } ?? []), snapshot: snapshot, options: options)
            // The central plan already has a slot. Its heading cards are source
            // aggregators here, so links funnel to evidence rather than the plan.
            let nodes = projected.nodes.filter { !slots.compactMap({ $0?.id }).contains($0.id) }
            let ids = Set(nodes.map(\.id)), roots = nodes.filter { !ids.contains($0.parentID ?? "") }.map(\.id).sorted()
            _ = diagram.forest(nodes: nodes, roots: roots, prefix: "context:", x: 260, y: 28, role: "Source",
                hidden: projected.hidden)
            // Source nodes on the right feed their category on the left.
            for i in diagram.edges.indices where diagram.edges[i].kind == "hierarchy" {
                let from = diagram.edges[i].from; diagram.edges[i].from = diagram.edges[i].to; diagram.edges[i].to = from
                diagram.edges[i].kind = "context"
            }
            for root in roots { diagram.connect("context:" + root, workspaceTarget, kind: "context") }
            diagram.finish(); return diagram
        }
        let allAgents = snapshot.nodes.filter { $0.kind == .agent }
        let agents = allAgents.filter { agent in
            (options.mode != .agent || agent.id == options.agentID) &&
            (!options.attentionOnly || agent.needsAttention(at: now)) &&
            (matches(agent) || activeRelations.contains { edge in
                (edge.from == agent.id && index[edge.to].map(matches) == true) || (edge.to == agent.id && index[edge.from].map(matches) == true)
            })
        }
        let visibleAgentIDs = Set(agents.map(\.id))
        let executionIDs = visibleAgentIDs.union(activeRelations.filter { visibleAgentIDs.contains($0.from) && $0.kind == .output }.map(\.to))
        var sharedY = 360.0
        for resource in snapshot.nodes.filter({ node in node.kind == .resource && (node.parentID == "queue" || (options.mode == .agent && !agents.contains { $0.parentID == node.parentID })) }).sorted(by: { $0.id < $1.id }) {
            guard options.mode != .agent || activeRelations.contains(where: {
                ($0.from == resource.id && executionIDs.contains($0.to)) || ($0.to == resource.id && executionIDs.contains($0.from))
            }) else { continue }
            diagram.add(resource, x: 16, y: sharedY, role: "Shared durable instance")
            sharedY += MapDiagram.row
        }
        var groups = Set(agents.map { $0.parentID ?? "queue" })
        if options.mode == .typical && options.search.isEmpty && !options.attentionOnly && !options.changesOnly {
            groups.formUnion(snapshot.nodes.filter { $0.kind == .workspace }.map(\.id))
        }
        var top = 12.0
        for group in groups.sorted(by: { (index[$0]?.path ?? $0) < (index[$1]?.path ?? $1) }) {
            let groupAgents = agents.filter { ($0.parentID ?? "queue") == group }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
            let agentIDs = Set(groupAgents.map(\.id))
            let relations = activeRelations.filter { agentIDs.contains($0.from) || agentIDs.contains($0.to) }
            var inputs = Set(relations.filter { $0.kind == .input && index[$0.from]?.kind != .resource }.map(\.from))
            if options.mode == .typical {
                inputs = inputs.filter { id in
                    guard let path = index[id]?.path, let root = index[group]?.path else { return false }
                    return URL(fileURLWithPath: path).deletingLastPathComponent().path == root
                }
            }
            if let root = index[group]?.path {
                inputs.formUnion(snapshot.nodes.filter {
                    ["AGENTS.md", "README.md", "repo_guide.md"].contains($0.label) &&
                    $0.path.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path == root } == true
                }.map(\.id))
            }
            inputs.subtract(slots.compactMap { $0?.id })
            var x = 260.0
            if options.mode == .agent, let root = index[group]?.path {
                let externalIDs = inputs.filter { index[$0]?.path.map { !WorkspaceCollector.contains($0, in: root) } ?? true }
                inputs.subtract(externalIDs)
                let external = tree(targets: externalIDs, snapshot: snapshot, options: options)
                if !external.nodes.isEmpty {
                    let (_, columns) = diagram.forest(nodes: external.nodes, roots: external.roots, prefix: "external:",
                        x: x, y: top + 30, role: "Task input", hidden: external.hidden)
                    for source in external.roots { diagram.connect("external:" + source, workspaceTarget, kind: "context") }
                    x += Double(columns) * MapDiagram.column + 24
                }
            }
            let left = tree(targets: inputs, snapshot: snapshot, options: options)
            let start = diagram.items.count, y = top + 50
            // Reserve agent cards before packing context; bounded views retain the actors.
            for (i, agent) in groupAgents.enumerated() { diagram.add(agent, x: x, y: y + Double(i) * MapDiagram.row, role: "Agent") }
            let prefix = group + ":input:"
            let (inputHeight, columns) = diagram.forest(nodes: left.nodes, roots: left.roots, prefix: prefix,
                x: x, y: y, role: "Repo context", hidden: left.hidden)
            let groupContainerIndex = diagram.containers.count
            if !left.nodes.isEmpty {
                diagram.containers.append(.init(id: group + ":repo-context", label: options.mode == .typical ? "Repo context" : "Agent context",
                    x: x - 6, y: top + 27, width: Double(columns) * MapDiagram.column - 18, height: inputHeight + 24))
            }
            let agentX = left.nodes.isEmpty ? x : x + Double(columns) * MapDiagram.column
            var nextAgentY = y
            var representations = left.represented.mapValues { prefix + $0 }
            for agent in groupAgents {
                guard let slot = diagram.items.firstIndex(where: { $0.id == agent.id }) else { continue }
                diagram.items[slot].x = agentX; diagram.items[slot].y = nextAgentY
                let outputs = Set(relations.filter { $0.from == agent.id && $0.kind == .output }.map(\.to))
                let projected = tree(targets: outputs, snapshot: snapshot, options: options,
                    shallow: options.mode == .typical && !options.expandedView)
                let outputPrefix = agent.id + ":output:"
                let (height, _) = diagram.forest(nodes: projected.nodes, roots: projected.roots, prefix: outputPrefix,
                    x: agentX + MapDiagram.column, y: nextAgentY, role: "Output", hidden: projected.hidden)
                for (id, representative) in projected.represented {
                    representations[id] = outputPrefix + representative
                }
                // The agent feeds the directory tree once; containment edges
                // reach its leaves without arrows cutting through folder cards.
                for root in projected.roots { diagram.connect(agent.id, outputPrefix + root, kind: "output") }
                for edge in relations where edge.to == agent.id && edge.kind == .input {
                    if let source = left.represented[edge.from] { diagram.connect(prefix + source, agent.id, kind: "input") }
                }
                diagram.connect(workspaceTarget, agent.id, kind: "context")
                nextAgentY += max(MapDiagram.row, height) + 8
            }
            var resourceY = max(y + inputHeight, nextAgentY)
            let executionIDs = agentIDs.union(relations.filter { $0.kind == .output }.map(\.to))
            let resources = snapshot.nodes.filter { node in
                node.kind == .resource && node.parentID != "queue" && node.parentID == group &&
                (options.mode != .agent || activeRelations.contains { ($0.from == node.id && executionIDs.contains($0.to)) || ($0.to == node.id && executionIDs.contains($0.from)) })
            }
            for resource in resources {
                let key = group + ":resource:" + resource.id
                diagram.add(resource, id: key, x: agentX + MapDiagram.column, y: resourceY, role: "Durable instance")
                representations[resource.id] = key; resourceY += MapDiagram.row
            }
            for edge in activeRelations where ![.input, .output].contains(edge.kind) || index[edge.from]?.kind == .resource || index[edge.to]?.kind == .resource {
                let from = representations[edge.from] ?? (agentIDs.contains(edge.from) ? edge.from : "")
                let to = representations[edge.to] ?? (agentIDs.contains(edge.to) ? edge.to : "")
                if !from.isEmpty && !to.isEmpty { diagram.connect(from, to, kind: edge.kind.rawValue) }
            }
            let placed = Array(diagram.items.dropFirst(start))
            let bottom = max(top + 100, placed.map { $0.y + MapDiagram.nodeHeight + 18 }.max() ?? top + 100)
            let right = max(x + MapDiagram.nodeWidth, placed.map { $0.x + MapDiagram.nodeWidth }.max() ?? x)
            diagram.containers.insert(.init(id: group, label: index[group].flatMap { $0.kind == .workspace ? "Worktree / repo: " + $0.label : nil } ?? "Unassigned workspace",
                x: x - 12, y: top, width: right - x + 24, height: bottom - top), at: groupContainerIndex)
            top = bottom + 16
        }
        if options.showOtherFiles || options.changesOnly || !options.search.isEmpty {
            let visible = Set(diagram.items.map { $0.node.id })
            let files = Set(snapshot.nodes.filter { [.file, .document].contains($0.kind) && !visible.contains($0.id) && matches($0) }.map(\.id))
            let projected = tree(targets: files, snapshot: snapshot, options: options)
            _ = diagram.forest(nodes: projected.nodes, roots: projected.roots, prefix: "browse:", x: 260, y: top + 28,
                role: "Other files", hidden: projected.hidden)
        }
        // Preserve cross-worktree handoffs and feedback when both endpoints are
        // visible. Projection never invents missing endpoint ownership.
        for edge in activeRelations where ![.input, .output].contains(edge.kind) || index[edge.from]?.kind == .resource || index[edge.to]?.kind == .resource {
            if let from = diagram.items.first(where: { $0.node.id == edge.from }),
               let to = diagram.items.first(where: { $0.node.id == edge.to }) {
                diagram.connect(from.id, to.id, kind: edge.kind.rawValue)
            }
        }
        diagram.finish(); return diagram
    }
}
