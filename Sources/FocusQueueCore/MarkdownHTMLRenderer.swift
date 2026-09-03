import Foundation
import Ink

public enum MarkdownHTMLRenderer {
  public static func page(markdown: String, sourceURL: URL) -> String {
    let body = MarkdownParser().html(from: markdown)
    let title = escapeHTML(sourceURL.lastPathComponent)
    let baseURL = escapeHTML(
      sourceURL.deletingLastPathComponent().appendingPathComponent("", isDirectory: true)
        .absoluteString
    )

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
          :root { color-scheme: light dark; }
          body {
            box-sizing: border-box;
            max-width: 980px;
            margin: 0 auto;
            padding: 45px;
            color: light-dark(#1f2328, #e6edf3);
            background: light-dark(#ffffff, #0d1117);
            font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            overflow-wrap: break-word;
          }
          h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.5em 0 0.6em; }
          h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid light-dark(#d0d7de, #30363d); }
          h1:first-child, h2:first-child { margin-top: 0; }
          a { color: light-dark(#0969da, #58a6ff); }
          blockquote {
            margin-left: 0;
            padding-left: 1em;
            color: light-dark(#59636e, #9198a1);
            border-left: 0.25em solid light-dark(#d0d7de, #3d444d);
          }
          code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          code { padding: 0.15em 0.35em; border-radius: 6px; background: light-dark(#eff1f3, #252c35); }
          pre { padding: 16px; overflow: auto; border-radius: 8px; background: light-dark(#f6f8fa, #151b23); }
          pre code { padding: 0; background: transparent; }
          table { display: block; width: max-content; max-width: 100%; overflow: auto; border-collapse: collapse; }
          th, td { padding: 6px 13px; border: 1px solid light-dark(#d0d7de, #3d444d); }
          tr:nth-child(2n) { background: light-dark(#f6f8fa, #151b23); }
          img { max-width: 100%; height: auto; }
          hr { height: 1px; margin: 24px 0; border: 0; background: light-dark(#d0d7de, #3d444d); }
          @media (max-width: 600px) { body { padding: 20px; } }
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
}
