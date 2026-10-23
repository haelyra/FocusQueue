import AppKit
import FocusQueueCore
import Foundation

/// File navigation from a loadHTMLString page may be rejected by WebKit before
/// its navigation delegate receives the link. An inert app scheme keeps local
/// links inside the delegate, where their destinations are validated.
enum EmbeddedDocumentLink {
  static let scheme = "focus-queue-document"

  static func destination(_ url: URL) -> URL? {
    guard url.scheme == scheme else { return url }
    guard url.host == "open",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
      let file = URL(string: value), file.isFileURL,
      file.host == nil || file.host == "" || file.host == "localhost"
    else { return nil }
    return file
  }

  static func documentURL(_ url: URL) -> URL? {
    guard let target = destination(url), target.isFileURL,
      target.host == nil || target.host == "" || target.host == "localhost"
    else { return nil }
    var path = target.path
    // Codex source links can include a line number after the extension.
    if let range = path.range(of: #"(?i)(?<=\.md):[0-9]+$|(?<=\.markdown):[0-9]+$"#,
                              options: .regularExpression) {
      path.removeSubrange(range)
    }
    let file = URL(fileURLWithPath: path).standardizedFileURL
    guard ["md", "markdown"].contains(file.pathExtension.lowercased()) else { return nil }
    return file
  }

  static func routeLocalLinks(in html: String, sourceURL: URL) -> String {
    guard let expression = try? NSRegularExpression(pattern: #"(<a\b[^>]*\bhref=")([^"]*)(")"#,
                                                   options: .caseInsensitive) else { return html }
    var result = html
    for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
      guard let range = Range(match.range(at: 2), in: result) else { continue }
      let href = String(result[range])
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&amp;", with: "&")
      guard !href.hasPrefix("#"),
        let destination = URL(string: href, relativeTo: sourceURL.deletingLastPathComponent())?.absoluteURL,
        destination.isFileURL else { continue }
      var route = URLComponents()
      route.scheme = scheme
      route.host = "open"
      route.queryItems = [URLQueryItem(name: "url", value: destination.absoluteString)]
      if let value = route.url?.absoluteString {
        result.replaceSubrange(range, with: value.replacingOccurrences(of: "&", with: "&amp;"))
      }
    }
    return result
  }
}

struct PlanDocumentTabs {
  private(set) var urls: [URL] = []

  mutating func open(_ url: URL) {
    guard let file = EmbeddedDocumentLink.documentURL(url), !urls.contains(file) else { return }
    urls.append(file)
  }

  mutating func close(_ url: URL) {
    urls.removeAll { $0 == url }
  }
}
