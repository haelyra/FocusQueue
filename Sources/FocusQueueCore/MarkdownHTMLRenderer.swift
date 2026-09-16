import Foundation
import Ink

public enum MarkdownHTMLRenderer {
  public static func page(
    markdown: String, sourceURL: URL, accentStyle: QueueAccentStyle = .vibrant
  ) -> String {
    let parser = MarkdownParser(modifiers: [headingModifier, mermaidModifier, taskListModifier])
    let body = parser.html(from: markdown)
    let title = escapeHTML(sourceURL.lastPathComponent)
    let baseURL = escapeHTML(
      sourceURL.deletingLastPathComponent().appendingPathComponent("", isDirectory: true)
        .absoluteString
    )
    let accentTokens = accentTokens(for: accentStyle)

    return """
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data: https: http:; media-src file: data: https: http:; style-src 'unsafe-inline'; font-src data:;">
        <base href="\(baseURL)">
        <title>\(title)</title>
        <style>
          :root {
            color-scheme: light dark;
            --page: light-dark(#f3f3f3, #242424);
            --surface: light-dark(#ffffff, #292929);
            --surface-raised: light-dark(#ededed, #303030);
            --surface-hover: light-dark(#e7e7e7, #363636);
            --border: light-dark(#d5d5d5, #454545);
            --border-strong: light-dark(#bdbdbd, #626262);
            --text: light-dark(#252525, #eeeeee);
            --text-secondary: light-dark(#606060, #b2b2b2);
            --text-tertiary: light-dark(#777777, #969696);
            \(accentTokens)
            --radius: 12px;
            --radius-small: 7px;
          }
          * { box-sizing: border-box; }
          html { background: var(--page); min-height: 100%; -webkit-font-smoothing: antialiased; }
          body {
            min-height: 100vh;
            max-width: 1100px;
            margin: 0 auto;
            padding: 28px 34px 64px;
            color: var(--text);
            background: var(--page);
            font: 15.5px/1.66 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            overflow-wrap: break-word;
          }
          ::selection { color: var(--selection-text); background: var(--selection); }
          h1, h2, h3, h4, h5, h6 {
            line-height: 1.24;
            margin: 1.6em 0 0.62em;
            letter-spacing: -0.012em;
            text-wrap: balance;
            scroll-margin-top: 20px;
          }
          h1 { position: relative; margin-top: 0; padding-bottom: 18px; font-size: 29px; }
          h1::after {
            content: "";
            position: absolute;
            left: 0;
            bottom: 0;
            width: 62px;
            height: 4px;
            border-radius: 99px;
            background: var(--border-strong);
          }
          h2 { padding-bottom: 0.42em; border-bottom: 1px solid var(--border); font-size: 21px; }
          h3 { font-size: 17px; }
          h4, h5, h6 {
            color: var(--text-secondary);
            font-size: 13px;
            letter-spacing: 0.055em;
            text-transform: uppercase;
          }
          p, li, blockquote { text-wrap: pretty; }
          ul, ol { padding-left: 1.45em; }
          li { margin: 0.28em 0; }
          li.task-list-item { list-style: none; margin-left: -1.3em; }
          .task-checkbox { width: 14px; height: 14px; margin: 0 7px 0 0; vertical-align: middle; accent-color: var(--text-secondary); opacity: 1; }
          a {
            color: var(--accent);
            font-weight: 520;
            text-decoration-color: var(--accent-border);
            text-underline-offset: 0.18em;
            transition-property: color, text-decoration-color;
            transition-duration: 140ms;
            transition-timing-function: ease-out;
          }
          a:hover { color: var(--accent-strong); text-decoration-color: currentColor; }
          a:focus-visible { outline: 3px solid var(--accent-glow-strong); outline-offset: 3px; }
          blockquote {
            margin: 1em 0;
            padding: 10px 15px;
            color: var(--text-secondary);
            background: var(--accent-glow);
            border-left: 3px solid var(--accent);
            border-radius: 0 var(--radius-small) var(--radius-small) 0;
          }
          code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          code { padding: 0.15em 0.38em; border: 1px solid var(--border); border-radius: 5px; background: var(--surface-raised); }
          pre { padding: 16px; overflow: auto; border: 1px solid var(--border); border-radius: var(--radius); background: var(--surface); }
          pre code { padding: 0; background: transparent; }
          table {
            display: block;
            width: max-content;
            max-width: 100%;
            margin: 1.15em 0;
            overflow: auto;
            border-collapse: separate;
            border: 1px solid var(--border);
            border-radius: var(--radius);
            border-spacing: 0;
            background: var(--surface);
          }
          th, td { padding: 8px 13px; border-right: 1px solid var(--border); border-bottom: 1px solid var(--border); }
          th:last-child, td:last-child { border-right: 0; }
          tr:last-child td { border-bottom: 0; }
          th {
            color: var(--text-secondary);
            background: var(--surface-raised);
            font-size: 11.5px;
            letter-spacing: 0.04em;
          }
          tbody tr { transition-property: background-color; transition-duration: 120ms; }
          tbody tr:hover { background: var(--surface-hover); }
          img {
            max-width: 100%;
            height: auto;
            border-radius: var(--radius-small);
            outline: 1px solid light-dark(rgba(0, 0, 0, 0.1), rgba(255, 255, 255, 0.1));
            outline-offset: -1px;
          }
          hr { height: 1px; margin: 28px 0; border: 0; background: var(--border); }
          figure[data-plan-canvas-diagram] {
            position: relative;
            margin: 1.25em 0;
            padding: 18px;
            cursor: pointer;
            border: 1px solid var(--border);
            border-radius: calc(var(--radius) + 6px);
            background: var(--surface);
            box-shadow: 0 1px 2px light-dark(rgba(27, 35, 64, 0.06), rgba(0, 0, 0, 0.28));
            transition-property: border-color, box-shadow, transform, background-color;
            transition-duration: 150ms;
            transition-timing-function: ease-out;
          }
          figure[data-plan-canvas-diagram]:hover {
            border-color: var(--accent-border);
            box-shadow: 0 8px 24px light-dark(rgba(49, 63, 117, 0.10), rgba(0, 0, 0, 0.32));
          }
          figure[data-plan-canvas-diagram]:active { transform: scale(0.995); }
          figure[data-plan-canvas-diagram]:focus-visible,
          figure[data-plan-canvas-diagram].is-selected {
            outline: 3px solid var(--accent-glow-strong);
            outline-offset: 2px;
            border-color: var(--accent);
          }
          figure[data-plan-canvas-diagram].is-selected::after {
            content: "Selected for discussion";
            position: absolute;
            top: 10px;
            right: 10px;
            padding: 4px 8px;
            color: var(--selection-text);
            background: var(--accent);
            border-radius: 99px;
            font-size: 10px;
            font-weight: 650;
            letter-spacing: 0.02em;
          }
          pre.mermaid { margin: 0; white-space: pre-wrap; }
          figure.is-rendered pre.mermaid { padding: 4px; border: 0; background: transparent; text-align: center; }
          figure.is-rendered pre.mermaid svg { max-width: 100%; height: auto; }
          .plan-diagram-source { display: none; }
          figure[data-plan-canvas-diagram] figcaption {
            display: flex;
            align-items: center;
            gap: 7px;
            min-height: 20px;
            margin-top: 10px;
            color: var(--text-tertiary);
            font-size: 10.5px;
            letter-spacing: 0.035em;
            text-transform: uppercase;
          }
          figure[data-plan-canvas-diagram] figcaption::before {
            content: "◇";
            color: var(--accent);
            font-size: 14px;
          }
          figure.is-loading .diagram-state::before { content: "Rendering diagram"; }
          figure.is-unrendered .diagram-state::before { content: "Diagram source · renderer unavailable"; }
          figure:not(.is-loading):not(.is-unrendered) .diagram-state::before { content: "Click diagram to discuss"; }
          ::-webkit-scrollbar { width: 9px; height: 9px; }
          ::-webkit-scrollbar-track { background: transparent; }
          ::-webkit-scrollbar-thumb { background: var(--border-strong); border: 2px solid transparent; border-radius: 99px; background-clip: padding-box; }
          @media (max-width: 600px) { body { padding: 28px 24px 64px; } }
          @media (prefers-reduced-motion: reduce) {
            *, *::before, *::after { scroll-behavior: auto !important; transition-duration: 0.01ms !important; }
          }
        </style>
      </head>
      <body>
      \(body)
      </body>
      </html>
      """
  }

  private static func escapeHTML(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private static var taskListModifier: Modifier {
    Modifier(target: .lists) { input in
      // Modify parsed list items only. Literal examples in code remain literal.
      guard let regex = try? NSRegularExpression(pattern: #"<li>(<p>)?\[([ xX])\]\s*"#) else { return input.html }
      var html = input.html
      for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
        guard let range = Range(match.range, in: html), let marker = Range(match.range(at: 2), in: html) else { continue }
        let checked = html[marker].lowercased() == "x"
        let paragraph = match.range(at: 1).location == NSNotFound ? "" : "<p>"
        html.replaceSubrange(range, with: "<li class=\"task-list-item\">\(paragraph)<input class=\"task-checkbox\" type=\"checkbox\" disabled\(checked ? " checked" : "") aria-label=\"\(checked ? "Completed task" : "Incomplete task")\"> ")
      }
      return html
    }
  }

  private static var headingModifier: Modifier {
    Modifier(target: .headings) { input in
      guard let openingEnd = input.html.firstIndex(of: ">") else { return input.html }
      let rawTitle = input.markdown.drop(while: { $0 == "#" || $0.isWhitespace })
      let identifier = headingIdentifier(String(rawTitle))
      guard !identifier.isEmpty else { return input.html }
      var html = input.html
      html.insert(contentsOf: " id=\"\(escapeHTML(identifier))\"", at: openingEnd)
      return html
    }
  }

  private static var mermaidModifier: Modifier {
    Modifier(target: .codeBlocks) { input in
      guard let firstLine = input.markdown.split(separator: "\n", maxSplits: 1).first else {
        return input.html
      }
      let language = firstLine.drop(while: { $0 == "`" }).trimmingCharacters(in: .whitespaces)
        .split(whereSeparator: \.isWhitespace).first?.lowercased()
      guard language == "mermaid" else { return input.html }
      let prefix = #"<pre><code class="language-mermaid">"#
      let suffix = "</code></pre>"
      guard input.html.hasPrefix(prefix), input.html.hasSuffix(suffix) else { return input.html }
      let sourceStart = input.html.index(input.html.startIndex, offsetBy: prefix.count)
      let sourceEnd = input.html.index(input.html.endIndex, offsetBy: -suffix.count)
      let source = String(input.html[sourceStart..<sourceEnd])
      return """
        <figure data-plan-canvas-diagram role="button" tabindex="0" aria-label="Select diagram for discussion" aria-pressed="false">
        <pre class="mermaid">\(source)</pre>
        <code class="plan-diagram-source" hidden>\(source)</code>
        <figcaption><span class="diagram-state"></span></figcaption>
        </figure>
        """
    }
  }

  private static func headingIdentifier(_ value: String) -> String {
    value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# "))
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: "-")
  }

  private static func accentTokens(for style: QueueAccentStyle) -> String {
    switch style {
    case .muted:
      return """
        --accent: light-dark(#557a8b, #78a7b8); --accent-strong: light-dark(#395d6c, #9cc3d0);
        --accent-companion: light-dark(#9b6980, #bd86a0); --accent-border: light-dark(#91aeba, #567d8c);
        --accent-glow: light-dark(rgba(85, 122, 139, 0.09), rgba(120, 167, 184, 0.12));
        --accent-glow-strong: light-dark(rgba(85, 122, 139, 0.23), rgba(120, 167, 184, 0.28));
        --selection: light-dark(#cce0e8, #345767); --selection-text: light-dark(#172b34, #f4fbff);
        """
    case .pastel:
      return """
        --accent: light-dark(#607bc7, #91adff); --accent-strong: light-dark(#405aa4, #b5c6ff);
        --accent-companion: light-dark(#c66b94, #f39bc1); --accent-border: light-dark(#a9b8e7, #687dbb);
        --accent-glow: light-dark(rgba(96, 123, 199, 0.09), rgba(145, 173, 255, 0.13));
        --accent-glow-strong: light-dark(rgba(96, 123, 199, 0.24), rgba(145, 173, 255, 0.30));
        --selection: light-dark(#d9e1ff, #3f538f); --selection-text: light-dark(#17203f, #ffffff);
        """
    case .monochrome:
      return """
        --accent: light-dark(#525866, #b5bdce); --accent-strong: light-dark(#292e38, #dce1eb);
        --accent-companion: light-dark(#838996, #7e879a); --accent-border: light-dark(#aeb4c0, #677085);
        --accent-glow: light-dark(rgba(82, 88, 102, 0.08), rgba(181, 189, 206, 0.10));
        --accent-glow-strong: light-dark(rgba(82, 88, 102, 0.22), rgba(181, 189, 206, 0.25));
        --selection: light-dark(#d9dce2, #474d5a); --selection-text: light-dark(#1b1e24, #ffffff);
        """
    case .vibrant:
      return """
        --accent: light-dark(#5068d8, #8294ff); --accent-strong: light-dark(#324ab8, #aab6ff);
        --accent-companion: light-dark(#ca3d7c, #ef79ad); --accent-border: light-dark(#9aa8eb, #5f70ca);
        --accent-glow: light-dark(rgba(80, 104, 216, 0.09), rgba(130, 148, 255, 0.14));
        --accent-glow-strong: light-dark(rgba(80, 104, 216, 0.25), rgba(130, 148, 255, 0.32));
        --selection: light-dark(#ccd5ff, #40539d); --selection-text: light-dark(#111a3c, #ffffff);
        """
    }
  }
}
