import Foundation

/// The project map's interaction script: the root's milestone picker, one
/// milestone's tree at a time with collapsible cards (all collapsed at first),
/// animated layout, centering and zooming on what a click opens, hover
/// highlighting, temporary "peek" of dependencies hidden in collapsed parts,
/// click-to-locate, and live agent marks. It reads only the static markup
/// `ProjectMapHTML` writes (`data-node`, `data-parent`, `data-lane`,
/// `data-rank`, `data-near`, `data-from/to`, and the `.opt` milestone options).
///
/// Focus Queue's document viewer keeps page scripts off and injects this source
/// into its own isolated content world; the page also carries it inline for the
/// UI Canvas and browsers. `data-fq-map` on `<html>` keeps it to one run per page.
/// Without any script the page still shows the current milestone's static tree.
///
/// Cost matters on large plans: animation frames touch only the cards and lines
/// that move, hover highlighting toggles classes on a handful of elements, and
/// live pushes rebuild only the cards whose agents changed.
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
  var rootEl = document.getElementById('root');
  var picker = document.getElementById('phases');
  var options = [].slice.call(map.querySelectorAll('.opt'));
  var nodes = {}, list = [];
  map.querySelectorAll('[data-node]').forEach(function (el) {
    var n = { id: el.dataset.node, el: el, kind: el.dataset.kind, parent: el.dataset.parent || null,
              lane: el.dataset.lane || null, rank: +el.dataset.rank, children: [],
              shown: el.style.display !== 'none' };
    var size = C.sizes[n.kind] || C.sizes.item;
    n.w = size[0]; n.h = size[1];
    n.cx = parseFloat(el.style.left) + n.w / 2; n.y = parseFloat(el.style.top);
    nodes[n.id] = n; list.push(n);
  });
  list.forEach(function (n) { if (n.parent && nodes[n.parent]) nodes[n.parent].children.push(n); });
  var root = nodes.root;

  // Cards with children start collapsed; a badge on each counts what it hides.
  function collapsible(n) { return n.kind !== 'root' && n.children.length > 0; }
  list.forEach(function (n) {
    if (n.kind !== 'item' || !n.children.length) return;
    var kids = document.createElement('span');
    kids.className = 'kids';
    kids.title = n.children.length + ' below: click the card to show or hide';
    n.el.appendChild(kids);
    n.el.classList.add('parent');
    n.kids = kids;
  });
  // Hidden because a card above it is collapsed.
  function folded(n) {
    for (var p = n.parent && nodes[n.parent]; p; p = p.parent && nodes[p.parent]) {
      if (collapsible(p) && !expanded.has(p.id)) return true;
    }
    return false;
  }

  var lines = [].map.call(map.querySelectorAll('line[data-from]'), function (el) {
    return { el: el, from: nodes[el.dataset.from], to: nodes[el.dataset.to],
             dep: el.classList.contains('dep'), on: !el.classList.contains('off') };
  }).filter(function (l) { return l.from && l.to; });
  var bands = [].slice.call(map.querySelectorAll('.band[data-rank]'));

  var storeKey = 'fq-map-open:' + location.pathname, laneKey = 'fq-map-lane:' + location.pathname;
  var expanded = new Set();
  try { expanded = new Set(JSON.parse(sessionStorage.getItem(storeKey) || '[]')); } catch (e) {}
  function save() { try { sessionStorage.setItem(storeKey, JSON.stringify(Array.from(expanded))); } catch (e) {} }
  var selected = rootEl ? rootEl.dataset.current : null;
  try {
    var saved = sessionStorage.getItem(laneKey);
    if (saved && options.some(function (o) { return o.dataset.lane === saved; })) selected = saved;
  } catch (e) {}
  var peek = [];

  // Tidy tree over what is visible. A parent with more than WRAP leaf
  // children wraps them into a framed grid at most WRAP wide.
  // Peeked tasks stack under their nearest shown ancestor.
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
    function measure(n) {
      n.frame = null; n.extra = stripExtra(n); n.off = 0;
      n.vis = n === root ? n.children.filter(function (k) { return k.lane === selected; })
            : (collapsible(n) && !expanded.has(n.id)) ? [] : n.children;
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
      if (!n || target[id]) return;
      var host = shownAncestor(n, target);
      if (!host || host === root) return;
      var at = target[host.id];
      var i = stacks[host.id] = (stacks[host.id] || 0);
      stacks[host.id] = i + 1;
      target[id] = { cx: at.cx, y: at.y + host.h + 44 + i * C.sub, peek: true };
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

  function shownAncestor(n, target) {
    for (var p = n.parent && nodes[n.parent]; p; p = p.parent && nodes[p.parent]) {
      if (target[p.id] && !target[p.id].peek) return p;
    }
    return root;
  }
  // Cards grow out of, and fold back into, the nearest card still shown.
  function anchor(n, target) {
    var a = target[shownAncestor(n, target).id] || target.root;
    return { cx: a.cx, y: a.y };
  }

  var frameID = 0, lastTarget = {}, moving = [], active = [];
  function apply(animate) {
    var target = lastTarget = layout();
    list.forEach(function (n) {
      n.moving = false;
      if (!n.kids) return;
      var open = expanded.has(n.id);
      var text = (open ? '▾ ' : '▸ ') + n.children.length;
      if (n.kids.textContent !== text) n.kids.textContent = text;
      n.el.classList.toggle('open', open);
    });
    // Only cards shown before or after this change move; the rest stay hidden untouched.
    moving = list.filter(function (n) { return n.shown || target[n.id]; });
    var maxX = 0, maxY = 0, maxRank = 0;
    moving.forEach(function (n) {
      var to = target[n.id];
      n.moving = true;
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
    // Lines between moving cards redraw each frame; every other line is off.
    active = [];
    lines.forEach(function (l) {
      if (l.from.moving && l.to.moving) active.push(l);
      else if (l.on) { l.el.classList.add('off'); l.on = false; }
    });
    drawFrames(false);
    cancelAnimationFrame(frameID);
    var start = performance.now(), duration = animate ? 300 : 0;
    function frame(now) {
      var k = duration ? Math.min(1, (now - start) / duration) : 1;
      var e = 1 - Math.pow(1 - k, 3);
      moving.forEach(function (n) {
        n.cx = n.from.cx + (n.to.cx - n.from.cx) * e;
        n.y = n.from.y + (n.to.y - n.from.y) * e;
        n.el.style.left = (n.cx - n.w / 2) + 'px';
        n.el.style.top = n.y + 'px';
        n.el.style.opacity = n.willShow ? (n.shown ? '' : String(e)) : String(1 - e);
        n.el.style.transform = (n.willShow && !n.shown) ? 'scale(' + (0.6 + 0.4 * e) + ')' : '';
      });
      drawLines();
      if (k < 1) { frameID = requestAnimationFrame(frame); return; }
      moving.forEach(function (n) {
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
    moving.forEach(function (n) {
      var t = target[n.id];
      if (!t || !t.peek) return;
      for (var r = 0; r + 1 < rankTop.length && rankTop[r + 1] <= t.y + n.h; r++) deepest = Math.max(deepest, r + 1);
    });
    return deepest;
  }

  function drawn(n) { return n.el.style.display !== 'none'; }
  function drawLines() {
    active.forEach(function (l) {
      var a = l.from, b = l.to;
      var on = drawn(a) && drawn(b);
      if (on !== l.on) { l.el.classList.toggle('off', !on); l.on = on; }
      // A dependency reaching a peeked task is lit, so the reason it appeared is visible.
      l.el.classList.toggle('lit', on && l.dep &&
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

  // The milestone picker: the root opens it; a choice shows that milestone.
  function option(lane) { return options.filter(function (o) { return o.dataset.lane === lane; })[0]; }
  function showRoot() {
    var o = option(selected);
    if (!rootEl || !o) return;
    rootEl.querySelector('.sel').textContent = o.dataset.title;
    var det = rootEl.querySelector('.det');
    if (det && det.firstChild) det.firstChild.nodeValue = o.dataset.detail;
    var bar = rootEl.querySelector('.bar i');
    if (bar) bar.style.width = o.dataset.share + '%';
    options.forEach(function (x) { x.classList.toggle('on', x === o); x.setAttribute('aria-selected', String(x === o)); });
    paintRootLive();
  }
  function openPicker() {
    if (!picker || !rootEl) return;
    picker.style.left = Math.max(8, parseFloat(rootEl.style.left) + (C.sizes.root[0] - 300) / 2) + 'px';
    picker.style.top = (parseFloat(rootEl.style.top) + C.sizes.root[1] + 8) + 'px';
    picker.hidden = false;
  }
  function closePicker() { if (picker && !picker.hidden) picker.hidden = true; }
  function select(lane) {
    closePicker();
    if (lane !== selected) {
      selected = lane;
      try { sessionStorage.setItem(laneKey, lane); } catch (e) {}
      peek = []; highlight(null); showRoot(); apply(true);
    }
    focus(root);
  }

  // Cards with children toggle; the root opens the picker; other tasks
  // locate themselves in the queue; documents open.
  map.addEventListener('click', function (event) {
    if (event.target.closest('details') || event.target.closest('.menu')) return;
    var opt = event.target.closest('.opt');
    if (opt) { select(opt.dataset.lane); return; }
    if (event.target.closest('a[href]')) return;
    var more = event.target.closest('.more');
    if (more) {
      event.stopPropagation();
      var card = more.closest('[data-task]'), r = more.getBoundingClientRect(), m = map.getBoundingClientRect();
      openMenu(card, r.left - m.left, r.bottom - m.top + 4);
      return;
    }
    closeMenu();
    var el = event.target.closest('[data-node]');
    if (!el) { closePicker(); return; }
    var n = nodes[el.dataset.node];
    if (n === root) { if (picker && picker.hidden) openPicker(); else closePicker(); return; }
    closePicker();
    if (collapsible(n)) {
      // Opening a card centers the view on it and zooms to fit what opened;
      // closing leaves the view where it is.
      var opening = !expanded.has(n.id);
      if (opening) expanded.add(n.id); else expanded.delete(n.id);
      save(); peek = []; apply(true);
      if (opening) focus(n);
    } else if (el.dataset.task) {
      el.classList.remove('located'); void el.offsetWidth; el.classList.add('located');
      send({ type: 'locate', task: el.dataset.task });
    } else {
      var link = el.querySelector('a[href]');
      if (link) link.click();
    }
  });
  document.querySelectorAll('[data-action]').forEach(function (button) {
    button.addEventListener('click', function () {
      var all = list.filter(function (n) { return collapsible(n) && n.lane === selected; });
      if (button.dataset.action === 'expand') all.forEach(function (n) { expanded.add(n.id); });
      else all.forEach(function (n) { expanded.delete(n.id); });
      save(); peek = []; apply(true);
    });
  });

  // The box around a node and its shown descendants, in page coordinates
  // (the map sits below the header). The app zooms to fit it; a browser
  // just scrolls it to the middle.
  function focus(n) {
    var t = lastTarget, box = null;
    (function grow(k) {
      var at = t[k.id];
      if (!at || at.peek) return;
      var x = at.cx - k.w / 2, y = at.y, r = x + k.w, b = y + k.h + (k.extra || 0);
      box = box ? { x: Math.min(box.x, x), y: Math.min(box.y, y), r: Math.max(box.r, r), b: Math.max(box.b, b) }
                : { x: x, y: y, r: r, b: b };
      (k.vis || []).forEach(grow);
    })(n);
    if (!box) return;
    var ox = map.offsetLeft, oy = map.offsetTop, at = t[n.id];
    var rect = [box.x + ox, box.y + oy, box.r - box.x, box.b - box.y];
    var node = [at.cx - n.w / 2 + ox, at.y + oy, n.w, n.h];
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.focusQueueMap;
    if (handler) { handler.postMessage({ type: 'focus', box: rect, node: node }); return; }
    var wide = rect[2] > innerWidth, tall = rect[3] > innerHeight;
    window.scrollTo({ left: (wide ? node[0] + node[2] / 2 : rect[0] + rect[2] / 2) - innerWidth / 2,
                      top: tall ? node[1] - 40 : rect[1] + rect[3] / 2 - innerHeight / 2, behavior: 'smooth' });
  }

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
  document.addEventListener('keydown', function (event) { if (event.key === 'Escape') { closeMenu(); closePicker(); } });
  document.addEventListener('click', function (event) {
    if (menu && !event.target.closest('.menu')) closeMenu();
    if (!event.target.closest('#map')) closePicker();
  });

  // Live agents, pushed by the app every few seconds: one provider mark per
  // unfinished agent in a strip under its task, colored and pulsing by state
  // (see the legend), and the newest tool call as a rough activity. Only cards
  // whose agents changed are rebuilt.
  var liveSig = {}, laneLive = {}, laneSig = {};
  window.fqMapLive = function (payload) {
    if (!payload || !payload.tasks) return;
    if (payload.providers) live.providers = payload.providers;
    if (payload.defaultProvider) live.defaultProvider = payload.defaultProvider;
    if (payload.names) live.names = payload.names;
    var buckets = {}, grew = false;
    list.forEach(function (n) {
      if (n.kind !== 'item' || !n.el.dataset.task) return;
      var agents = payload.tasks[n.el.dataset.task] || [];
      agents.forEach(function (a) {
        var state = agentState(a);
        if (!state || state === 'idle' || !n.lane) return;
        var bucket = buckets[n.lane] = buckets[n.lane] || {};
        var key = state + ':' + a.p;
        bucket[key] = (bucket[key] || 0) + 1;
      });
      var sig = JSON.stringify(agents);
      if (liveSig[n.id] === sig) return;
      liveSig[n.id] = sig;
      var strip = n.el.querySelector('.agents'), act = n.el.querySelector('.act');
      var before = strip ? strip.children.length : 0;
      if (strip) strip.textContent = '';
      if (act) act.textContent = '';
      agents.forEach(function (a) {
        var state = agentState(a);
        if (!state || !strip) return;
        var i = document.createElement('i');
        i.className = 'pv ' + state;
        i.title = a.t + ' (' + (live.names[a.p] || a.p) + ') · ' + STATE_LABELS[state] +
          (state === 'working' && a.k ? ' · ' + a.k + ' ' + (a.d || '') : '') + (a.a && state !== 'working' ? ' · ' + a.a : '');
        i.appendChild(icon('pv-' + a.p));
        strip.appendChild(i);
      });
      var doing = agents.filter(function (a) { return agentState(a) === 'working' && a.k; })[0];
      if (act && doing) {
        act.appendChild(icon('act-' + doing.k));
        act.appendChild(document.createTextNode(doing.k + (doing.d ? ' ' + doing.d : '')));
        act.title = doing.t + ': ' + doing.k + (doing.d ? ' ' + doing.d : '');
      }
      if (n.shown && strip && strip.children.length !== before && stripExtra(n) !== n.extra) grew = true;
    });
    // Each milestone shows one mark per provider and state at work inside it,
    // most urgent first, so the picker shows what needs you anywhere.
    laneLive = buckets;
    options.forEach(function (o) {
      var bucket = buckets[o.dataset.lane] || {}, sig = JSON.stringify(bucket);
      if (laneSig[o.dataset.lane] === sig) return;
      laneSig[o.dataset.lane] = sig;
      paintLive(o.querySelector('.live'), bucket);
    });
    paintRootLive();
    // A strip that gained or lost a row of marks moves the rows below it.
    if (grew) apply(true);
  };
  function paintLive(slot, bucket) {
    if (!slot) return;
    slot.textContent = '';
    var total = 0;
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
    slot.title = total ? total + ' active agent' + (total === 1 ? '' : 's') + ' in this milestone' : '';
  }
  // The root shows the chosen milestone's marks; its caret turns amber when
  // an agent elsewhere needs you.
  var rootSig = '';
  function paintRootLive() {
    if (!rootEl) return;
    var bucket = laneLive[selected] || {};
    var elsewhere = Object.keys(laneLive).some(function (lane) {
      return lane !== selected && Object.keys(laneLive[lane]).some(function (k) { return k.indexOf('attention:') === 0; });
    });
    var sig = selected + JSON.stringify(bucket) + elsewhere;
    if (sig === rootSig) return;
    rootSig = sig;
    paintLive(rootEl.querySelector('.live'), bucket);
    var caret = rootEl.querySelector('.caret');
    if (caret) {
      caret.classList.toggle('alert', elsewhere);
      caret.title = elsewhere ? 'An agent in another milestone needs you' : '';
    }
  }

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

  // Hovering a card highlights it, its dependency neighbours, and their lines.
  var hl = null, hlEls = [];
  function highlight(el) {
    if (hl === el) return;
    hlEls.forEach(function (x) { x.classList.remove('hi'); });
    hlEls = [];
    hl = el;
    map.classList.toggle('dim', !!el);
    if (!el) return;
    hlEls = [el];
    (el.dataset.near || '').split(' ').forEach(function (j) {
      var other = j && document.getElementById('n' + j);
      if (other) hlEls.push(other);
    });
    map.querySelectorAll('line.e' + el.id.slice(1)).forEach(function (l) { hlEls.push(l); });
    hlEls.forEach(function (x) { x.classList.add('hi'); });
  }

  // Resting on a task briefly shows its dependencies hidden in collapsed cards.
  var hoverTimer = 0, leaveTimer = 0;
  function related(id) {
    var out = [];
    lines.forEach(function (l) {
      if (!l.dep) return;
      var other = l.from.id === id ? l.to : l.to.id === id ? l.from : null;
      if (other && other.kind === 'item' && other.lane === selected && folded(other)) out.push(other.id);
    });
    return out;
  }
  function setPeek(ids) {
    var same = ids.length === peek.length && ids.every(function (id, i) { return peek[i] === id; });
    if (same) return;
    peek = ids; apply(true);
  }
  // Resting on a card for half a second grows it to show its full text.
  var fullTimer = 0, fullEl = null;
  function setFull(el) {
    if (fullEl === el) return;
    if (fullEl) fullEl.classList.remove('full');
    fullEl = el;
    if (el) el.classList.add('full');
  }
  map.addEventListener('mouseover', function (event) {
    var el = event.target.closest('.node');
    if (!el) return;
    clearTimeout(leaveTimer);
    highlight(el);
    if (el !== fullEl) {
      clearTimeout(fullTimer);
      fullTimer = setTimeout(function () { setFull(el); }, 500);
    }
    if (el.classList.contains('peek')) return;
    clearTimeout(hoverTimer);
    var id = el.dataset.node;
    hoverTimer = setTimeout(function () { setPeek(related(id)); }, 140);
  });
  map.addEventListener('mouseout', function (event) {
    var el = event.target.closest('.node');
    if (!el || (event.relatedTarget && el.contains(event.relatedTarget))) return;
    clearTimeout(hoverTimer);
    clearTimeout(fullTimer);
    clearTimeout(leaveTimer);
    if (fullEl === el) setFull(null);
    highlight(null);
    leaveTimer = setTimeout(function () { setPeek([]); }, 260);
  });

  showRoot();
  apply(false);
})();
"""#
}
