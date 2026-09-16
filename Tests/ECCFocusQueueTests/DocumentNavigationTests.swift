import FocusQueueCore
import Foundation
import Testing

@testable import ECCFocusQueue

@Suite("Document tabs and collapsed panel")
struct DocumentNavigationTests {
  @Test("Relative Markdown links route through the app and preserve escaped filenames")
  func relativeLinks() throws {
    let source = URL(fileURLWithPath: "/tmp/Task Context/plan.md")
    let html = EmbeddedDocumentLink.routeLocalLinks(
      in: """
        <a href="../Evidence/reply%20%26%20notes.md#verdict">Reply</a>
        <a href="https://example.com/guide.md">Remote</a>
        <a href="javascript:alert(1)">Unsafe</a>
        """, sourceURL: source)
    #expect(html.contains("https://example.com/guide.md"))
    let expression = try NSRegularExpression(pattern: #"href="([^"]+)""#)
    let match = try #require(expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)))
    let range = try #require(Range(match.range(at: 1), in: html))
    let route = try #require(URL(string: String(html[range])))
    #expect(route.scheme == EmbeddedDocumentLink.scheme)
    let file = try #require(EmbeddedDocumentLink.documentURL(route))
    #expect(file.path == "/tmp/Evidence/reply & notes.md")
    #expect(!EmbeddedDocumentPolicy.allowsLink(URL(string: "javascript:alert(1)")!))
  }

  @Test("Document tabs deduplicate normalized paths and keep other tabs when one closes")
  func documentTabs() {
    var tabs = PlanDocumentTabs()
    let first = URL(fileURLWithPath: "/tmp/context/reply.md")
    let second = URL(fileURLWithPath: "/tmp/context/evidence.markdown")
    tabs.open(first)
    tabs.open(URL(fileURLWithPath: "/tmp/context/../context/reply.md"))
    tabs.open(second)
    tabs.open(URL(string: "https://example.com/plan.md")!)
    #expect(tabs.urls == [first, second])
    tabs.close(first)
    #expect(tabs.urls == [second])
  }

  @Test("Line links read the actual document and app routes cannot open remote schemes")
  func documentValidation() {
    #expect(EmbeddedDocumentLink.documentURL(URL(fileURLWithPath: "/tmp/plan.md:42"))?.path == "/tmp/plan.md")
    #expect(EmbeddedDocumentLink.destination(URL(string: "focus-queue-document://open?url=https%3A%2F%2Fexample.com")!) == nil)
    #expect(EmbeddedDocumentLink.documentURL(URL(string: "file://remote-host/share/plan.md")!) == nil)
    #expect(EmbeddedDocumentLink.documentURL(URL(fileURLWithPath: "/tmp/script.sh")) == nil)
  }

  @Test("Collapsed panel uses a tiny frame across placements and negative display coordinates")
  func collapsedFrame() {
    let screen = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
    for placement in [QueueWindowPlacement.upperLeft, .upperRight, .center] {
      let frame = CollapsedQueueGeometry.frame(visibleFrame: screen, placement: placement)
      #expect(frame.size == CGSize(width: 52, height: 44))
      #expect(screen.contains(frame))
      if placement == .upperRight { #expect(frame.maxX == screen.maxX - 12) }
      if placement == .upperLeft { #expect(frame.minX == screen.minX + 12) }
      if placement == .center { #expect(frame.midX == screen.midX && frame.midY == screen.midY) }
    }
  }

  @Test("Top-task mode stays compact and anchored across placements")
  func topTaskFrame() {
    let screen = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
    for placement in [QueueWindowPlacement.upperLeft, .upperRight, .center] {
      let frame = TopTaskQueueGeometry.frame(
        preferredWidth: 440,
        visibleFrame: screen,
        placement: placement
      )
      #expect(frame.size == CGSize(width: 440, height: 238))
      #expect(screen.contains(frame))
      if placement == .upperRight { #expect(frame.maxX == screen.maxX - 12) }
      if placement == .upperLeft { #expect(frame.minX == screen.minX + 12) }
      if placement == .center { #expect(frame.midX == screen.midX && frame.midY == screen.midY) }
    }
    #expect(TopTaskQueueGeometry.size(preferredWidth: 200).width == 400)
    #expect(TopTaskQueueGeometry.size(preferredWidth: 900).width == 620)
  }
}
