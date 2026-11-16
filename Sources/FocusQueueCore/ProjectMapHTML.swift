import Foundation

/// Renders a `ProjectMap` as one self-contained HTML page: lanes per plan
/// section, columns by dependency depth, SVG edges, an agent dropdown per task,
/// and dotted grey ghost nodes. No network, no external scripts.
public enum ProjectMapHTML {
    public static func render(_ map: ProjectMap) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(map)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let safe = json.replacingOccurrences(of: "</", with: "<\\/")
        let title = escape("\(map.projectName) project map")
        return template
            .replacingOccurrences(of: "{{TITLE}}", with: title)
            .replacingOccurrences(of: "{{DATA}}", with: safe)
    }

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
  :root:not([data-theme="light"]) {
    --bg: #1b1b1d; --panel: #26262a; --ink: #f2f2f4; --muted: #a1a1a8; --line: #3a3a40;
    --edge: #5c5c64; --edge-hi: #4c9bff; --lane: #222226;
    --done: #3cbf73; --active: #4c9bff; --review: #a97cf0; --blocked: #ff6b61; --idle: #8e8e93; --cancel: #6c6c72;
    --ghost: #7c7c84;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink);
  font: 13px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
header { position: sticky; top: 0; z-index: 5; background: var(--bg); border-bottom: 1px solid var(--line);
  padding: 12px 16px 10px; }
h1 { font-size: 16px; margin: 0 0 2px; }
.sub { color: var(--muted); font-size: 12px; }
.controls { display: flex; flex-wrap: wrap; gap: 10px 14px; align-items: center; margin-top: 8px; font-size: 12px; }
.controls label { display: inline-flex; gap: 5px; align-items: center; cursor: pointer; }
.legend { display: inline-flex; flex-wrap: wrap; gap: 8px; color: var(--muted); }
.legend span { display: inline-flex; align-items: center; gap: 4px; }
.dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
.dot.ghost { background: transparent; border: 1.5px dashed var(--ghost); }
main { position: relative; padding: 12px 16px 40px; overflow-x: auto; }
svg#edges { position: absolute; left: 0; top: 0; pointer-events: none; overflow: visible; z-index: 1; }
.lane { position: relative; margin: 0 0 14px; padding: 8px 10px 10px; background: var(--lane);
  border-radius: 10px; min-width: max-content; }
.lane h2 { font-size: 12px; font-weight: 600; margin: 0 0 8px; color: var(--muted); letter-spacing: .01em; }
.lane.track h2::after { content: " · not gating"; font-weight: 400; }
.cols { display: flex; gap: 46px; align-items: flex-start; }
.col { display: flex; flex-direction: column; gap: 10px; width: 236px; }
.node { position: relative; background: var(--panel); border: 1px solid var(--line); border-left: 4px solid var(--idle);
  border-radius: 8px; padding: 7px 9px 7px; z-index: 2; }
.node.s-done { border-left-color: var(--done); }
.node.s-active { border-left-color: var(--active); }
.node.s-review { border-left-color: var(--review); }
.node.s-blocked { border-left-color: var(--blocked); }
.node.s-cancel { border-left-color: var(--cancel); opacity: .65; }
.node.s-cancel .title { text-decoration: line-through; }
.node.ghost { background: var(--lane); border: 1.5px dashed var(--ghost); color: var(--ghost); }
.node.hi { box-shadow: 0 0 0 2px var(--edge-hi); }
.node.dim { opacity: .35; }
.top { display: flex; justify-content: space-between; gap: 6px; align-items: center; }
.id { font: 11px ui-monospace, "SF Mono", Menlo, monospace; color: var(--muted); }
.pill { font-size: 10px; font-weight: 600; padding: 1px 6px; border-radius: 9px; border: 1px solid currentColor; white-space: nowrap; }
.pill.s-done { color: var(--done); } .pill.s-active { color: var(--active); } .pill.s-review { color: var(--review); }
.pill.s-blocked { color: var(--blocked); } .pill.s-idle { color: var(--idle); } .pill.s-cancel { color: var(--cancel); }
.pill.ghost { color: var(--ghost); border-style: dashed; }
.title { font-weight: 600; margin: 3px 0 2px; overflow-wrap: anywhere; }
.meta { font-size: 11px; color: var(--muted); overflow-wrap: anywhere; }
.gate { font-size: 11px; color: var(--muted); margin-top: 3px; display: -webkit-box; -webkit-line-clamp: 3;
  -webkit-box-orient: vertical; overflow: hidden; }
details { margin-top: 5px; font-size: 12px; }
summary { cursor: pointer; color: var(--muted); list-style: none; user-select: none; }
summary::-webkit-details-marker { display: none; }
summary::before { content: "▸"; display: inline-block; width: 12px; transition: transform .12s; }
details[open] summary::before { transform: rotate(90deg); }
.agent { border-top: 1px solid var(--line); padding: 4px 0 2px; margin-top: 4px; }
.agent b { font-weight: 600; }
.agent .meta { margin-top: 1px; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
.empty { color: var(--muted); padding: 20px 0; }
</style>
</head>
<body>
<header>
  <h1 id="h"></h1>
  <div class="sub" id="sub"></div>
  <div class="controls">
    <label><input type="checkbox" id="hideDone"> Hide finished</label>
    <label><input type="checkbox" id="showGhosts" checked> Ghost tasks</label>
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
<main id="board"><svg id="edges"></svg></main>
<script type="application/json" id="data">{{DATA}}</script>
<script>
(function () {
  const map = JSON.parse(document.getElementById('data').textContent);
  const board = document.getElementById('board');
  const svg = document.getElementById('edges');
  const NS = 'http://www.w3.org/2000/svg';
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

  function group(status) {
    status = (status || '').toLowerCase();
    if (status === 'missing') return 'ghost';
    if (['resolved', 'done', 'completed', 'closed', 'merged', 'deployed'].includes(status)) return 'done';
    if (['cancelled', 'canceled'].includes(status)) return 'cancel';
    if (['blocked', 'failed'].includes(status)) return 'blocked';
    if (['review', 'qa', 'in-review', 'testing'].includes(status)) return 'review';
    if (['in-progress', 'in progress', 'active', 'working', 'implementation'].includes(status)) return 'active';
    return 'idle';
  }
  const label = s => s === 'missing' ? 'No task yet' : s.replace(/-/g, ' ');

  const tasks = map.nodes.filter(n => n.kind === 'task');
  const ghosts = map.nodes.filter(n => n.kind === 'ghost');
  const open = tasks.filter(n => !['done', 'cancel'].includes(group(n.status))).length;
  document.getElementById('h').textContent = map.projectName + ' · project map';
  document.getElementById('sub').textContent =
    `Phase: ${map.currentPhase} · ${tasks.length} tasks (${open} open) · ${ghosts.length} ghost tasks · ` +
    (map.planFile ? `plan: ${map.planFile}` : 'no development plan file') +
    ` · generated ${new Date(map.generatedAt).toLocaleString()}`;

  const hideDone = document.getElementById('hideDone');
  const showGhosts = document.getElementById('showGhosts');
  try {
    hideDone.checked = localStorage.getItem('fq-map-hide-done') === '1';
    showGhosts.checked = localStorage.getItem('fq-map-ghosts') !== '0';
  } catch (e) {}

  let cards = {};
  function visible(n) {
    if (n.kind === 'ghost') return showGhosts.checked;
    return !(hideDone.checked && ['done', 'cancel'].includes(group(n.status)));
  }

  function depths(nodes) {
    const ids = new Set(nodes.map(n => n.id));
    const preds = {};
    map.edges.forEach(e => { if (ids.has(e.from) && ids.has(e.to)) (preds[e.to] = preds[e.to] || []).push(e.from); });
    const memo = {}, visiting = {};
    const depth = id => {
      if (memo[id] != null) return memo[id];
      if (visiting[id]) return 0;
      visiting[id] = true;
      const d = (preds[id] || []).reduce((m, p) => Math.max(m, depth(p) + 1), 0);
      visiting[id] = false;
      return (memo[id] = d);
    };
    nodes.forEach(n => depth(n.id));
    return memo;
  }

  function card(n) {
    const g = group(n.status);
    const c = el('div', 'node ' + (g === 'ghost' ? 'ghost' : 's-' + g));
    c.dataset.id = n.id;
    const top = el('div', 'top');
    top.append(el('span', 'id', n.kind === 'ghost' ? (n.leaves.length ? 'leaf ' + n.leaves.join(', ') : 'module') : n.id));
    top.append(el('span', 'pill ' + (g === 'ghost' ? 'ghost' : 's-' + g), label(n.status)));
    c.append(top, el('div', 'title', n.kind === 'ghost' ? n.title.replace(/^\S+\.\s/, '') : n.title));
    const meta = [];
    if (n.kind === 'task' && n.leaves.length) meta.push('Plan ' + n.leaves.join(', '));
    if (n.phase) meta.push(n.phase);
    if (meta.length) c.append(el('div', 'meta', meta.join(' · ')));
    if (n.gate) { const gt = el('div', 'gate', 'Gate: ' + n.gate); gt.title = n.gate; c.append(gt); }
    if (n.reason) c.append(el('div', 'meta', n.reason));
    if (n.kind === 'task') {
      const d = el('details');
      const count = n.agents.length;
      d.append(el('summary', null, count ? `${count} agent${count === 1 ? '' : 's'}` : 'No agents'));
      if (!count) d.append(el('div', 'meta', 'No agent has worked on this task yet.'));
      n.agents.forEach(a => {
        const row = el('div', 'agent');
        const head = el('div');
        head.append(el('b', null, a.title), document.createTextNode(` · ${a.provider} · ${a.status}`));
        row.append(head);
        if (a.attention) row.append(el('div', 'meta', a.attention));
        if (a.summary) row.append(el('div', 'meta', a.summary));
        d.append(row);
      });
      d.addEventListener('toggle', draw);
      c.append(d);
    }
    c.addEventListener('mouseenter', () => highlight(n.id));
    c.addEventListener('mouseleave', () => highlight(null));
    return c;
  }

  function layout() {
    board.querySelectorAll('.lane, .empty').forEach(e => e.remove());
    cards = {};
    let any = false;
    map.lanes.forEach((lane, i) => {
      const nodes = map.nodes.filter(n => n.lane === i && visible(n));
      if (!nodes.length) return;
      any = true;
      const d = depths(nodes);
      const section = el('section', 'lane' + (lane.isTrack ? ' track' : ''));
      section.append(el('h2', null, lane.title));
      const cols = el('div', 'cols');
      const max = Math.max(0, ...nodes.map(n => d[n.id] || 0));
      for (let k = 0; k <= max; k++) {
        const col = el('div', 'col');
        nodes.filter(n => (d[n.id] || 0) === k).forEach(n => { const c = card(n); cards[n.id] = c; col.append(c); });
        cols.append(col);
      }
      section.append(cols);
      board.append(section);
    });
    if (!any) board.append(el('div', 'empty', 'No tasks to show.'));
    draw();
  }

  let hi = null;
  function draw() {
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    svg.setAttribute('width', board.scrollWidth);
    svg.setAttribute('height', board.scrollHeight);
    const defs = document.createElementNS(NS, 'defs');
    ['edge', 'edge-hi'].forEach(name => {
      const m = document.createElementNS(NS, 'marker');
      m.setAttribute('id', 'a-' + name); m.setAttribute('viewBox', '0 0 8 8'); m.setAttribute('refX', '7');
      m.setAttribute('refY', '4'); m.setAttribute('markerWidth', '7'); m.setAttribute('markerHeight', '7');
      m.setAttribute('orient', 'auto');
      const p = document.createElementNS(NS, 'path');
      p.setAttribute('d', 'M0,0 L8,4 L0,8 z'); p.setAttribute('fill', `var(--${name})`);
      m.append(p); defs.append(m);
    });
    svg.append(defs);
    const base = board.getBoundingClientRect();
    const ox = board.scrollLeft - base.left, oy = board.scrollTop - base.top;
    map.edges.forEach(e => {
      const a = cards[e.from], b = cards[e.to];
      if (!a || !b) return;
      const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
      const on = hi && (e.from === hi || e.to === hi);
      let x1, y1, x2, y2, d;
      if (rb.left >= ra.right - 1) {
        x1 = ra.right + ox; y1 = ra.top + Math.min(ra.height / 2, 22) + oy;
        x2 = rb.left + ox - 2; y2 = rb.top + Math.min(rb.height / 2, 22) + oy;
        const dx = Math.max(24, (x2 - x1) / 2);
        d = `M${x1},${y1} C${x1 + dx},${y1} ${x2 - dx},${y2} ${x2},${y2}`;
      } else {
        x1 = ra.left + ra.width / 2 + ox; y1 = (rb.top > ra.top ? ra.bottom : ra.top) + oy;
        x2 = rb.left + rb.width / 2 + ox; y2 = (rb.top > ra.top ? rb.top - 2 : rb.bottom + 2) + oy;
        const dy = (y2 - y1) / 2;
        d = `M${x1},${y1} C${x1},${y1 + dy} ${x2},${y2 - dy} ${x2},${y2}`;
      }
      const p = document.createElementNS(NS, 'path');
      p.setAttribute('d', d); p.setAttribute('fill', 'none');
      p.setAttribute('stroke', on ? 'var(--edge-hi)' : 'var(--edge)');
      p.setAttribute('stroke-width', on ? '2' : '1.1');
      p.setAttribute('opacity', hi && !on ? '0.15' : (a.closest('.lane') === b.closest('.lane') ? '0.9' : '0.45'));
      if (e.source === 'task' || a.classList.contains('ghost') || b.classList.contains('ghost')) p.setAttribute('stroke-dasharray', '4 3');
      p.setAttribute('marker-end', `url(#a-${on ? 'edge-hi' : 'edge'})`);
      svg.append(p);
    });
  }

  function highlight(id) {
    hi = id;
    const linked = new Set(id ? [id] : []);
    if (id) map.edges.forEach(e => { if (e.from === id) linked.add(e.to); if (e.to === id) linked.add(e.from); });
    Object.entries(cards).forEach(([k, c]) => {
      c.classList.toggle('hi', !!id && k === id);
      c.classList.toggle('dim', !!id && !linked.has(k));
    });
    draw();
  }

  hideDone.addEventListener('change', () => { try { localStorage.setItem('fq-map-hide-done', hideDone.checked ? '1' : '0'); } catch (e) {} layout(); });
  showGhosts.addEventListener('change', () => { try { localStorage.setItem('fq-map-ghosts', showGhosts.checked ? '1' : '0'); } catch (e) {} layout(); });
  window.addEventListener('resize', draw);
  layout();
})();
</script>
</body>
</html>
"""#
}
