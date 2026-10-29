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
    <title>Habit tracker</title>
    <style>
      :root { --bg:#f6f4ef; --card:#fff; --ink:#1f2328; --muted:#6b7280; --accent:#2f7d6d; --soft:#e4f1ed; }
      * { box-sizing:border-box; }
      body { margin:0; font:15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
             background:var(--bg); color:var(--ink); }
      header { padding:28px 20px 12px; }
      .date { color:var(--muted); font-size:13px; text-transform:uppercase; letter-spacing:.06em; }
      h1 { margin:4px 0 0; font-size:28px; }
      .ring { display:flex; align-items:center; gap:14px; margin:18px 20px; padding:16px;
              background:var(--card); border-radius:18px; box-shadow:0 1px 3px rgba(0,0,0,.06); }
      .ring svg { flex:none; }
      .ring strong { font-size:20px; display:block; }
      .ring span { color:var(--muted); font-size:13px; }
      h2 { margin:22px 20px 8px; font-size:13px; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; }
      ul { list-style:none; margin:0 16px; padding:0; }
      li { display:flex; align-items:center; gap:12px; padding:14px; margin-bottom:8px; background:var(--card);
           border-radius:14px; box-shadow:0 1px 2px rgba(0,0,0,.05); cursor:pointer; }
      li .check { width:24px; height:24px; border-radius:50%; border:2px solid #cfd4d9; flex:none;
                  display:grid; place-items:center; color:#fff; font-size:14px; }
      li.done .check { background:var(--accent); border-color:var(--accent); }
      li.done .name { color:var(--muted); text-decoration:line-through; }
      li .streak { margin-left:auto; font-size:12px; color:var(--accent); background:var(--soft);
                   padding:3px 8px; border-radius:999px; }
      button.add { display:block; margin:16px 20px 32px; width:calc(100% - 40px); padding:14px; border:0;
                   border-radius:14px; background:var(--accent); color:#fff; font-size:16px; font-weight:600; }
    </style>
    </head>
    <body>
      <header>
        <div class="date">Thursday</div>
        <h1>Good morning</h1>
      </header>
      <section class="ring">
        <svg width="56" height="56" viewBox="0 0 56 56" aria-hidden="true">
          <circle cx="28" cy="28" r="23" fill="none" stroke="#e4f1ed" stroke-width="7"/>
          <circle id="progress" cx="28" cy="28" r="23" fill="none" stroke="#2f7d6d" stroke-width="7"
                  stroke-linecap="round" stroke-dasharray="144.5" stroke-dashoffset="72" transform="rotate(-90 28 28)"/>
        </svg>
        <div><strong id="summary">2 of 4 done</strong><span>Keep the streak going</span></div>
      </section>
      <h2>Today</h2>
      <ul id="habits">
        <li class="done"><span class="check">✓</span><span class="name">Drink a glass of water</span><span class="streak">12 days</span></li>
        <li class="done"><span class="check">✓</span><span class="name">Stretch for 5 minutes</span><span class="streak">4 days</span></li>
        <li><span class="check">✓</span><span class="name">Read 10 pages</span><span class="streak">7 days</span></li>
        <li><span class="check">✓</span><span class="name">Plan tomorrow</span><span class="streak">2 days</span></li>
      </ul>
      <button class="add">Add a habit</button>
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
