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
      .quote([.paragraph("A useful note")]),
      .code("swift", "let answer = 42"),
    ])
    let inline = ChatMarkdown.inline("**Done** with `code` and [a link](https://example.com)")
    #expect(String(inline.characters) == "Done with code and a link")
    #expect(inline.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(inline.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
  }

  @Test("Tables parse alignment, escaped pipes, and pipes inside code")
  func parsesTables() {
    let reply = """
      **Plan:**

      | # | Step | State |
      |:-:|---|--:|
      | 1 | Use `a|b` here | done |
      | 2 | Escaped \\| pipe |
      """
    #expect(ChatMarkdown.blocks(in: reply) == [
      .paragraph("**Plan:**"),
      .table(
        header: ["#", "Step", "State"],
        alignments: [.center, .leading, .trailing],
        rows: [["1", "Use `a|b` here", "done"], ["2", "Escaped | pipe", ""]]),
    ])
  }

  @Test("Nested lists, task items, continuations, and hard breaks keep structure")
  func parsesNestedStructure() {
    let reply = """
      - Parent item
        continues here
        - Child item
          1. Grandchild
      - [ ] Open task
      - [x] Finished task

      Line one\\
      Line two
      ## Heading ##
      """
    #expect(ChatMarkdown.blocks(in: reply) == [
      .bullet("Parent item continues here", level: 0),
      .bullet("Child item", level: 1),
      .numbered("1.", "Grandchild", level: 2),
      .task(false, "Open task", level: 0),
      .task(true, "Finished task", level: 0),
      .paragraph("Line one\nLine two"),
      .heading(2, "Heading"),
    ])
  }

  @Test("Rendered message is one attributed string with real table cells and no Markdown markers")
  func rendersTablesAndInlineStyles() {
    let rendered = ChatMarkdownRenderer.attributedString(for: """
      ## Summary

      **Bold** and `code`.

      | Step | State |
      |---|---|
      | Build | done |
      """)
    let text = rendered.string
    #expect(!text.contains("**"))
    #expect(!text.contains("|"))
    #expect(!text.contains("##"))
    var tableCells = 0
    rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
      if let style = value as? NSParagraphStyle, style.textBlocks.contains(where: { $0 is NSTextTableBlock }) {
        tableCells += 1
      }
    }
    #expect(tableCells >= 4)
  }

  @Test("Selecting across several lines copies all of them as plain text")
  func copiesMultipleLines() {
    let textView = ChatMarkdownNSTextView()
    textView.setMarkdown("""
      First paragraph line.

      - Item one
      - Item two

      ```
      let a = 1
      let b = 2
      ```
      """)
    _ = textView.fittingHeight(for: 320)
    textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
    // A private pasteboard keeps the user's clipboard intact; the types match Edit > Copy.
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    #expect(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
    let copied = pasteboard.string(forType: .string) ?? ""
    #expect(copied.contains("First paragraph line.\n"))
    #expect(copied.contains("Item one\n"))
    #expect(copied.contains("Item two\n"))
    #expect(copied.contains("let a = 1\nlet b = 2"))
  }

  @Test("Formatted chat lays out headlessly at inspector width")
  func headlessChatLayout() {
    let view = ChatMarkdownView("""
      ## Summary

      **Done** with the change. See [details](https://example.com).

      - Clear message spacing
      - Readable code

      | A | B |
      |---|---|
      | 1 | 2 |

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
