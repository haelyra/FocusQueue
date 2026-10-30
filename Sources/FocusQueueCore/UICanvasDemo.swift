import Foundation

/// The example mockup the walkthrough opens in UI Canvas, so a new user can
/// try editing and chatting before asking an agent for a real one.
public enum UICanvasDemo {
  public static let title = "Demo · Habit tracker"
  public static let fileName = "ui-canvas-demo.html"

  /// Writes the mockup into the task's folder (once) and returns its path.
  public static func install(supportDirectory: URL, taskID: String) throws -> URL {
    let directory = supportDirectory
      .appendingPathComponent("tasks/\(taskID.uppercased())/walkthrough", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(fileName)
    if !FileManager.default.fileExists(atPath: file.path) {
      try Data(html.utf8).write(to: file, options: .atomic)
    }
    return file
  }

  public static let html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Streaks · Habit tracker</title>
    <style>
      :root { --bg:#0f1218; --panel:#171b23; --line:#262c38; --ink:#e8ebf1; --muted:#8b93a3; --accent:#5ad1a8; --soft:#16332b; }
      * { box-sizing:border-box; }
      body { margin:0; font:15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
             background:var(--bg); color:var(--ink); }
      nav { display:flex; align-items:center; gap:28px; padding:18px 40px; border-bottom:1px solid var(--line); }
      .logo { font-weight:700; font-size:18px; letter-spacing:-.01em; }
      .logo span { color:var(--accent); }
      nav a { color:var(--muted); text-decoration:none; font-size:14px; }
      nav a.active { color:var(--ink); }
      nav .avatar { margin-left:auto; width:32px; height:32px; border-radius:50%;
                    background:linear-gradient(135deg,#5ad1a8,#4f7cff); }
      main { display:grid; grid-template-columns: 1.6fr 1fr; gap:24px; padding:32px 40px; max-width:1180px; }
      h1 { margin:0 0 4px; font-size:30px; letter-spacing:-.02em; }
      .sub { color:var(--muted); margin:0 0 24px; }
      .card { background:var(--panel); border:1px solid var(--line); border-radius:16px; padding:20px; }
      h2 { margin:0 0 14px; font-size:13px; color:var(--muted); text-transform:uppercase; letter-spacing:.08em; }
      ul { list-style:none; margin:0; padding:0; }
      li { display:flex; align-items:center; gap:14px; padding:14px 12px; border-radius:12px; cursor:pointer; }
      li + li { border-top:1px solid var(--line); }
      li:hover { background:#1c212b; }
      li .check { width:22px; height:22px; border-radius:50%; border:2px solid #3a4252; flex:none;
                  display:grid; place-items:center; color:#0f1218; font-size:13px; font-weight:700; }
      li.done .check { background:var(--accent); border-color:var(--accent); }
      li.done .name { color:var(--muted); text-decoration:line-through; }
      li .streak { margin-left:auto; font-size:12px; color:var(--accent); background:var(--soft);
                   padding:3px 9px; border-radius:999px; }
      .stat { display:flex; align-items:center; gap:16px; margin-bottom:18px; }
      .stat strong { display:block; font-size:22px; }
      .stat span { color:var(--muted); font-size:13px; }
      .week { display:grid; grid-template-columns:repeat(7,1fr); gap:8px; align-items:end; height:120px; margin-top:8px; }
      .week div { background:linear-gradient(180deg,#5ad1a8,#2f7d6d); border-radius:6px 6px 3px 3px; }
      .days { display:grid; grid-template-columns:repeat(7,1fr); gap:8px; color:var(--muted); font-size:11px;
              text-align:center; margin-top:6px; }
      button.add { margin-top:18px; padding:12px 18px; border:0; border-radius:10px; background:var(--accent);
                   color:#0b1512; font-size:15px; font-weight:600; cursor:pointer; }
    </style>
    </head>
    <body>
      <nav>
        <div class="logo">Streaks<span>.</span></div>
        <a class="active" href="#">Today</a><a href="#">Habits</a><a href="#">Insights</a>
        <div class="avatar"></div>
      </nav>
      <main>
        <section>
          <h1>Good morning</h1>
          <p class="sub">Thursday · keep your streaks alive</p>
          <div class="card">
            <h2>Today</h2>
            <ul id="habits">
              <li class="done"><span class="check">✓</span><span class="name">Drink a glass of water</span><span class="streak">12 days</span></li>
              <li class="done"><span class="check">✓</span><span class="name">Stretch for 5 minutes</span><span class="streak">4 days</span></li>
              <li><span class="check">✓</span><span class="name">Read 10 pages</span><span class="streak">7 days</span></li>
              <li><span class="check">✓</span><span class="name">Plan tomorrow</span><span class="streak">2 days</span></li>
            </ul>
            <button class="add">Add a habit</button>
          </div>
        </section>
        <aside class="card">
          <h2>Progress</h2>
          <div class="stat">
            <svg width="64" height="64" viewBox="0 0 56 56" aria-hidden="true">
              <circle cx="28" cy="28" r="23" fill="none" stroke="#1f2a2a" stroke-width="7"/>
              <circle id="progress" cx="28" cy="28" r="23" fill="none" stroke="#5ad1a8" stroke-width="7"
                      stroke-linecap="round" stroke-dasharray="144.5" stroke-dashoffset="72" transform="rotate(-90 28 28)"/>
            </svg>
            <div><strong id="summary">2 of 4 done</strong><span>Best streak: 12 days</span></div>
          </div>
          <h2>This week</h2>
          <div class="week">
            <div style="height:60%"></div><div style="height:85%"></div><div style="height:45%"></div>
            <div style="height:100%"></div><div style="height:70%"></div><div style="height:30%"></div><div style="height:50%"></div>
          </div>
          <div class="days"><span>M</span><span>T</span><span>W</span><span>T</span><span>F</span><span>S</span><span>S</span></div>
        </aside>
      </main>
      <script>
        const items = [...document.querySelectorAll('#habits li')];
        function update() {
          const done = items.filter(item => item.classList.contains('done')).length;
          document.getElementById('summary').textContent = done + ' of ' + items.length + ' done';
          document.getElementById('progress').setAttribute('stroke-dashoffset', 144.5 * (1 - done / items.length));
        }
        items.forEach(item => item.addEventListener('click', () => { item.classList.toggle('done'); update(); }));
        update();
      </script>
    </body>
    </html>
    """
}
