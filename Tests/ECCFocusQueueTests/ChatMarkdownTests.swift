import AppKit
import SwiftUI
import Testing

@testable import ECCFocusQueue

@Suite("Queue chat Markdown")
@MainActor
struct ChatMarkdownTests {
  @Test("Replies parse emphasis, lists, quotes, and fenced code")
  func parsesCommonReplyFormatting() {
    let reply = """
      **Done** with the update.

      - First item
      2. Second item

      > A useful note

      ```swift
      let answer = 42
      ```
      """
    #expect(ChatMarkdown.blocks(in: reply) == [
      .paragraph("**Done** with the update."),
      .bullet("First item"),
      .numbered("2.", "Second item"),
      .quote("A useful note"),
      .code("swift", "let answer = 42"),
    ])
    let inline = ChatMarkdown.inline("**Done** with `code` and [a link](https://example.com)")
    #expect(String(inline.characters) == "Done with code and a link")
    #expect(inline.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(inline.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
  }

  @Test("Formatted chat lays out headlessly at inspector width")
  func headlessChatLayout() {
    let view = ChatMarkdownView("""
      ## Summary

      **Done** with the change. See [details](https://example.com).

      - Clear message spacing
      - Readable code

      ```swift
      print("hello")
      ```
      """)
      .frame(width: 280)
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width >= 280)
    #expect(host.fittingSize.height > 100)
  }
}
