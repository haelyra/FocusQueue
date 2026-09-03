import AppKit
import FocusQueueCore
import Foundation

enum MarkdownBrowser {
  static func open(_ sourceURL: URL, workspace: NSWorkspace = .shared) throws {
    let markdown = try String(contentsOf: sourceURL, encoding: .utf8)
    let renderedURL = try writeRenderedPage(markdown, sourceURL: sourceURL)
    openInDefaultBrowser(renderedURL, workspace: workspace)
  }

  private static func writeRenderedPage(_ markdown: String, sourceURL: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ECCFocusQueue-Markdown", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let pageURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("html")
    try MarkdownHTMLRenderer.page(markdown: markdown, sourceURL: sourceURL).write(
      to: pageURL,
      atomically: true,
      encoding: .utf8
    )
    return pageURL
  }

  private static func openInDefaultBrowser(_ url: URL, workspace: NSWorkspace) {
    let webURL = URL(string: "https://example.com")!
    if let browser = workspace.urlForApplication(toOpen: webURL) {
      workspace.open(
        [url],
        withApplicationAt: browser,
        configuration: NSWorkspace.OpenConfiguration()
      )
      return
    }
    workspace.open(url)
  }
}
