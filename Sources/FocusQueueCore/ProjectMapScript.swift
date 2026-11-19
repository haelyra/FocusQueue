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

  // Tidy tree over what is visible. A parent with more than WRAP children
  // keeps the ones that have subtrees in its first row and wraps the rest
  // into a framed grid at most WRAP wide, so wide ranks become extra rows.
  // Peeked tasks stack under their collapsed phase so nothing else moves while
  // the pointer rests on a card.
  var WRAP = 5;
  var frames = [], rankTop = [];
  // Agent marks hang under a card; the first row fits in the gap below it,
  // and each further row adds height so the rows below move down.
  var MARK = 17;
  function stripExtra(n) {
    var strip = n.kind === 'item' && n.el.querySelector('.agents');
    var count = strip ? strip.children.length : 0;
    var perRow = Math.max(1, Math.floor((n.w - 12 + 3) / MARK));
    return Math.max(0, Math.ceil(count / perRow) - 1) * MARK;
  }
  function layout() {
    var target = {}, need = {};
    frames = [];
    list.forEach(function (n) { n.frame = null; n.extra = stripExtra(n); n.off = 0; });
    function measure(n) {
      n.vis = (n.kind === 'phase' && !expanded.has(n.id)) ? [] : n.children;
      n.vis.forEach(measure);
      n.grid = null;
      var leaves = n.vis.filter(function (k) { return !k.vis.length; });
      if (n.vis.length > WRAP && leaves.length > 1) {
        var branches = n.vis.filter(function (k) { return k.vis.length; });
        var cols = Math.min(WRAP, leaves.length), rowCount = Math.ceil(leaves.length / cols);
        // Rows in a wrapped group sit one card apart, plus any extra mark rows above them.
        var offset = 0;
        for (var row = 0; row < rowCount; row++) {
          var members = leaves.slice(row * cols, row * cols + cols);
          members.forEach(function (k) { k.off = offset; });
          offset += C.sub + Math.max.apply(null, members.map(function (k) { return k.extra; }));
        }
        n.grid = { branches: branches, leaves: leaves, cols: cols, rows: rowCount };
        n.slots = branches.reduce(function (s, k) { return s + k.slots; }, 0) + cols;
      } else {
        n.slots = n.vis.length ? n.vis.reduce(function (s, k) { return s + k.slots; }, 0) : 1;
      }
      return n.slots;
    }
    var root = nodes.root;
    measure(root);
    // Each rank is as tall as its deepest wrapped row and longest mark strip need.
    (function collect(n) {
      need[n.rank] = Math.max(need[n.rank] || 0, n.off + n.extra);
      n.vis.forEach(collect);
    })(root);
    rankTop = [C.top];
    for (var r = 0; r <= 64; r++) rankTop.push(rankTop[r] + C.rank + (need[r] || 0));
    function place(n, start) {
      target[n.id] = { cx: C.left + (start + n.slots / 2) * C.slot, y: rankTop[n.rank] + n.off };
      var c = start;
      if (!n.grid) { n.vis.forEach(function (k) { place(k, c); c += k.slots; }); return; }
      n.grid.branches.forEach(function (k) { place(k, c); c += k.slots; });
      var g = n.grid, bottom = 0;
      g.leaves.forEach(function (k, i) {
        place(k, c + (i % g.cols));
        bottom = Math.max(bottom, k.off + k.h + k.extra);
      });
      var frame = { parent: n.id, x: C.left + c * C.slot + 4, y: rankTop[n.rank + 1] - 12,
                    w: g.cols * C.slot - 8, h: bottom + 32 };
      frame.cx = frame.x + frame.w / 2;
      frames.push(frame);
      g.leaves.forEach(function (k) { k.frame = frame; });
    }
    place(root, 0);
    var stacks = {};
    peek.forEach(function (id) {
      var n = nodes[id];
      if (!n || target[id] || !n.lane || !target[n.lane]) return;
      var phase = target[n.lane], phaseNode = nodes[n.lane];
      var i = stacks[n.lane] = (stacks[n.lane] || 0);
      stacks[n.lane] = i + 1;
      target[id] = { cx: phase.cx, y: phase.y + phaseNode.h + 44 + i * C.sub, peek: true };
    });
    return target;
  }

  // Wrapped groups get a frame behind their cards; parent lines land on it.
  var frameEls = [];
  function drawFrames(visible) {
    frameEls.forEach(function (el) { el.remove(); });
    frameEls = [];
    if (!visible) return;
    frames.forEach(function (f) {
      var el = document.createElement('div');
      el.className = 'group';
      el.style.left = f.x + 'px'; el.style.top = f.y + 'px';
      el.style.width = f.w + 'px'; el.style.height = f.h + 'px';
      map.insertBefore(el, svg);
      frameEls.push(el);
    });
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
    var deepest = Math.max(maxRank, peekDepth(target));
    bands.forEach(function (b) {
      var r = +b.dataset.rank;
      b.style.display = r <= deepest ? '' : 'none';
      b.style.width = width + 'px';
      b.style.top = (rankTop[r] - 34) + 'px';
      b.style.height = (rankTop[r + 1] - rankTop[r]) + 'px';
    });
    drawFrames(false);
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
      drawFrames(true);
      drawLines();
    }
    // Without animation the layout lands now, so a map never flashes expanded.
    if (animate) frameID = requestAnimationFrame(frame); else frame(start);
  }

  function peekDepth(target) {
    var deepest = 0;
    list.forEach(function (n) {
      var t = target[n.id];
      if (!t || !t.peek) return;
      for (var r = 0; r + 1 < rankTop.length && rankTop[r + 1] <= t.y + n.h; r++) deepest = Math.max(deepest, r + 1);
    });
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
      // A line from a parent into its wrapped group ends on the group's frame,
      // so it never threads between the cards.
      if (b.frame && b.frame.parent === a.id && !b.el.classList.contains('peek')) {
        x1 = a.cx; y1 = a.y + a.h; x2 = b.frame.cx; y2 = b.frame.y - 3;
      } else if (b.y >= a.y + a.h) { x1 = a.cx; y1 = a.y + a.h; x2 = b.cx; y2 = b.y - 3; }
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
    if (event.target.closest('details') || event.target.closest('.menu')) return;
    var more = event.target.closest('.more');
    if (more) {
      event.stopPropagation();
      var card = more.closest('[data-task]'), r = more.getBoundingClientRect(), m = map.getBoundingClientRect();
      openMenu(card, r.left - m.left, r.bottom - m.top + 4);
      return;
    }
    closeMenu();
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
      send({ type: 'locate', task: el.dataset.task });
    }
  });
  document.querySelectorAll('[data-action]').forEach(function (button) {
    button.addEventListener('click', function () {
      var phases = list.filter(function (p) { return p.kind === 'phase' && p.children.length; });
      expanded = new Set(button.dataset.action === 'expand' ? phases.map(function (p) { return p.id; }) : []);
      save(); peek = []; apply(true);
    });
  });

  function send(message) {
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.focusQueueMap;
    if (handler) handler.postMessage(message);
  }

  // Task menu: right-click a task card, or its ⋯ button.
  var menu = null, live = { providers: ['claude', 'codex', 'kimi'], defaultProvider: null, names: {} };
  function closeMenu() { if (menu) { menu.remove(); menu = null; } }
  function icon(id) {
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', id.indexOf('pv-') === 0 ? '0 0 24 24' : '0 0 16 16');
    svg.setAttribute('width', '13'); svg.setAttribute('height', '13');
    var use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', '#' + id);
    svg.appendChild(use);
    return svg;
  }
  function item(label, iconID, enabled, action) {
    var b = document.createElement('button');
    b.type = 'button';
    if (iconID) b.appendChild(icon(iconID));
    b.appendChild(document.createTextNode(label));
    b.disabled = !enabled;
    b.addEventListener('click', function (event) { event.stopPropagation(); closeMenu(); action(); });
    return b;
  }
  function openMenu(card, x, y) {
    closeMenu();
    var task = card.dataset.task, open = !card.classList.contains('fin');
    menu = document.createElement('div');
    menu.className = 'menu';
    var head = document.createElement('div');
    head.className = 'head';
    head.textContent = task + (open ? '' : ' · finished');
    menu.appendChild(head);
    var name = function (p) { return live.names[p] || (p.charAt(0).toUpperCase() + p.slice(1)); };
    // The app's default provider leads once the app has said which it is.
    if (live.defaultProvider) {
      menu.appendChild(item('Launch agent (' + name(live.defaultProvider) + ')', 'pv-' + live.defaultProvider, open,
        function () { send({ type: 'launch', task: task }); }));
    }
    live.providers.filter(function (p) { return p !== live.defaultProvider; }).forEach(function (p) {
      menu.appendChild(item('Launch ' + name(p) + ' agent', 'pv-' + p, open,
        function () { send({ type: 'launch', task: task, provider: p }); }));
    });
    menu.appendChild(item('New agent with a prompt…', 'act-editing', open, function () { send({ type: 'prompt', task: task }); }));
    menu.appendChild(document.createElement('hr'));
    menu.appendChild(item('Find in queue', 'act-researching', true, function () { send({ type: 'locate', task: task }); }));
    menu.style.left = x + 'px'; menu.style.top = y + 'px';
    map.appendChild(menu);
  }
  map.addEventListener('contextmenu', function (event) {
    var card = event.target.closest('[data-task]');
    if (!card) return;
    event.preventDefault();
    var m = map.getBoundingClientRect();
    openMenu(card, event.clientX - m.left, event.clientY - m.top);
  });
  document.addEventListener('keydown', function (event) { if (event.key === 'Escape') closeMenu(); });
  document.addEventListener('click', function (event) { if (menu && !event.target.closest('.menu')) closeMenu(); });

  // Live agents, pushed by the app every few seconds: one provider mark per
  // unfinished agent in a strip under its task, colored and pulsing by state
  // (see the legend), and the newest tool call as a rough activity.
  window.fqMapLive = function (payload) {
    if (!payload || !payload.tasks) return;
    if (payload.providers) live.providers = payload.providers;
    if (payload.defaultProvider) live.defaultProvider = payload.defaultProvider;
    if (payload.names) live.names = payload.names;
    var phaseLive = {};
    list.forEach(function (n) {
      if (n.kind !== 'item' || !n.el.dataset.task) return;
      var agents = payload.tasks[n.el.dataset.task] || [];
      var strip = n.el.querySelector('.agents'), act = n.el.querySelector('.act');
      if (strip) strip.textContent = '';
      if (act) act.textContent = '';
      agents.forEach(function (a) {
        var state = agentState(a);
        if (!state) return;
        var i = document.createElement('i');
        i.className = 'pv ' + state;
        i.title = a.t + ' (' + (live.names[a.p] || a.p) + ') · ' + STATE_LABELS[state] +
          (state === 'working' && a.k ? ' · ' + a.k + ' ' + (a.d || '') : '') + (a.a && state !== 'working' ? ' · ' + a.a : '');
        i.appendChild(icon('pv-' + a.p));
        if (strip) strip.appendChild(i);
        if (n.lane && state !== 'idle') {
          var bucket = phaseLive[n.lane] = phaseLive[n.lane] || {};
          var key = state + ':' + a.p;
          bucket[key] = (bucket[key] || 0) + 1;
        }
      });
      var doing = agents.filter(function (a) { return agentState(a) === 'working' && a.k; })[0];
      if (act && doing) {
        act.appendChild(icon('act-' + doing.k));
        act.appendChild(document.createTextNode(doing.k + (doing.d ? ' ' + doing.d : '')));
        act.title = doing.t + ': ' + doing.k + (doing.d ? ' ' + doing.d : '');
      }
    });
    // Each phase shows one mark per provider and state at work inside it,
    // most urgent first, so a collapsed phase still shows what needs you.
    list.forEach(function (n) {
      if (n.kind !== 'phase') return;
      var slot = n.el.querySelector('.live');
      if (!slot) return;
      slot.textContent = '';
      var bucket = phaseLive[n.id] || {}, total = 0;
      Object.keys(bucket).sort(function (x, y) {
        return STATE_ORDER.indexOf(x.split(':')[0]) - STATE_ORDER.indexOf(y.split(':')[0]);
      }).forEach(function (key) {
        var parts = key.split(':');
        total += bucket[key];
        var i = document.createElement('i');
        i.className = 'pv ' + parts[0];
        i.title = bucket[key] + ' ' + (live.names[parts[1]] || parts[1]) + ' · ' + STATE_LABELS[parts[0]];
        i.appendChild(icon('pv-' + parts[1]));
        slot.appendChild(i);
      });
      slot.title = total ? total + ' active agent' + (total === 1 ? '' : 's') + ' in this phase' : '';
    });
    // A strip that gained or lost a row of marks moves the rows below it.
    if (list.some(function (n) { return n.shown && stripExtra(n) !== n.extra; })) apply(true);
  };

  // Same rules as ProjectMap.State: attention wins over status.
  var STATE_LABELS = { working: 'Working', attention: 'Needs you', blocked: 'Blocked', interrupted: 'Interrupted', idle: 'Idle' };
  var STATE_ORDER = ['attention', 'blocked', 'interrupted', 'working', 'idle'];
  function agentState(a) {
    if (a.ak === 'approval' || a.ak === 'question') return 'attention';
    if (a.ak === 'interrupted') return 'interrupted';
    if (a.ak === 'failed' || a.ak === 'incomplete' || a.ak === 'quotaExhausted') return 'blocked';
    if (a.s === 'working') return 'working';
    if (a.s === 'blocked') return 'blocked';
    if (a.s === 'idle' || a.s === 'queued') return 'idle';
    return null;
  }

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

  // Resting on a card or phase for half a second grows it to show its full text.
  var fullTimer = 0, fullEl = null;
  function setFull(el) {
    if (fullEl === el) return;
    if (fullEl) fullEl.classList.remove('full');
    fullEl = el;
    if (el) el.classList.add('full');
  }
  map.addEventListener('mouseover', function (event) {
    var el = event.target.closest('.node, .phase');
    if (!el || el === fullEl) return;
    clearTimeout(fullTimer);
    fullTimer = setTimeout(function () { setFull(el); }, 500);
  });
  map.addEventListener('mouseout', function (event) {
    var el = event.target.closest('.node, .phase');
    if (!el || (event.relatedTarget && el.contains(event.relatedTarget))) return;
    clearTimeout(fullTimer);
    if (fullEl === el) setFull(null);
  });

  apply(false);
})();
"""#
}
