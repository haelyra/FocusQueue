import Foundation

/// Renders a `ProjectMap` as one self-contained, script-free HTML page. Focus
/// Queue's document viewer runs pages with scripts off, so the layout, SVG
/// edges, hover highlighting (CSS `:has`), filters (CSS checkboxes), and agent
/// dropdowns (`<details>`) are all computed here or done in CSS.
public enum ProjectMapHTML {
    // Layout in CSS pixels. Cards have a fixed size so edges can be precomputed;
    // the agent dropdown floats over the board instead of growing the card.
    static let cardWidth = 236.0, cardHeight = 140.0
    static let columnGap = 56.0, rowGap = 12.0
    static let laneHeader = 30.0, lanePadding = 10.0, laneGap = 14.0, margin = 16.0

    struct Placed { var node: ProjectMap.Node; var index: Int; var x: Double; var y: Double }

    public static func render(_ map: ProjectMap) -> String {
        let indexOf = Dictionary(map.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Depth inside each lane = longest chain of in-lane prerequisites.
        var placed: [String: Placed] = [:]
        var lanes: [(title: String, isTrack: Bool, y: Double, height: Double, width: Double)] = []
        var y = margin
        var boardWidth = 0.0
        for (laneIndex, lane) in map.lanes.enumerated() {
            let nodes = map.nodes.filter { $0.lane == laneIndex }
            guard !nodes.isEmpty else { continue }
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
            var rows: [Int: Int] = [:]
            for node in nodes {
                let column = depthOf(node.id)
                let row = rows[column, default: 0]
                rows[column] = row + 1
                placed[node.id] = Placed(
                    node: node, index: indexOf[node.id] ?? 0,
                    x: margin + lanePadding + Double(column) * (cardWidth + columnGap),
                    y: y + laneHeader + Double(row) * (cardHeight + rowGap))
            }
            let columns = (rows.keys.max() ?? 0) + 1
            let maxRows = rows.values.max() ?? 1
            let height = laneHeader + Double(maxRows) * (cardHeight + rowGap) - rowGap + lanePadding
            let width = lanePadding * 2 + Double(columns) * cardWidth + Double(columns - 1) * columnGap
            lanes.append((lane.title, lane.isTrack, y, height, width))
            boardWidth = max(boardWidth, width)
            y += height + laneGap
        }
        let boardHeight = y + margin
        boardWidth += margin * 2

        // Edges, precomputed. Edges to a later column run right-to-left between
        // columns; the rest run between card bottoms and tops.
        var edgeMarkup: [String] = []
        var neighbours: [Int: Set<Int>] = [:]
        for edge in map.edges {
            guard let a = placed[edge.from], let b = placed[edge.to] else { continue }
            neighbours[a.index, default: []].insert(b.index)
            neighbours[b.index, default: []].insert(a.index)
            let path: String
            if b.x >= a.x + cardWidth {
                let x1 = a.x + cardWidth, y1 = a.y + 24, x2 = b.x - 2, y2 = b.y + 24
                let dx = max(24, (x2 - x1) / 2)
                path = "M\(f(x1)),\(f(y1)) C\(f(x1 + dx)),\(f(y1)) \(f(x2 - dx)),\(f(y2)) \(f(x2)),\(f(y2))"
            } else {
                let down = b.y > a.y
                let x1 = a.x + cardWidth / 2, y1 = down ? a.y + cardHeight : a.y
                let x2 = b.x + cardWidth / 2 + (b.x == a.x ? 18 : 0), y2 = down ? b.y - 2 : b.y + cardHeight + 2
                let dy = (y2 - y1) / 2
                path = "M\(f(x1)),\(f(y1)) C\(f(x1)),\(f(y1 + dy)) \(f(x2)),\(f(y2 - dy)) \(f(x2)),\(f(y2))"
            }
            var classes = ["edge", "e\(a.index)", "e\(b.index)"]
            if a.node.lane != b.node.lane { classes.append("cross") }
            if edge.source == "task" || a.node.kind == .ghost || b.node.kind == .ghost { classes.append("dash") }
            if isFinished(a.node) || isFinished(b.node) { classes.append("fin") }
            if a.node.kind == .ghost || b.node.kind == .ghost { classes.append("gh") }
            edgeMarkup.append(#"<path class="\#(classes.joined(separator: " "))" d="\#(path)"/>"#)
        }

        // Hover: highlight the card's edges and neighbours, dim everything else.
        var hoverCSS: [String] = []
        for item in placed.values.sorted(by: { $0.index < $1.index }) {
            let i = item.index
            hoverCSS.append("#map:has(#n\(i):hover) .node:not(.k\(i)){opacity:.3}")
            hoverCSS.append("#map:has(#n\(i):hover) .e\(i){stroke:var(--edge-hi);stroke-width:2;opacity:1;marker-end:url(#ahi)}")
        }

        let laneMarkup = lanes.map { lane in
            #"<section class="lane\#(lane.isTrack ? " track" : "")" style="top:\#(f(lane.y))px;left:\#(f(margin))px;width:\#(f(lane.width))px;height:\#(f(lane.height))px"><h2>\#(escape(lane.title))</h2></section>"#
        }
        let cardMarkup = placed.values.sorted(by: { $0.index < $1.index }).map { item in
            card(item, neighbours: neighbours[item.index] ?? [])
        }

        let tasks = map.nodes.filter { $0.kind == .task }
        let open = tasks.filter { !isFinished($0) }.count
        let ghosts = map.nodes.count - tasks.count
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let summary = "Phase: \(map.currentPhase) · \(tasks.count) tasks (\(open) open) · \(ghosts) ghost tasks · "
            + (map.planFile.map { "plan: \($0)" } ?? "no development plan file")
            + " · generated \(stamp.string(from: map.generatedAt))"

        return template
            .replacingOccurrences(of: "{{TITLE}}", with: escape("\(map.projectName) project map"))
            .replacingOccurrences(of: "{{HEADING}}", with: escape("\(map.projectName) · project map"))
            .replacingOccurrences(of: "{{SUMMARY}}", with: escape(summary))
            .replacingOccurrences(of: "{{HOVER}}", with: hoverCSS.joined(separator: "\n"))
            .replacingOccurrences(of: "{{WIDTH}}", with: f(boardWidth))
            .replacingOccurrences(of: "{{HEIGHT}}", with: f(boardHeight))
            .replacingOccurrences(of: "{{LANES}}", with: laneMarkup.joined(separator: "\n"))
            .replacingOccurrences(of: "{{EDGES}}", with: edgeMarkup.joined(separator: "\n"))
            .replacingOccurrences(of: "{{CARDS}}", with: cardMarkup.joined(separator: "\n"))
            .replacingOccurrences(of: "{{EMPTY}}", with: placed.isEmpty ? #"<p class="empty">No tasks to show.</p>"# : "")
    }

    static func card(_ item: Placed, neighbours: Set<Int>) -> String {
        let node = item.node
        let group = statusGroup(node.status)
        var classes = ["node", node.kind == .ghost ? "ghost" : "s-\(group)", "k\(item.index)"]
        classes += neighbours.sorted().map { "k\($0)" }
        if isFinished(node) { classes.append("fin") }
        if node.kind == .ghost { classes.append("gh") }
        let label = node.kind == .ghost
            ? (node.leaves.isEmpty ? "module" : "leaf " + node.leaves.joined(separator: ", "))
            : node.id
        let pill = node.status == "missing" ? "No task yet" : node.status.replacingOccurrences(of: "-", with: " ")
        let title = node.kind == .ghost
            ? node.title.replacingOccurrences(of: #"^\S+\.\s"#, with: "", options: .regularExpression)
            : node.title
        var meta: [String] = []
        if node.kind == .task, !node.leaves.isEmpty { meta.append("Plan " + node.leaves.joined(separator: ", ")) }
        if let phase = node.phase { meta.append(phase) }
        var body = #"<div class="top"><span class="id">\#(escape(label))</span><span class="pill \#(node.kind == .ghost ? "ghost" : "s-\(group)")">\#(escape(pill))</span></div>"#
        body += #"<div class="title" title="\#(escape(title))">\#(escape(title))</div>"#
        if !meta.isEmpty { body += #"<div class="meta">\#(escape(meta.joined(separator: " · ")))</div>"# }
        if let gate = node.gate { body += #"<div class="gate" title="\#(escape(gate))">Gate: \#(escape(gate))</div>"# }
        if let reason = node.reason { body += #"<div class="meta" title="\#(escape(reason))">\#(escape(reason))</div>"# }
        if node.kind == .task {
            let count = node.agents.count
            let heading = count == 0 ? "No agents" : "\(count) agent\(count == 1 ? "" : "s")"
            let rows = count == 0
                ? #"<div class="meta">No agent has worked on this task yet.</div>"#
                : node.agents.map { agent in
                    var row = #"<div class="agent"><div><b>\#(escape(agent.title))</b> · \#(escape(agent.provider)) · \#(escape(agent.status))</div>"#
                    if let attention = agent.attention { row += #"<div class="meta">\#(escape(attention))</div>"# }
                    if !agent.summary.isEmpty { row += #"<div class="meta clamp">\#(escape(agent.summary))</div>"# }
                    return row + "</div>"
                }.joined()
            body += #"<details><summary>\#(heading)</summary><div class="panel">\#(rows)</div></details>"#
        }
        return #"<div class="\#(classes.joined(separator: " "))" id="n\#(item.index)" data-id="\#(escape(node.id))" style="left:\#(f(item.x))px;top:\#(f(item.y))px">\#(body)</div>"#
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
<title>{{TITLE}}</title>
<style>
:root {
  --bg: #f7f7f5; --panel: #ffffff; --ink: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7;
  --edge: #a1a1a6; --edge-hi: #0a66d8; --lane: #efefec;
  --done: #1f8a4c; --active: #0a66d8; --review: #7b3fd0; --blocked: #c4372f; --idle: #8a8a8e; --cancel: #a1a1a6;
  --ghost: #9a9aa0;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #1b1b1d; --panel: #26262a; --ink: #f2f2f4; --muted: #a1a1a8; --line: #3a3a40;
    --edge: #6a6a72; --edge-hi: #4c9bff; --lane: #222226;
    --done: #3cbf73; --active: #4c9bff; --review: #a97cf0; --blocked: #ff6b61; --idle: #8e8e93; --cancel: #6c6c72;
    --ghost: #7c7c84;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--ink); }
body { font: 13px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
header { padding: 12px 16px 10px; border-bottom: 1px solid var(--line); }
h1 { font-size: 16px; margin: 0 0 2px; }
.sub { color: var(--muted); font-size: 12px; }
.controls { display: flex; flex-wrap: wrap; gap: 10px 14px; align-items: center; margin-top: 8px; font-size: 12px; }
.toggle { position: absolute; opacity: 0; pointer-events: none; }
.controls label { cursor: pointer; user-select: none; }
.controls label::before { content: "☐ "; }
#hideDone:checked ~ header label[for=hideDone]::before, #hideGhosts:checked ~ header label[for=hideGhosts]::before { content: "☑ "; }
#hideDone:checked ~ #map .fin, #hideGhosts:checked ~ #map .gh { visibility: hidden; }
.legend { display: inline-flex; flex-wrap: wrap; gap: 8px; color: var(--muted); }
.legend span { display: inline-flex; align-items: center; gap: 4px; }
.dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
.dot.ghost { border: 1.5px dashed var(--ghost); }
#map { position: relative; }
.lane { position: absolute; background: var(--lane); border-radius: 10px; padding: 8px 10px; }
.lane h2 { font-size: 12px; font-weight: 600; margin: 0; color: var(--muted); white-space: nowrap; }
.lane.track h2::after { content: " · not gating"; font-weight: 400; }
svg { position: absolute; left: 0; top: 0; overflow: visible; pointer-events: none; z-index: 1; }
.edge { fill: none; stroke: var(--edge); stroke-width: 1.2; opacity: .9; marker-end: url(#a); }
.edge.cross { opacity: .45; }
.edge.dash { stroke-dasharray: 4 3; }
.node { position: absolute; width: 236px; height: 140px; display: flex; flex-direction: column; gap: 1px;
  background: var(--panel); border: 1px solid var(--line); border-left: 4px solid var(--idle);
  border-radius: 8px; padding: 7px 9px; z-index: 2; }
.node:hover { box-shadow: 0 0 0 2px var(--edge-hi); }
.node:has(details[open]) { z-index: 40; }
.node.s-done { border-left-color: var(--done); }
.node.s-active { border-left-color: var(--active); }
.node.s-review { border-left-color: var(--review); }
.node.s-blocked { border-left-color: var(--blocked); }
.node.s-cancel { border-left-color: var(--cancel); }
.node.s-cancel .title { text-decoration: line-through; }
.node.ghost { background: var(--lane); border: 1.5px dashed var(--ghost); color: var(--ghost); }
.top { display: flex; justify-content: space-between; gap: 6px; align-items: center; }
.id { font: 11px ui-monospace, "SF Mono", Menlo, monospace; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.pill { font-size: 10px; font-weight: 600; padding: 0 6px; border-radius: 9px; border: 1px solid currentColor; white-space: nowrap; }
.pill.s-done { color: var(--done); } .pill.s-active { color: var(--active); } .pill.s-review { color: var(--review); }
.pill.s-blocked { color: var(--blocked); } .pill.s-idle { color: var(--idle); } .pill.s-cancel { color: var(--cancel); }
.pill.ghost { color: var(--ghost); border-style: dashed; }
.title { font-weight: 600; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.meta { font-size: 11px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.gate { font-size: 11px; color: var(--muted); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
details { margin-top: auto; font-size: 12px; position: relative; }
summary { cursor: pointer; color: var(--muted); list-style: none; user-select: none; }
summary::-webkit-details-marker { display: none; }
summary::before { content: "▸"; display: inline-block; width: 12px; }
details[open] summary::before { content: "▾"; }
.panel { position: absolute; left: -10px; top: 20px; width: 320px; max-height: 280px; overflow: auto;
  background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 4px 9px 6px;
  box-shadow: 0 6px 20px rgba(0,0,0,.18); }
.agent { padding: 5px 0 3px; border-top: 1px solid var(--line); }
.agent:first-child { border-top: 0; }
.agent b { font-weight: 600; }
.panel .meta { white-space: normal; }
.panel .clamp { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
.empty { color: var(--muted); padding: 20px 16px; }
{{HOVER}}
</style>
</head>
<body>
<input type="checkbox" class="toggle" id="hideDone">
<input type="checkbox" class="toggle" id="hideGhosts">
<header>
  <h1>{{HEADING}}</h1>
  <div class="sub">{{SUMMARY}}</div>
  <div class="controls">
    <label for="hideDone">Hide finished</label>
    <label for="hideGhosts">Hide ghost tasks</label>
    <span class="legend">
      <span><i class="dot" style="background:var(--active)"></i>In progress</span>
      <span><i class="dot" style="background:var(--review)"></i>Review/QA</span>
      <span><i class="dot" style="background:var(--blocked)"></i>Blocked</span>
      <span><i class="dot" style="background:var(--idle)"></i>Not started</span>
      <span><i class="dot" style="background:var(--done)"></i>Done</span>
      <span><i class="dot ghost"></i>No task yet</span>
    </span>
  </div>
</header>
{{EMPTY}}
<div id="map" style="width:{{WIDTH}}px;height:{{HEIGHT}}px">
{{LANES}}
<svg width="{{WIDTH}}" height="{{HEIGHT}}" viewBox="0 0 {{WIDTH}} {{HEIGHT}}" aria-hidden="true">
<defs>
<marker id="a" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="var(--edge)"/></marker>
<marker id="ahi" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="var(--edge-hi)"/></marker>
</defs>
{{EDGES}}
</svg>
{{CARDS}}
</div>
</body>
</html>
"""#
}
