import Foundation

/// Semantic groups feed the bounded map template. File hierarchy is retained in
/// expandable representatives; individual context files never fan out to agents.
public enum WorkspaceMapProjection {
    public static func diagram(snapshot: MapSnapshot, options: WorkspaceMapOptions, now: Date = Date(), limit: Int = 180) -> MapDiagram {
        var snapshot = snapshot
        let legacyTerminals = Set(snapshot.nodes.filter { $0.kind == .resource && $0.evidence == "Saved runtime identity" }.map(\.id))
        snapshot.nodes.removeAll { legacyTerminals.contains($0.id) }
        snapshot.relations.removeAll { legacyTerminals.contains($0.from) || legacyTerminals.contains($0.to) }
        guard let queue = snapshot.nodes.first(where: { $0.kind == .queue }) else { return .init(limit: limit) }
        let index = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let children = Dictionary(grouping: snapshot.nodes, by: { $0.parentID ?? "" })
        func matches(_ node: MapNode) -> Bool {
            (options.search.isEmpty || [node.label, node.path ?? "", node.summary].joined(separator: " ").localizedCaseInsensitiveContains(options.search)) &&
                (!options.changesOnly || node.gitStatus != nil)
        }
        func source(_ node: MapNode, role: String, visited: Set<String> = []) -> MapTree {
            guard !visited.contains(node.id), visited.count < 30 else { return MapTree(node, role: role) }
            let descendants = (children[node.id] ?? []).filter { [.section, .link].contains($0.kind) }
            return MapTree(node, role: role, children: descendants.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
                .map { source($0, role: "Source", visited: visited.union([node.id])) }, startsCollapsed: node.kind != .section)
        }
        func group(_ id: String, _ title: String, path: String?, role: String, contents: [MapTree], collapsed: Bool = false) -> MapTree {
            MapTree(MapNode(id: id, parentID: nil, kind: .folder, label: title, path: path,
                summary: "\(contents.count) items", evidence: "Presentation group"), role: role, children: contents, startsCollapsed: collapsed)
        }
        func fileForest(_ orderedIDs: [String], role: String, shallow: Bool) -> [MapTree] {
            var groups: [String: [MapNode]] = [:], order: [String] = [], direct: [String: MapNode] = [:]
            for id in orderedIDs {
                guard let node = index[id], matches(node) else { continue }
                // Physical folders represent files without reproducing every quiet
                // ancestor directory. The full path is printed on the root card.
                let parent = node.parentID.flatMap { index[$0] }
                let key = parent?.kind == .folder ? parent!.id : node.id
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(node)
                if parent?.kind != .folder { direct[key] = node }
            }
            return order.map { id in
                if let node = direct[id] { return source(node, role: role) }
                let parent = index[id]!
                return MapTree(parent, role: role, children: (groups[id] ?? []).map { source($0, role: role) }, startsCollapsed: shallow)
            }
        }
        var context = snapshot.nodes.first { $0.kind == .context }
            ?? MapNode(id: "context-workspace", parentID: "queue", kind: .context, label: "Context workspace", evidence: "Task")
        context.label = snapshot.taskID + " Context workspace"
        let slots = snapshot.nodes.filter { ["Central plan", "Task context and evidence links", "Task map"].contains($0.label) }
            .sorted { a, b in
                let labels = ["Central plan", "Task context and evidence links", "Task map"]
                return labels.firstIndex(of: a.label)! < labels.firstIndex(of: b.label)!
            }
        var root = MapTree(context, role: "Task workspace"); root.previews = slots
        let agents = snapshot.nodes.filter { $0.kind == .agent }
        let focused = options.agentID.flatMap { index[$0] }
        var selectedRelations: [String: [MapRelation]] = [:]
        for agent in agents { selectedRelations[agent.id] = MapAgentFocus.relations(agent: agent, snapshot: snapshot, options: options, now: now) }

        func agentTree(_ agent: MapNode, visited: Set<String> = []) -> MapTree {
            guard !visited.contains(agent.id), visited.count < 20 else { return MapTree(agent, role: "Agent") }
            let edges = selectedRelations[agent.id] ?? []
            let outputs = edges.filter { $0.kind == .output }.map(\.to)
            let outputBranches = fileForest(outputs, role: options.retrospective ? "Changed file" : "Output",
                                      shallow: options.mode == .typical && !options.expandedView)
            var branches: [MapTree] = []
            let subagents = agents.filter { $0.parentAgentID == agent.id }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
            for child in subagents {
                var branch = agentTree(child, visited: visited.union([agent.id]))
                let inputs = (selectedRelations[child.id] ?? []).filter { $0.kind == .input && !$0.evidence.hasPrefix("Provided") }.map(\.from)
                if !inputs.isEmpty { branch.children.insert(group("inputs:" + child.id, "Working context", path: child.path, role: "Input", contents: fileForest(inputs, role: "Input", shallow: false)), at: 0) }
                branches.append(branch)
            }
            branches += outputBranches
            return MapTree(agent, role: agent.parentAgentID == nil ? "Agent" : "Subagent instance", children: branches)
        }
        if options.mode == .context {
            let inputs = Set(snapshot.relations.filter { $0.kind == .input }.map(\.from))
            let sources = snapshot.nodes.filter { (inputs.contains($0.id) || $0.kind == .document) && matches($0) && !slots.contains($0) }
                .sorted { ($0.label, $0.id) < ($1.label, $1.id) }
            root.children = fileForest(sources.map(\.id), role: "Context", shallow: false)
            // Headings from the plan represent their links; the plan itself is
            // already a slot in the workspace group.
            for plan in slots where plan.label == "Central plan" {
                root.children += (children[plan.id] ?? []).filter { $0.kind == .section }.map { source($0, role: "Context") }
            }
        } else {
            let eligible = agents.filter { agent in
                (options.mode != .agent || agent.id == focused?.id) &&
                (options.mode == .agent || agent.parentAgentID == nil || index[agent.parentAgentID ?? ""] == nil) &&
                (!options.attentionOnly || agent.needsAttention(at: now)) &&
                (matches(agent) || (selectedRelations[agent.id] ?? []).contains { index[$0.from == agent.id ? $0.to : $0.from].map(matches) == true })
            }
            if options.mode == .agent, let focused {
                let inputs = (selectedRelations[focused.id] ?? []).filter { $0.kind == .input && !$0.evidence.hasPrefix("Provided") }.map(\.from)
                if !inputs.isEmpty { root.children.append(group("inputs:" + focused.id, "Working context", path: focused.path, role: "Input", contents: fileForest(inputs, role: "Input", shallow: false))) }
            }
            var workspaceIDs = Set(eligible.map { $0.parentID ?? "queue" })
            if options.mode == .typical && options.search.isEmpty && !options.attentionOnly && !options.changesOnly {
                workspaceIDs.formUnion(snapshot.nodes.filter { $0.kind == .workspace }.map(\.id))
            }
            for workspaceID in workspaceIDs.sorted(by: { (index[$0]?.path ?? $0) < (index[$1]?.path ?? $1) }) {
                let workspace = index[workspaceID].flatMap { $0.kind == .workspace ? $0 : nil }
                    ?? MapNode(id: "unassigned", parentID: "queue", kind: .workspace, label: "Unassigned workspace", evidence: "Registered location unavailable")
                var tree = MapTree(workspace, role: "Worktree · repo context", children: eligible.filter { ($0.parentID ?? "queue") == workspaceID }
                    .sorted { ($0.label, $0.id) < ($1.label, $1.id) }.map { agentTree($0) })
                let repoFiles = snapshot.nodes.filter { node in
                    node.path.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path == workspace.path } == true && [.file, .document].contains(node.kind) &&
                    (["AGENTS.md", "README.md", "repo_guide.md"].contains(node.label) || snapshot.relations.contains { $0.to != node.id && $0.from == node.id && $0.kind == .input })
                }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
                tree.previews = ["AGENTS.md", "README.md"].compactMap { name in repoFiles.first { $0.label == name } }
                let others = repoFiles.filter { !tree.previews.contains($0) }
                if !others.isEmpty {
                    tree.children.insert(group("repo-context:" + workspace.id, "More repo context", path: workspace.path,
                        role: "Context", contents: others.map { source($0, role: "Context") }, collapsed: true), at: 0)
                }
                if (options.expandedView || options.showOtherFiles || options.changesOnly || !options.search.isEmpty),
                   let rootPath = workspace.path {
                    let related = Set(snapshot.relations.flatMap { [$0.from, $0.to] })
                    let files = snapshot.nodes.filter { node in
                        [.file, .document].contains(node.kind) && matches(node) &&
                        node.path.map { WorkspaceCollector.contains($0, in: rootPath) } == true &&
                        !related.contains(node.id) && !tree.previews.contains(node)
                    }
                    let contents = fileForest(files.map(\.id), role: "Repository file", shallow: !options.expandedView)
                    if !contents.isEmpty {
                        tree.children.insert(group("browse:" + workspace.id, "Repository files", path: rootPath,
                            role: "Files", contents: contents, collapsed: true), at: 0)
                    }
                }
                let groupAgentIDs = Set(agents.filter { candidate in
                    var current: MapNode? = candidate, seen = Set<String>()
                    while let currentAgent = current, seen.insert(currentAgent.id).inserted {
                        if eligible.contains(where: { $0.id == currentAgent.id && ($0.parentID ?? "queue") == workspaceID }) { return true }
                        current = currentAgent.parentAgentID.flatMap { index[$0] }
                    }
                    return false
                }.map(\.id))
                let execution = groupAgentIDs.union(snapshot.relations.filter { groupAgentIDs.contains($0.from) && $0.kind == .output }.map(\.to))
                tree.children += snapshot.nodes.filter { resource in
                    resource.kind == .resource && resource.parentID == workspaceID &&
                    (options.mode == .typical || snapshot.relations.contains { ($0.from == resource.id && execution.contains($0.to)) || ($0.to == resource.id && execution.contains($0.from)) })
                }.sorted { $0.id < $1.id }.map { MapTree($0, role: "Instance") }
                root.children.append(tree)
            }
            root.children += snapshot.nodes.filter { resource in resource.kind == .resource && resource.parentID == "queue" && (options.mode == .typical || snapshot.relations.contains { relation in (relation.from == resource.id && relation.to == options.agentID) || (relation.to == resource.id && relation.from == options.agentID) }) }
                .sorted { $0.id < $1.id }.map { MapTree($0, role: "Instance") }
        }
        var diagram = MapCompactLayout.diagram(queue: queue, root: root, options: options, limit: limit)
        // Workspace outlines show the physical boundary without another set of
        // context-file edges. Only the group is connected to each agent.
        let workspaceItems = diagram.items.filter { $0.node.kind == .workspace }.sorted { $0.y < $1.y }
        for (position, item) in workspaceItems.enumerated() {
            let rootPath = item.node.path
            let members = diagram.items.filter { candidate in
                candidate.id == item.id || (candidate.node.parentID == item.node.id && candidate.node.kind == .agent) || (candidate.x > item.x && rootPath.map { root in candidate.node.path.map { WorkspaceCollector.contains($0, in: root) } ?? false } == true)
            }
            let bottom = members.map { $0.y + MapDiagram.nodeHeight }.max() ?? item.y
            let top = members.map(\.y).min() ?? item.y
            let right = members.map { $0.x + MapDiagram.nodeWidth }.max() ?? item.x
            let count = workspaceItems.count
            let prefix = count == 1 ? "Worktree" : "Worktree \(position + 1) of \(count)"
            diagram.containers.append(.init(id: item.node.id, label: "\(prefix): \(item.node.label)",
                x: item.x - 7, y: top - 25, width: right - item.x + 14, height: bottom - top + 32))
        }
        // Secondary feedback/handoff edges are drawn only between visible cards
        // and only while respecting the four-connection cap.
        for relation in snapshot.relations where [.feedback, .handoff, .dependency].contains(relation.kind) {
            guard let from = diagram.items.first(where: { $0.node.id == relation.from }), let to = diagram.items.first(where: { $0.node.id == relation.to }),
                  diagram.edges.filter({ $0.from == from.id }).count < 4 else { continue }
            diagram.connect(from.id, to.id, kind: relation.kind.rawValue)
        }
        diagram.finish(); MapEdgeRouter.route(&diagram); return diagram
    }
}
