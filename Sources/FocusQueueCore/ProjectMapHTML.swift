import Foundation

/// Renders a `ProjectMap` as a textbook-style tree on one self-contained,
/// script-free, dark HTML page.
///
/// - Rank 0 is the project, rank 1 its phases (plan sections), and ranks 2+
///   its tasks by dependency depth inside their phase. Each task hangs under
///   its deepest in-phase prerequisite, so a child is always one rank below its
///   parent. Every parent is centered over its children; edges are straight.
/// - Dependencies the tree cannot show (a second prerequisite, or one in
///   another phase) are dashed lines, hidden until a card is hovered or the
///   "Show all dependencies" toggle is on.
///
/// Focus Queue's document viewer runs pages with scripts off, so layout and
/// edges are computed here, hover uses CSS `:has`, filters are CSS checkboxes,
/// and agent lists are native `<details>` dropdowns.
public enum ProjectMapHTML {
    static let nodeWidth = 176.0, nodeHeight = 74.0
    static let phaseWidth = 200.0, phaseHeight = 56.0
    static let rootWidth = 240.0, rootHeight = 64.0
    // Slightly tight: 10 px between cards, 58 px between ranks.
    static let slotWidth = 186.0, rankHeight = 132.0
    static let left = 120.0, top = 46.0, margin = 40.0

    enum Kind { case root, phase(isTrack: Bool), item(ProjectMap.Node, index: Int) }

    final class TreeNode {
        let id: String
        let kind: Kind
        var children: [TreeNode] = []
        var rank = 0
        var slots = 1.0
        var centerX = 0.0
        init(id: String, kind: Kind) { self.id = id; self.kind = kind }

        var size: (width: Double, height: Double) {
            switch kind {
            case .root: (ProjectMapHTML.rootWidth, ProjectMapHTML.rootHeight)
            case .phase: (ProjectMapHTML.phaseWidth, ProjectMapHTML.phaseHeight)
            case .item: (ProjectMapHTML.nodeWidth, ProjectMapHTML.nodeHeight)
            }
        }
        var y: Double { ProjectMapHTML.top + Double(rank) * ProjectMapHTML.rankHeight }
        var x: Double { centerX - size.width / 2 }
    }

    public static func render(_ map: ProjectMap) -> String {
        let indexOf = Dictionary(map.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let root = TreeNode(id: "root", kind: .root)
        var byID: [String: TreeNode] = [:]
        var treeEdges = Set<String>()

        for (laneIndex, lane) in map.lanes.enumerated() {
            let nodes = map.nodes.filter { $0.lane == laneIndex }
            // An empty gating section is a phase nobody has planned yet; it stays
            // visible (and counts toward progress at an estimated size).
            guard !nodes.isEmpty || !lane.isTrack else { continue }
            let phase = TreeNode(id: "lane\(laneIndex)", kind: .phase(isTrack: lane.isTrack))
            phase.rank = 1
            root.children.append(phase)
            byID[phase.id] = phase

            let ids = Set(nodes.map(\.id))
            var preds: [String: [String]] = [:]
            for edge in map.edges where ids.contains(edge.from) && ids.contains(edge.to) {
                preds[edge.to, default: []].append(edge.from)
            }
            var depth: [String: Int] = [:]
            var visiting = Set<String>()
            func depthOf(_ id: String) -> Int {
                if let known = depth[id] { return known }
                guard visiting.insert(id).inserted else { return 0 }
                let value = (preds[id] ?? []).map { depthOf($0) + 1 }.max() ?? 0
                visiting.remove(id)
                depth[id] = value
                return value
            }
            for node in nodes { byID[node.id] = TreeNode(id: node.id, kind: .item(node, index: indexOf[node.id] ?? 0)) }
            for node in nodes {
                let tree = byID[node.id]!
                let own = depthOf(node.id)
                tree.rank = 2 + own
                // The parent is the prerequisite exactly one level up, earliest in plan order.
                let parent = (preds[node.id] ?? [])
                    .filter { depthOf($0) == own - 1 }
                    .min { (indexOf[$0] ?? 0) < (indexOf[$1] ?? 0) }
                if let parent, let parentNode = byID[parent] {
                    parentNode.children.append(tree)
                    treeEdges.insert(parent + "\u{1}" + node.id)
                } else {
                    phase.children.append(tree)
                }
            }
        }
        for node in byID.values {
            node.children.sort { order($0, indexOf) < order($1, indexOf) }
        }

        // Tidy layout: a node spans its children's slots and sits centered over them.
        func measure(_ node: TreeNode) -> Double {
            node.slots = node.children.isEmpty ? 1 : node.children.map(measure).reduce(0, +)
            return node.slots
        }
        func place(_ node: TreeNode, start: Double) {
            node.centerX = left + (start + node.slots / 2) * slotWidth
            var cursor = start
            for child in node.children { place(child, start: cursor); cursor += child.slots }
        }
        _ = measure(root)
        place(root, start: 0)
        var all: [TreeNode] = []
        func collect(_ node: TreeNode) { all.append(node); node.children.forEach(collect) }
        collect(root)
        let maxRank = all.map(\.rank).max() ?? 0
        let width = left + root.slots * slotWidth + margin
        let height = top + Double(maxRank) * rankHeight + nodeHeight + margin + 30

        // Rank bands with labels, alternating so ranks read at a glance.
        var bands: [String] = []
        for rank in 0...maxRank {
            let y = top + Double(rank) * rankHeight - 34
            let name = rank == 0 ? "project" : rank == 1 ? "phases" : rank == 2 ? "first tasks" : "depends on rank \(rank - 1)"
            bands.append(#"<div class="band\#(rank % 2 == 0 ? " even" : "")" data-rank="\#(rank)" style="top:\#(f(y))px;height:\#(f(rankHeight))px;width:\#(f(width))px"><div class="ranklabel" title="\#(name)">R\#(rank)</div></div>"#)
        }

        // Edges: straight lines from a parent's bottom center to a child's top center.
        var lines: [String] = []
        var neighbours: [Int: Set<Int>] = [:]
        func segment(_ a: TreeNode, _ b: TreeNode) -> (Double, Double, Double, Double) {
            if b.rank > a.rank { return (a.centerX, a.y + a.size.height, b.centerX, b.y - 3) }
            if b.rank < a.rank { return (a.centerX, a.y, b.centerX, b.y + b.size.height + 3) }
            let forward = b.centerX > a.centerX
            return (forward ? a.x + a.size.width : a.x, a.y + a.size.height / 2,
                    forward ? b.x - 3 : b.x + b.size.width + 3, b.y + b.size.height / 2)
        }
        for node in all {
            for child in node.children {
                if case .item = node.kind { continue }   // dependency edges come below
                let (x1, y1, x2, y2) = segment(node, child)
                lines.append(#"<line class="struct\#(child.isGhost ? " gh" : "")" data-from="\#(escape(node.id))" data-to="\#(escape(child.id))" x1="\#(f(x1))" y1="\#(f(y1))" x2="\#(f(x2))" y2="\#(f(y2))"/>"#)
            }
        }
        for edge in map.edges {
            guard let a = byID[edge.from], let b = byID[edge.to],
                  case .item(let from, let i) = a.kind, case .item(let to, let j) = b.kind else { continue }
            neighbours[i, default: []].insert(j)
            neighbours[j, default: []].insert(i)
            let isTree = treeEdges.contains(edge.from + "\u{1}" + edge.to)
            var classes = ["dep", isTree ? "tree" : "extra", "e\(i)", "e\(j)"]
            if from.kind == .ghost || to.kind == .ghost { classes += ["gh", "dash"] }
            if isFinished(from) || isFinished(to) { classes.append("fin") }
            let (x1, y1, x2, y2) = segment(a, b)
            lines.append(#"<line class="\#(classes.joined(separator: " "))" data-from="\#(escape(edge.from))" data-to="\#(escape(edge.to))" x1="\#(f(x1))" y1="\#(f(y1))" x2="\#(f(x2))" y2="\#(f(y2))"/>"#)
        }

        let progress = Progress(map)
        var parentOf: [String: String] = [:]
        for node in all { for child in node.children { parentOf[child.id] = node.id } }
        var hoverCSS: [String] = []
        var cards: [String] = []
        for node in all {
            switch node.kind {
            case .root:
                cards.append(#"<div class="root" id="root" data-node="root" data-kind="root" data-rank="0" style="left:\#(f(node.x))px;top:\#(f(node.y))px" title="Click to expand or collapse every phase"><b>\#(escape(map.projectName))</b><span>\#(percent(progress.project)) complete</span>\#(bar(progress.project))</div>"#)
            case .phase(let isTrack):
                let index = Int(node.id.dropFirst(4)) ?? 0
                let title = map.lanes.indices.contains(index) ? map.lanes[index].title : node.id
                let count = map.nodes.filter { $0.lane == index }.count
                let share = progress.lanes[index]
                let detail = count == 0
                    ? "not planned yet · ≈\(Int(progress.estimatedSize.rounded())) tasks"
                    : "\(count) node\(count == 1 ? "" : "s") · \(percent(share ?? 0))\(isTrack ? " · not gating" : "")"
                cards.append(#"<div class="phase\#(isTrack ? " track" : "")\#(count == 0 ? " unplanned" : "")" data-node="\#(node.id)" data-kind="phase" data-parent="root" data-rank="1" style="left:\#(f(node.x))px;top:\#(f(node.y))px" title="\#(escape(title)) — click to expand or collapse"><b>\#(escape(title))</b><span>\#(escape(detail))<span class="live"></span></span>\#(bar(share ?? 0))</div>"#)
            case .item(let item, let i):
                hoverCSS.append("#map:has(#n\(i):hover) .node:not(.k\(i)){opacity:.28}")
                hoverCSS.append("#map:has(#n\(i):hover) .e\(i){stroke:var(--edge-hi);stroke-width:2.2;opacity:1;visibility:visible;marker-end:url(#ahi)}")
                cards.append(card(item, index: i, neighbours: neighbours[i] ?? [], x: node.x, y: node.y,
                                  parent: parentOf[node.id] ?? "root", lane: "lane\(item.lane)", rank: node.rank))
            }
        }

        let layoutJSON = #"{"slot":\#(slotWidth),"rank":\#(rankHeight),"sub":\#(nodeHeight + 22),"top":\#(top),"left":\#(left),"margin":\#(margin),"sizes":{"root":[\#(rootWidth),\#(rootHeight)],"phase":[\#(phaseWidth),\#(phaseHeight)],"item":[\#(nodeWidth),\#(nodeHeight)]}}"#
        let tasks = map.nodes.filter { $0.kind == .task }
        let open = tasks.filter { !isFinished($0) }.count
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let summary = "\(percent(progress.project)) complete · \(tasks.count) tasks (\(open) open) · \(map.nodes.count - tasks.count) ghost tasks · "
            + (map.planFile.map { "plan: \($0)" } ?? "no development plan file")
            + " · generated \(stamp.string(from: map.generatedAt))"

        return template
            .replacingOccurrences(of: "{{TITLE}}", with: escape("\(map.projectName) project map"))
            .replacingOccurrences(of: "{{HEADING}}", with: escape("\(map.projectName) · project map"))
            .replacingOccurrences(of: "{{SUMMARY}}", with: escape(summary))
            .replacingOccurrences(of: "{{HOVER}}", with: hoverCSS.joined(separator: "\n"))
            .replacingOccurrences(of: "{{WIDTH}}", with: f(width))
            .replacingOccurrences(of: "{{HEIGHT}}", with: f(height))
            .replacingOccurrences(of: "{{BANDS}}", with: bands.joined(separator: "\n"))
            .replacingOccurrences(of: "{{EDGES}}", with: lines.joined(separator: "\n"))
            .replacingOccurrences(of: "{{CARDS}}", with: cards.joined(separator: "\n"))
            .replacingOccurrences(of: "{{LAYOUT}}", with: escape(layoutJSON))
            .replacingOccurrences(of: "{{SCRIPT}}", with: ProjectMapScript.source)
            .replacingOccurrences(of: "{{ICONS}}", with: iconDefinitions)
    }

    static func order(_ node: TreeNode, _ indexOf: [String: Int]) -> Int {
        if case .item(_, let index) = node.kind { return index }
        return Int(node.id.dropFirst(4)) ?? 0
    }

    static func card(_ node: ProjectMap.Node, index: Int, neighbours: Set<Int>, x: Double, y: Double,
                     parent: String = "root", lane: String = "", rank: Int = 2) -> String {
        let group = statusGroup(node.status)
        var classes = ["node", node.kind == .ghost ? "ghost" : "s-\(group)", "k\(index)"]
        classes += neighbours.sorted().map { "k\($0)" }
        if isFinished(node) { classes.append("fin") }
        if node.kind == .ghost { classes.append("gh") }
        let label = node.kind == .ghost
            ? (node.leaves.isEmpty ? "module" : "leaf " + node.leaves.joined(separator: ", "))
            : node.id
        let pill = node.status == "missing" ? "no task" : node.status.replacingOccurrences(of: "-", with: " ")
        let title = node.kind == .ghost
            ? node.title.replacingOccurrences(of: #"^\S+\.\s"#, with: "", options: .regularExpression)
            : node.title
        var details: [String] = []
        var facts: [String] = []
        if node.kind == .task, !node.leaves.isEmpty { facts.append("Plan " + node.leaves.joined(separator: ", ")) }
        if let phase = node.phase { facts.append(phase) }
        if !facts.isEmpty { details.append(#"<div class="meta">\#(escape(facts.joined(separator: " · ")))</div>"#) }
        if let gate = node.gate { details.append(#"<div class="meta">Gate: \#(escape(gate))</div>"#) }
        if let reason = node.reason { details.append(#"<div class="meta">\#(escape(reason))</div>"#) }
        let summary: String
        if node.kind == .task {
            let count = node.agents.count
            summary = count == 0 ? "No agents" : "\(count) agent\(count == 1 ? "" : "s")"
            if count == 0 { details.append(#"<div class="meta">No agent has worked on this task yet.</div>"#) }
            for agent in node.agents {
                var row = #"<div class="agent"><div><b>\#(escape(agent.title))</b> · \#(escape(agent.provider)) · \#(escape(agent.status))</div>"#
                if let attention = agent.attention { row += #"<div class="meta">\#(escape(attention))</div>"# }
                if !agent.summary.isEmpty { row += #"<div class="meta clamp">\#(escape(agent.summary))</div>"# }
                details.append(row + "</div>")
            }
        } else {
            summary = "Planned work"
        }
        let tooltip = escape(([title] + (node.gate.map { ["Gate: \($0)"] } ?? [])).joined(separator: "\n"))
        let task = node.kind == .task ? #" data-task="\#(escape(node.id))""# : ""
        // One mark per unfinished agent, colored by state, in a strip under the
        // card that wraps downward; the app keeps it live.
        let live = node.agents.compactMap { agent -> String? in
            guard let state = agent.state else { return nil }
            return ##"<i class="pv \##(state.rawValue)" title="\##(escape(agent.title)) (\##(escape(agent.provider))) · \##(state.label)"><svg viewBox="0 0 24 24"><use href="#pv-\##(escape(agent.provider))"/></svg></i>"##
        }.joined()
        let more = node.kind == .task
            ? #"<button class="more" type="button" title="Task actions" aria-label="Task actions for \#(escape(node.id))">⋯</button>"#
            : ""
        return #"<div class="\#(classes.joined(separator: " "))" id="n\#(index)" data-id="\#(escape(node.id))" data-node="\#(escape(node.id))" data-kind="item" data-parent="\#(escape(parent))" data-lane="\#(lane)" data-rank="\#(rank)"\#(task) style="left:\#(f(x))px;top:\#(f(y))px" title="\#(tooltip)"><div class="top"><span class="id">\#(escape(label))</span>\#(more)<span class="pill \#(node.kind == .ghost ? "ghost" : "s-\(group)")">\#(escape(pill))</span></div><div class="title">\#(escape(title))</div><details><summary>\#(summary)<span class="act"></span></summary><div class="panel">\#(details.joined())</div></details>\#(node.kind == .task ? #"<div class="agents">\#(live)</div>"# : "")</div>"#
    }

    /// Completion credit per status: done > review > in progress > blocked >
    /// backlog. Ghosts count as not started; cancelled work counts not at all.
    /// Provider marks and activity glyphs, referenced by `<use href="#…">`.
    static var iconDefinitions: String {
        let providers = AgentProvider.allCases.map {
            #"<symbol id="pv-\#($0.rawValue)" viewBox="0 0 24 24"><path fill="currentColor" d="\#(ProviderMark.path(for: $0).replacingOccurrences(of: "\n", with: " "))"/></symbol>"#
        }
        // 16-unit stroke glyphs: a page, a pencil, a prompt, a check, a lens,
        // a fork, a list, and three dots.
        let glyphs: [(String, String)] = [
            ("reading", "M4 2h6l3 3v9H4z M10 2v3h3 M6 8h5 M6 11h5"),
            ("editing", "M3 13l1-3 7-7 2 2-7 7z M10 4l2 2"),
            ("running", "M2 3h12v10H2z M4 6l2 2-2 2 M8 10h3"),
            ("testing", "M8 1.5a6.5 6.5 0 1 0 0.01 0z M5 8l2 2 4-4"),
            ("researching", "M7 2.5a4.5 4.5 0 1 0 0.01 0z M10.3 10.3L14 14"),
            ("delegating", "M4 2v12 M4 8c4 0 6-2 8-5 M12 3v3 M12 3H9"),
            ("planning", "M5 4h8 M5 8h8 M5 12h8 M2.5 4h.5 M2.5 8h.5 M2.5 12h.5"),
            ("working", "M3.5 8h.5 M7.75 8h.5 M12 8h.5"),
        ]
        let activities = glyphs.map { name, path in
            #"<symbol id="act-\#(name)" viewBox="0 0 16 16"><path fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" d="\#(path)"/></symbol>"#
        }
        return (providers + activities).joined()
    }

    static func credit(_ node: ProjectMap.Node) -> Double? {
        switch statusGroup(node.status) {
        case "done": 1
        case "review": 0.75
        case "active": 0.4
        case "blocked": 0.3
        case "cancel": nil
        default: 0
        }
    }

    /// Percent complete per lane and for the project. A gating section with no
    /// items yet counts at the average size of the planned gating sections,
    /// with nothing done, so unplanned phases pull the project total down.
    struct Progress {
        var lanes: [Int: Double] = [:]
        var project = 0.0
        var estimatedSize = 0.0

        init(_ map: ProjectMap) {
            var done = 0.0, size = 0.0
            var plannedSizes: [Double] = []
            var unplanned = 0
            for (index, lane) in map.lanes.enumerated() {
                let credits = map.nodes.filter { $0.lane == index }.compactMap(ProjectMapHTML.credit)
                if credits.isEmpty {
                    if !lane.isTrack { unplanned += 1; lanes[index] = 0 }
                    continue
                }
                let sum = credits.reduce(0, +)
                lanes[index] = sum / Double(credits.count)
                done += sum; size += Double(credits.count)
                if !lane.isTrack { plannedSizes.append(Double(credits.count)) }
            }
            estimatedSize = plannedSizes.isEmpty ? 0 : plannedSizes.reduce(0, +) / Double(plannedSizes.count)
            size += estimatedSize * Double(unplanned)
            project = size > 0 ? done / size : 0
        }
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func bar(_ value: Double) -> String {
        #"<i class="bar"><i style="width:\#(f(min(1, max(0, value)) * 100))%"></i></i>"#
    }

    static func statusGroup(_ status: String) -> String {
        switch status.lowercased() {
        case "missing": "ghost"
        case "resolved", "done", "completed", "closed", "merged", "deployed": "done"
        case "cancelled", "canceled": "cancel"
        case "blocked", "failed": "blocked"
        case "review", "qa", "in-review", "testing": "review"
        case "in-progress", "in progress", "active", "working", "implementation": "active"
        default: "idle"
        }
    }

    static func isFinished(_ node: ProjectMap.Node) -> Bool {
        node.kind == .task && ["done", "cancel"].contains(statusGroup(node.status))
    }

    static func f(_ value: Double) -> String { String(format: "%.1f", value) }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="Focus Queue project map">
<meta name="color-scheme" content="dark">
<title>{{TITLE}}</title>
<style>
:root {
  --bg: #121214; --band: #17171a; --band2: #1c1c20; --panel: #232327; --ink: #ececf0; --muted: #9a9aa3;
  --line: #3a3a42; --edge: #8a8a94; --edge-hi: #5aa2ff; --accent: #5aa2ff;
  --done: #3cbf73; --active: #4c9bff; --review: #a97cf0; --blocked: #ff6b61; --idle: #8e8e93; --cancel: #66666c;
  --ghost: #6e6e78;
  --ag-working: #8fc1ff; --ag-attention: #ffb44d; --ag-blocked: #ff6b61; --ag-interrupted: #ff9a4d; --ag-idle: #8e8e96;
}
* { box-sizing: border-box; }
html { background: var(--bg); color-scheme: dark; overflow: scroll; }
html, body { margin: 0; color: var(--ink); }
body { font: 12px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
::-webkit-scrollbar { width: 12px; height: 12px; background: #1a1a1e; }
::-webkit-scrollbar-thumb { background: #4a4a54; border-radius: 6px; border: 2px solid #1a1a1e; }
::-webkit-scrollbar-thumb:hover { background: #64646f; }
::-webkit-scrollbar-corner { background: #1a1a1e; }
header { padding: 12px 16px 10px; border-bottom: 1px solid var(--line); }
h1 { font-size: 16px; margin: 0 0 2px; }
.sub { color: var(--muted); }
.controls { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; margin-top: 8px; }
.toggle { position: absolute; opacity: 0; pointer-events: none; }
.controls label { cursor: pointer; user-select: none; }
.controls label::before { content: "☐ "; }
#hideDone:checked ~ header label[for=hideDone]::before, #hideGhosts:checked ~ header label[for=hideGhosts]::before,
#showDeps:checked ~ header label[for=showDeps]::before { content: "☑ "; }
#hideDone:checked ~ #map .fin, #hideGhosts:checked ~ #map .gh { visibility: hidden !important; }
#showDeps:checked ~ #map .extra { visibility: visible; }
.legend { display: inline-flex; flex-wrap: wrap; gap: 8px; color: var(--muted); }
.legend span { display: inline-flex; align-items: center; gap: 4px; }
.dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
.dot.ghost { border: 1.5px dashed var(--ghost); }
.hint { color: var(--muted); }
#map { position: relative; }
.band { position: absolute; left: 0; background: var(--band); border-top: 1px solid #222228; }
.band.even { background: var(--band2); }
/* Sticky and quiet: the rank tag stays at the left edge while the tree scrolls. */
.ranklabel { position: sticky; left: 0; display: inline-block; z-index: 3; margin-top: 6px; padding: 1px 7px;
  font-size: 10px; font-weight: 600; color: #5c5c66; letter-spacing: .04em; }
#map > svg { position: absolute; left: 0; top: 0; overflow: visible; pointer-events: none; z-index: 1; }
.pv svg, .act svg, .menu svg { display: inline-block; position: static; }
line { stroke: var(--edge); stroke-width: 1.4; }
line.struct { stroke: #5a5a64; }
line.dep.tree { stroke: var(--edge); }
line.extra { visibility: hidden; stroke-dasharray: 5 4; opacity: .8; }
line.dep { marker-end: url(#a); }
line.off { display: none; }
.group { position: absolute; z-index: 1; border: 1px dashed #3c3c46; border-radius: 12px; background: rgba(255,255,255,.015); pointer-events: none; }
line.lit { visibility: visible; stroke: var(--review); stroke-width: 2; opacity: 1; marker-end: url(#ahi); }
line.dash { stroke-dasharray: 5 4; }
.root, .phase, .node { position: absolute; z-index: 2; }
.root { width: 240px; height: 56px; border-radius: 28px; background: #1d2a3d; border: 2px solid var(--accent);
  display: flex; flex-direction: column; align-items: center; justify-content: center; }
.root { cursor: pointer; height: 64px; }
.root b { font-size: 15px; } .root span { color: var(--muted); font-size: 11px; }
.bar { display: block; width: 70%; height: 4px; margin-top: 4px; border-radius: 2px; background: #34343c; overflow: hidden; }
.bar i { display: block; height: 100%; background: var(--done); border-radius: 2px; }
.phase { cursor: pointer; }
.phase:hover { border-color: var(--accent); }
.phase.unplanned { border-style: dotted; opacity: .75; }
html[data-fq-map] .phase::after { content: "▸"; position: absolute; right: 8px; top: 6px; color: var(--muted); font-size: 10px; }
.phase { width: 200px; height: 56px; border-radius: 10px; background: #26262c; border: 1.5px solid #6a6a76;
  display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 0 10px; text-align: center; }
.phase b { font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
.phase span { color: var(--muted); font-size: 10.5px; }
.phase.track { border-style: dashed; }
.node { width: 176px; height: 74px; display: flex; flex-direction: column; background: var(--panel);
  border: 1px solid var(--line); border-top: 3px solid var(--idle); border-radius: 8px; padding: 4px 8px 3px; }
.node:hover { box-shadow: 0 0 0 2px var(--edge-hi); }
.node[data-task] { cursor: pointer; }
/* Agent marks hang under the card and wrap into rows. */
.agents { position: absolute; left: 6px; right: 6px; top: calc(100% + 3px); display: flex; flex-wrap: wrap; gap: 3px; pointer-events: auto; }
.agents:empty { display: none; }
.phase .live { display: inline-flex; gap: 2px; margin-left: 5px; vertical-align: -3px; }
.phase .live .pv, .phase .live .pv svg { width: 12px; height: 12px; }
.pv { position: relative; display: inline-flex; flex: none; width: 14px; height: 14px; --glow: rgba(90,162,255,.9); color: var(--ag-idle); }
.pv svg { width: 14px; height: 14px; }
/* Agent states: working pulses blue, needs-you pulses amber fast, blocked
   pulses red slowly, interrupted is a still orange, idle a still grey. */
.pv.working { color: var(--ag-working); --glow: rgba(90,162,255,.9); animation: pulse 1.6s ease-in-out infinite; }
.pv.attention { color: var(--ag-attention); --glow: rgba(255,180,77,.95); animation: pulse .9s ease-in-out infinite; }
.pv.blocked { color: var(--ag-blocked); --glow: rgba(255,107,97,.9); animation: pulse 2.6s ease-in-out infinite; }
.pv.interrupted { color: var(--ag-interrupted); }
.pv.idle { color: var(--ag-idle); opacity: .75; }
@keyframes pulse { 0%, 100% { opacity: .45; transform: scale(.9); filter: none; }
  50% { opacity: 1; transform: scale(1.1); filter: drop-shadow(0 0 4px var(--glow)); } }
.agentlegend { display: inline-flex; flex-wrap: wrap; gap: 8px; align-items: center; color: var(--muted); }
.agentlegend .pv { width: 12px; height: 12px; } .agentlegend .pv svg { width: 12px; height: 12px; }
.agentlegend span { display: inline-flex; align-items: center; gap: 4px; }
.act { color: #8fc1ff; margin-left: 6px; min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.act:empty { display: none; }
.act svg { width: 11px; height: 11px; margin-right: 3px; vertical-align: -1px; }
.more { display: none; margin-left: auto; border: 0; background: transparent; color: var(--muted); font-size: 14px; line-height: 1; padding: 0 3px; border-radius: 4px; cursor: pointer; }
html[data-fq-map] .more { display: inline-block; }
.more:hover { background: #34343c; color: var(--ink); }
.menu { position: absolute; z-index: 60; min-width: 210px; background: #2a2a30; border: 1px solid var(--line); border-radius: 8px;
  padding: 4px; box-shadow: 0 10px 30px rgba(0,0,0,.55); font-size: 12px; }
.menu button { display: flex; width: 100%; align-items: center; gap: 8px; text-align: left; border: 0; background: transparent; color: var(--ink);
  padding: 5px 8px; border-radius: 5px; cursor: pointer; font: inherit; }
.menu button:hover { background: #3a5a8c; }
.menu button:disabled { color: var(--muted); background: transparent; cursor: default; }
.menu button svg { width: 13px; height: 13px; }
.menu hr { border: 0; border-top: 1px solid var(--line); margin: 4px 2px; }
.menu .head { color: var(--muted); padding: 3px 8px 4px; font-size: 11px; }
.node.peek { box-shadow: 0 0 0 2px var(--review), 0 8px 22px rgba(0,0,0,.55); z-index: 30; }
.node.located { animation: located 1.1s ease-out; }
@keyframes located { 0% { box-shadow: 0 0 0 0 var(--accent); } 30% { box-shadow: 0 0 0 6px rgba(90,162,255,.55); } 100% { box-shadow: 0 0 0 0 rgba(90,162,255,0); } }
.actions { display: none; gap: 6px; }
html[data-fq-map] .actions { display: inline-flex; }
.actions button { font: inherit; color: var(--ink); background: #26262c; border: 1px solid var(--line); border-radius: 6px; padding: 2px 8px; cursor: pointer; }
.node:has(details[open]) { z-index: 40; }
.node.s-done { border-top-color: var(--done); }
.node.s-active { border-top-color: var(--active); }
.node.s-review { border-top-color: var(--review); }
.node.s-blocked { border-top-color: var(--blocked); }
.node.s-cancel { border-top-color: var(--cancel); }
.node.s-cancel .title { text-decoration: line-through; }
.node.ghost { background: transparent; border: 1.5px dashed var(--ghost); color: var(--ghost); }
.top { display: flex; gap: 5px; align-items: center; }
.id { font: 10.5px ui-monospace, "SF Mono", Menlo, monospace; color: var(--muted); white-space: nowrap; flex: none; }
.top .pill { flex: none; margin-left: auto; }
html[data-fq-map] .top .more + .pill { margin-left: 0; }
.pill { font-size: 9.5px; font-weight: 600; padding: 0 5px; border-radius: 8px; border: 1px solid currentColor; white-space: nowrap; }
.pill.s-done { color: var(--done); } .pill.s-active { color: var(--active); } .pill.s-review { color: var(--review); }
.pill.s-blocked { color: var(--blocked); } .pill.s-idle { color: var(--idle); } .pill.s-cancel { color: var(--cancel); }
.pill.ghost { color: var(--ghost); border-style: dashed; }
.title { font-weight: 600; font-size: 11.5px; margin-top: 1px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
details { margin-top: auto; position: relative; }
summary { cursor: pointer; color: var(--muted); list-style: none; user-select: none; font-size: 11px;
  display: flex; align-items: baseline; white-space: nowrap; overflow: hidden; }
summary::-webkit-details-marker { display: none; }
summary::before { content: "▸"; display: inline-block; width: 11px; flex: none; }
details[open] summary::before { content: "▾"; }
.panel { position: absolute; left: -9px; top: 17px; width: 320px; max-height: 300px; overflow: auto; color: var(--ink);
  background: #2a2a30; border: 1px solid var(--line); border-radius: 8px; padding: 6px 9px; box-shadow: 0 8px 24px rgba(0,0,0,.5); }
.meta { font-size: 11px; color: var(--muted); margin-bottom: 3px; }
.agent { padding: 5px 0 3px; border-top: 1px solid var(--line); }
.agent b { font-weight: 600; }
.clamp { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
{{HOVER}}
</style>
</head>
<body>
<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>{{ICONS}}</defs></svg>
<input type="checkbox" class="toggle" id="hideDone">
<input type="checkbox" class="toggle" id="hideGhosts">
<input type="checkbox" class="toggle" id="showDeps">
<header>
  <h1>{{HEADING}}</h1>
  <div class="sub">{{SUMMARY}}</div>
  <div class="controls">
    <label for="hideDone">Hide finished</label>
    <label for="hideGhosts">Hide ghost tasks</label>
    <label for="showDeps">Show all dependencies</label>
    <span class="legend">
      <span><i class="dot" style="background:var(--active)"></i>In progress</span>
      <span><i class="dot" style="background:var(--review)"></i>Review/QA</span>
      <span><i class="dot" style="background:var(--blocked)"></i>Blocked</span>
      <span><i class="dot" style="background:var(--idle)"></i>Not started</span>
      <span><i class="dot" style="background:var(--done)"></i>Done</span>
      <span><i class="dot ghost"></i>No task yet</span>
    </span>
    <span class="agentlegend" title="Each mark is one agent, shown with its provider's icon">Agents:
      <span><i class="pv working"><svg viewBox="0 0 24 24"><use href="#pv-claude"/></svg></i>Working</span>
      <span><i class="pv attention"><svg viewBox="0 0 24 24"><use href="#pv-claude"/></svg></i>Needs you</span>
      <span><i class="pv blocked"><svg viewBox="0 0 24 24"><use href="#pv-claude"/></svg></i>Blocked</span>
      <span><i class="pv interrupted"><svg viewBox="0 0 24 24"><use href="#pv-claude"/></svg></i>Interrupted</span>
      <span><i class="pv idle"><svg viewBox="0 0 24 24"><use href="#pv-claude"/></svg></i>Idle</span>
    </span>
    <span class="actions"><button type="button" data-action="expand">Expand all</button><button type="button" data-action="collapse">Collapse all</button></span>
    <span class="hint">Arrows point from a task to the work that waits on it · click a phase to open it · click a task to find it in the queue · scroll to zoom · right-drag to move</span>
  </div>
</header>
<div id="map" data-layout="{{LAYOUT}}" style="width:{{WIDTH}}px;height:{{HEIGHT}}px">
{{BANDS}}
<svg width="{{WIDTH}}" height="{{HEIGHT}}" viewBox="0 0 {{WIDTH}} {{HEIGHT}}" aria-hidden="true">
<defs>
<marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#8a8a94"/></marker>
<marker id="ahi" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#5aa2ff"/></marker>
</defs>
{{EDGES}}
</svg>
{{CARDS}}
</div>
<script>
{{SCRIPT}}
</script>
</body>
</html>
"""#
}

private extension ProjectMapHTML.TreeNode {
    var isGhost: Bool {
        if case .item(let node, _) = kind { return node.kind == .ghost }
        return false
    }
}
