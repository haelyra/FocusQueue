import Foundation

/// The project map's interaction script: collapsible phases with animated
/// layout, temporary "peek" of dependencies hidden in collapsed phases, and
/// click-to-locate. It reads only the static markup `ProjectMapHTML` writes
/// (`data-node`, `data-parent`, `data-lane`, `data-rank`, `data-from/to`).
///
/// Focus Queue's document viewer keeps page scripts off and injects this source
/// into its own isolated content world; the page also carries it inline for the
/// UI Canvas and browsers. `data-fq-map` on `<html>` keeps it to one run per page.
/// Without any script the page still shows the fully expanded static tree.
public enum ProjectMapScript {
    /// Message handler name the app registers in its content world.
    public static let messageHandler = "focusQueueMap"

    public static let source = #"""
(function () {
  if (!document.querySelector('meta[name="generator"][content="Focus Queue project map"]')) return;
  var html = document.documentElement;
  if (html.dataset.fqMap === 'ready') return;
  var map = document.getElementById('map');
  if (!map || !map.dataset.layout) return;
  html.dataset.fqMap = 'ready';

  var C = JSON.parse(map.dataset.layout);
  var svg = map.querySelector('svg');
  var nodes = {}, list = [];
  map.querySelectorAll('[data-node]').forEach(function (el) {
    var n = { id: el.dataset.node, el: el, kind: el.dataset.kind, parent: el.dataset.parent || null,
              lane: el.dataset.lane || null, rank: +el.dataset.rank, children: [], shown: true };
    var size = C.sizes[n.kind];
    n.w = size[0]; n.h = size[1];
    n.cx = parseFloat(el.style.left) + n.w / 2; n.y = parseFloat(el.style.top);
    nodes[n.id] = n; list.push(n);
  });
  list.forEach(function (n) { if (n.parent && nodes[n.parent]) nodes[n.parent].children.push(n); });
  var lines = [].map.call(map.querySelectorAll('line[data-from]'), function (el) {
    return { el: el, from: el.dataset.from, to: el.dataset.to };
  });
  var bands = [].slice.call(map.querySelectorAll('.band[data-rank]'));

  var storeKey = 'fq-map-open:' + location.pathname;
  var expanded = new Set();
  try { expanded = new Set(JSON.parse(sessionStorage.getItem(storeKey) || '[]')); } catch (e) {}
  function save() { try { sessionStorage.setItem(storeKey, JSON.stringify([].concat(Array.from(expanded)))); } catch (e) {} }
  var peek = [];

  // Tidy tree over what is visible; peeked tasks stack under their collapsed
  // phase so nothing else moves while the pointer rests on a card.
  function layout() {
    var target = {};
    function measure(n) {
      n.vis = (n.kind === 'phase' && !expanded.has(n.id)) ? [] : n.children;
      n.slots = n.vis.length ? n.vis.reduce(function (s, k) { return s + measure(k); }, 0) : 1;
      return n.slots;
    }
    function place(n, start) {
      target[n.id] = { cx: C.left + (start + n.slots / 2) * C.slot, y: C.top + n.rank * C.rank };
      var c = start;
      n.vis.forEach(function (k) { place(k, c); c += k.slots; });
    }
    var root = nodes.root;
    measure(root); place(root, 0);
    var stacks = {};
    peek.forEach(function (id) {
      var n = nodes[id];
      if (!n || target[id] || !n.lane || !target[n.lane]) return;
      var phase = target[n.lane];
      var i = stacks[n.lane] = (stacks[n.lane] || 0) + 1;
      target[id] = { cx: phase.cx, y: phase.y + i * C.rank, peek: true };
    });
    return target;
  }

  function anchor(n, target) {
    var a = (n.lane && target[n.lane]) || (n.parent && target[n.parent]) || target.root;
    return { cx: a.cx, y: a.y };
  }

  var frameID = 0;
  function apply(animate) {
    var target = layout();
    var maxX = 0, maxY = 0, maxRank = 0;
    list.forEach(function (n) {
      var to = target[n.id];
      n.willShow = !!to;
      n.from = n.shown ? { cx: n.cx, y: n.y } : anchor(n, target);
      n.to = to || anchor(n, target);
      n.el.classList.toggle('peek', !!(to && to.peek));
      if (to) {
        n.el.style.display = '';
        maxX = Math.max(maxX, to.cx + n.w / 2); maxY = Math.max(maxY, to.y + n.h);
        if (!to.peek) maxRank = Math.max(maxRank, n.rank);
      }
    });
    var width = Math.max(maxX + C.margin, 400), height = maxY + C.margin + 30;
    map.style.width = width + 'px'; map.style.height = height + 'px';
    svg.setAttribute('width', width); svg.setAttribute('height', height);
    svg.setAttribute('viewBox', '0 0 ' + width + ' ' + height);
    bands.forEach(function (b) {
      b.style.display = (+b.dataset.rank <= Math.max(maxRank, peekDepth(target))) ? '' : 'none';
      b.style.width = width + 'px';
    });
    cancelAnimationFrame(frameID);
    var start = performance.now(), duration = animate ? 300 : 0;
    function frame(now) {
      var k = duration ? Math.min(1, (now - start) / duration) : 1;
      var e = 1 - Math.pow(1 - k, 3);
      list.forEach(function (n) {
        n.cx = n.from.cx + (n.to.cx - n.from.cx) * e;
        n.y = n.from.y + (n.to.y - n.from.y) * e;
        n.el.style.left = (n.cx - n.w / 2) + 'px';
        n.el.style.top = n.y + 'px';
        n.el.style.opacity = n.willShow ? (n.shown ? '' : String(e)) : String(1 - e);
        n.el.style.transform = (n.willShow && !n.shown) ? 'scale(' + (0.6 + 0.4 * e) + ')' : '';
      });
      drawLines();
      if (k < 1) { frameID = requestAnimationFrame(frame); return; }
      list.forEach(function (n) {
        n.shown = n.willShow;
        n.el.style.opacity = ''; n.el.style.transform = '';
        if (!n.shown) n.el.style.display = 'none';
      });
      drawLines();
    }
    // Without animation the layout lands now, so a map never flashes expanded.
    if (animate) frameID = requestAnimationFrame(frame); else frame(start);
  }

  function peekDepth(target) {
    var deepest = 0;
    list.forEach(function (n) { var t = target[n.id]; if (t && t.peek) deepest = Math.max(deepest, Math.round((t.y - C.top) / C.rank)); });
    return deepest;
  }

  function drawn(n) { return n && n.el.style.display !== 'none'; }
  function drawLines() {
    lines.forEach(function (l) {
      var a = nodes[l.from], b = nodes[l.to];
      var on = drawn(a) && drawn(b);
      l.el.classList.toggle('off', !on);
      // A dependency reaching a peeked task is lit, so the reason it appeared is visible.
      l.el.classList.toggle('lit', on && l.el.classList.contains('dep') &&
        (a.el.classList.contains('peek') || b.el.classList.contains('peek')));
      if (!on) return;
      var x1, y1, x2, y2;
      if (b.y >= a.y + a.h) { x1 = a.cx; y1 = a.y + a.h; x2 = b.cx; y2 = b.y - 3; }
      else if (b.y + b.h <= a.y) { x1 = a.cx; y1 = a.y; x2 = b.cx; y2 = b.y + b.h + 3; }
      else {
        var fwd = b.cx > a.cx;
        x1 = fwd ? a.cx + a.w / 2 : a.cx - a.w / 2; y1 = a.y + a.h / 2;
        x2 = fwd ? b.cx - b.w / 2 - 3 : b.cx + b.w / 2 + 3; y2 = b.y + b.h / 2;
      }
      l.el.setAttribute('x1', x1.toFixed(1)); l.el.setAttribute('y1', y1.toFixed(1));
      l.el.setAttribute('x2', x2.toFixed(1)); l.el.setAttribute('y2', y2.toFixed(1));
    });
  }

  // Phases and the root toggle; tasks locate themselves in the queue.
  map.addEventListener('click', function (event) {
    if (event.target.closest('details')) return;
    var el = event.target.closest('[data-node]');
    if (!el) return;
    var n = nodes[el.dataset.node];
    if (n.kind === 'phase') {
      if (expanded.has(n.id)) expanded.delete(n.id); else expanded.add(n.id);
      save(); peek = []; apply(true);
    } else if (n.kind === 'root') {
      var phases = list.filter(function (p) { return p.kind === 'phase' && p.children.length; });
      var anyOpen = phases.some(function (p) { return expanded.has(p.id); });
      expanded = new Set(anyOpen ? [] : phases.map(function (p) { return p.id; }));
      save(); peek = []; apply(true);
    } else if (el.dataset.task) {
      el.classList.remove('located'); void el.offsetWidth; el.classList.add('located');
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.focusQueueMap;
      if (handler) handler.postMessage({ type: 'locate', task: el.dataset.task });
    }
  });
  document.querySelectorAll('[data-action]').forEach(function (button) {
    button.addEventListener('click', function () {
      var phases = list.filter(function (p) { return p.kind === 'phase' && p.children.length; });
      expanded = new Set(button.dataset.action === 'expand' ? phases.map(function (p) { return p.id; }) : []);
      save(); peek = []; apply(true);
    });
  });

  // Hovering a task briefly shows its dependencies that sit in collapsed phases.
  var hoverTimer = 0, leaveTimer = 0;
  function related(id) {
    var out = [];
    lines.forEach(function (l) {
      if (!l.el.classList.contains('dep')) return;
      var other = l.from === id ? l.to : l.to === id ? l.from : null;
      if (other && nodes[other] && nodes[other].kind === 'item' && !expanded.has(nodes[other].lane)) out.push(other);
    });
    return out;
  }
  function setPeek(ids) {
    var same = ids.length === peek.length && ids.every(function (id, i) { return peek[i] === id; });
    if (same) return;
    peek = ids; apply(true);
  }
  map.addEventListener('mouseover', function (event) {
    var el = event.target.closest('[data-kind="item"]');
    if (!el) return;
    clearTimeout(leaveTimer);
    if (el.classList.contains('peek')) return;
    clearTimeout(hoverTimer);
    var id = el.dataset.node;
    hoverTimer = setTimeout(function () { setPeek(related(id)); }, 140);
  });
  map.addEventListener('mouseout', function (event) {
    var el = event.target.closest('[data-kind="item"]');
    if (!el || (event.relatedTarget && el.contains(event.relatedTarget))) return;
    clearTimeout(hoverTimer);
    clearTimeout(leaveTimer);
    leaveTimer = setTimeout(function () { setPeek([]); }, 260);
  });

  apply(false);
})();
"""#
}
