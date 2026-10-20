import AppKit
import Foundation
import SwiftUI

enum ChatTableAlignment: Equatable {
  case leading, center, trailing
}

indirect enum ChatMarkdownBlock: Equatable {
  case paragraph(String)
  case heading(Int, String)
  case bullet(String, level: Int = 0)
  case numbered(String, String, level: Int = 0)
  case task(Bool, String, level: Int = 0)
  case quote([ChatMarkdownBlock])
  case code(String?, String)
  case table(header: [String], alignments: [ChatTableAlignment], rows: [[String]])
  case rule
}

enum ChatMarkdown {
  /// Hard line breaks inside a paragraph survive as this marker until rendering.
  static let lineBreak = "\n"

  static func blocks(in markdown: String) -> [ChatMarkdownBlock] {
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    var blocks: [ChatMarkdownBlock] = []
    var listIndents: [Int] = []
    var index = 0
    while index < lines.count {
      let raw = lines[index]
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { index += 1; continue }
      let indent = indentation(of: raw)

      if let fence = fence(in: line) {
        index += 1
        var code: [String] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          if candidate.hasPrefix(fence.marker),
             candidate.dropFirst(fence.marker.count).trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
            break
          }
          code.append(dropIndentation(lines[index], upTo: indent))
          index += 1
        }
        blocks.append(.code(fence.language, code.joined(separator: "\n")))
        continue
      }
      if let heading = heading(in: line) {
        listIndents = []
        blocks.append(.heading(heading.level, heading.text)); index += 1; continue
      }
      if isRule(line) { listIndents = []; blocks.append(.rule); index += 1; continue }
      if index + 1 < lines.count, line.contains("|"),
         let alignments = tableDelimiter(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
        listIndents = []
        let header = tableCells(in: line)
        index += 2
        var rows: [[String]] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          guard !candidate.isEmpty, candidate.contains("|") else { break }
          rows.append(tableCells(in: candidate))
          index += 1
        }
        let width = max(header.count, alignments.count, rows.map(\.count).max() ?? 0)
        func pad<T>(_ values: [T], _ filler: T) -> [T] {
          Array(values.prefix(width)) + Array(repeating: filler, count: max(0, width - values.count))
        }
        blocks.append(.table(
          header: pad(header, ""), alignments: pad(alignments, .leading), rows: rows.map { pad($0, "") }))
        continue
      }
      if let item = listItem(in: line) {
        let level = listLevel(for: indent, in: &listIndents)
        var text = [item.text]
        index += 1
        while index < lines.count {
          let next = lines[index].trimmingCharacters(in: .whitespaces)
          guard !next.isEmpty, !startsBlock(next, following: lines, at: index) else { break }
          text.append(next)
          index += 1
        }
        let joined = joinParagraph(text, raw: lines[(index - text.count)..<index].map { $0 })
        switch item.kind {
        case .bullet: blocks.append(.bullet(joined, level: level))
        case .numbered(let number): blocks.append(.numbered(number, joined, level: level))
        case .task(let done): blocks.append(.task(done, joined, level: level))
        }
        continue
      }
      listIndents = []
      if line.hasPrefix(">") {
        var quoted: [String] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          guard candidate.hasPrefix(">") else { break }
          var content = candidate.dropFirst()
          if content.first == " " { content = content.dropFirst() }
          quoted.append(String(content))
          index += 1
        }
        blocks.append(.quote(self.blocks(in: quoted.joined(separator: "\n"))))
        continue
      }

      let start = index
      var paragraph = [line]
      index += 1
      while index < lines.count {
        let next = lines[index].trimmingCharacters(in: .whitespaces)
        guard !next.isEmpty, !startsBlock(next, following: lines, at: index) else { break }
        paragraph.append(next)
        index += 1
      }
      blocks.append(.paragraph(joinParagraph(paragraph, raw: Array(lines[start..<index]))))
    }
    return blocks
  }

  /// Joins soft-wrapped lines with spaces and keeps Markdown hard breaks
  /// (two trailing spaces or a trailing backslash) as line breaks.
  private static func joinParagraph(_ trimmed: [String], raw: [String]) -> String {
    var result = ""
    for (offset, line) in trimmed.enumerated() {
      var text = line
      let original = offset < raw.count ? raw[offset] : line
      let isLast = offset == trimmed.count - 1
      var hardBreak = false
      if !isLast, original.hasSuffix("  ") { hardBreak = true }
      if !isLast, text.hasSuffix("\\") { hardBreak = true; text.removeLast() }
      result += text
      if !isLast { result += hardBreak ? lineBreak : " " }
    }
    return result
  }

  static func inline(_ markdown: String) -> AttributedString {
    (try? AttributedString(markdown: markdown, options: .init(
      interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
  }

  private enum ListKind { case bullet, numbered(String), task(Bool) }

  private static func listItem(in line: String) -> (kind: ListKind, text: String)? {
    if let text = bullet(in: line) {
      let lowered = text.lowercased()
      if lowered.hasPrefix("[ ] ") || lowered == "[ ]" {
        return (.task(false), String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces))
      }
      if lowered.hasPrefix("[x] ") || lowered == "[x]" {
        return (.task(true), String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces))
      }
      return (.bullet, text)
    }
    if let numbered = numbered(in: line) { return (.numbered(numbered.number), numbered.text) }
    return nil
  }

  /// Maps a list item's indentation onto a nesting level. Siblings share an
  /// indentation; any deeper indentation opens one more level.
  private static func listLevel(for indent: Int, in stack: inout [Int]) -> Int {
    while let last = stack.last, last > indent { stack.removeLast() }
    if stack.last != indent { stack.append(indent) }
    return min(stack.count - 1, 6)
  }

  private static func indentation(of line: String) -> Int {
    var width = 0
    for character in line {
      if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
    }
    return width
  }

  private static func dropIndentation(_ line: String, upTo width: Int) -> String {
    var remaining = width
    var result = Substring(line)
    while remaining > 0, let first = result.first, first == " " || first == "\t" {
      remaining -= first == "\t" ? 4 : 1
      result = result.dropFirst()
    }
    return String(result)
  }

  private static func startsBlock(_ line: String, following lines: [String], at index: Int) -> Bool {
    if fence(in: line) != nil || heading(in: line) != nil || isRule(line)
      || bullet(in: line) != nil || numbered(in: line) != nil || line.hasPrefix(">") {
      return true
    }
    return line.contains("|") && index + 1 < lines.count
      && tableDelimiter(lines[index + 1].trimmingCharacters(in: .whitespaces)) != nil
  }

  private static func fence(in line: String) -> (marker: String, language: String?)? {
    guard let first = line.first, first == "`" || first == "~" else { return nil }
    let count = line.prefix(while: { $0 == first }).count
    guard count >= 3 else { return nil }
    let language = line.dropFirst(count).trimmingCharacters(in: .whitespaces)
    return (String(repeating: first, count: count), language.isEmpty ? nil : language)
  }

  private static func heading(in line: String) -> (level: Int, text: String)? {
    let count = line.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
    var text = line.dropFirst(count + 1).trimmingCharacters(in: .whitespaces)
    // Optional closing sequence: "## Title ##".
    if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
    return (count, text)
  }

  private static func bullet(in line: String) -> String? {
    guard line.count >= 2, ["-", "*", "+"].contains(String(line.prefix(1))),
          line.dropFirst().first == " " else { return nil }
    return String(line.dropFirst(2))
  }

  private static func numbered(in line: String) -> (number: String, text: String)? {
    let digits = line.prefix(while: { $0.isNumber })
    guard !digits.isEmpty, digits.count <= 9 else { return nil }
    let suffix = line.dropFirst(digits.count)
    guard suffix.first == "." || suffix.first == ")", suffix.dropFirst().first == " " else { return nil }
    return (String(digits) + ".", String(suffix.dropFirst(2)))
  }

  private static func isRule(_ line: String) -> Bool {
    let compact = line.filter { !$0.isWhitespace }
    guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(String(first)) else { return false }
    return compact.allSatisfy { $0 == first }
  }

  private static func tableDelimiter(_ line: String) -> [ChatTableAlignment]? {
    guard line.contains("-") else { return nil }
    let cells = tableCells(in: line)
    guard !cells.isEmpty, line.contains("|") || cells.count > 1 else { return nil }
    var alignments: [ChatTableAlignment] = []
    for cell in cells {
      let leading = cell.hasPrefix(":"), trailing = cell.hasSuffix(":")
      let dashes = cell.drop(while: { $0 == ":" }).reversed().drop(while: { $0 == ":" })
      guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
      alignments.append(leading && trailing ? .center : trailing ? .trailing : .leading)
    }
    return alignments
  }

  /// Splits a table row on pipes that are neither escaped nor inside code spans.
  private static func tableCells(in line: String) -> [String] {
    var row = Substring(line)
    if row.hasPrefix("|") { row = row.dropFirst() }
    if row.hasSuffix("|"), !row.hasSuffix("\\|") { row = row.dropLast() }
    var cells: [String] = []
    var current = ""
    var inCode = false
    var escaped = false
    for character in row {
      if escaped {
        current += character == "|" ? "|" : "\\\(character)"
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "`" {
        inCode.toggle(); current.append(character)
      } else if character == "|", !inCode {
        cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""
      } else {
        current.append(character)
      }
    }
    if escaped { current += "\\" }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    return cells
  }
}

// MARK: - Attributed rendering

/// Renders parsed blocks into one attributed string so a single text view can
/// select and copy across paragraphs, lists, tables, and code.
enum ChatMarkdownRenderer {
  static let bodySize: CGFloat = 13
  static let blockSpacing: CGFloat = 10
  static let listIndent: CGFloat = 20

  static func attributedString(for markdown: String) -> NSAttributedString {
    attributedString(for: ChatMarkdown.blocks(in: markdown))
  }

  static func attributedString(for blocks: [ChatMarkdownBlock]) -> NSAttributedString {
    let output = NSMutableAttributedString()
    append(blocks, to: output, containers: [], isFirst: true)
    // A trailing newline adds an empty line fragment below the last block.
    if output.string.hasSuffix("\n") {
      output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
    }
    return output
  }

  private static func append(
    _ blocks: [ChatMarkdownBlock], to output: NSMutableAttributedString,
    containers: [NSTextBlock], isFirst: Bool
  ) {
    var previous: ChatMarkdownBlock?
    for (offset, block) in blocks.enumerated() {
      var spacing = isFirst && offset == 0 ? 0 : blockSpacing
      if let previous, isListItem(previous), isListItem(block) { spacing = 4 }
      append(block, to: output, containers: containers, spacingBefore: spacing)
      previous = block
    }
  }

  private static func isListItem(_ block: ChatMarkdownBlock) -> Bool {
    switch block {
    case .bullet, .numbered, .task: true
    default: false
    }
  }

  private static func paragraphStyle(
    containers: [NSTextBlock], spacingBefore: CGFloat, lineSpacing: CGFloat = 3
  ) -> NSMutableParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = lineSpacing
    style.paragraphSpacingBefore = spacingBefore
    style.textBlocks = containers
    return style
  }

  private static func append(
    _ block: ChatMarkdownBlock, to output: NSMutableAttributedString,
    containers: [NSTextBlock], spacingBefore: CGFloat
  ) {
    let body = NSFont.systemFont(ofSize: bodySize, weight: .light)
    switch block {
    case .paragraph(let text):
      let style = paragraphStyle(containers: containers, spacingBefore: spacingBefore)
      appendLine(inline(text, font: body), style: style, to: output)

    case .heading(let level, let text):
      let size: CGFloat = level == 1 ? 17 : level == 2 ? 15 : 13
      let style = paragraphStyle(
        containers: containers, spacingBefore: spacingBefore == 0 ? 0 : spacingBefore + 4)
      appendLine(inline(text, font: .systemFont(ofSize: size, weight: .semibold)), style: style, to: output)

    case .bullet(let text, let level):
      appendListItem(marker: level % 2 == 0 ? "•" : "◦", text: text, level: level,
        containers: containers, spacingBefore: spacingBefore, to: output)
    case .numbered(let number, let text, let level):
      appendListItem(marker: number, text: text, level: level,
        containers: containers, spacingBefore: spacingBefore, to: output)
    case .task(let done, let text, let level):
      appendListItem(marker: done ? "☑" : "☐", text: text, level: level,
        containers: containers, spacingBefore: spacingBefore, to: output, struck: done)

    case .quote(let nested):
      let quote = NSTextBlock()
      quote.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
      quote.setBorderColor(NSColor.controlAccentColor.withAlphaComponent(0.65), for: .minX)
      quote.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
      quote.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
      quote.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
      quote.setValue(100, type: .percentageValueType, for: .width)
      quote.setWidth(spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
      let start = output.length
      append(nested, to: output, containers: containers + [quote], isFirst: true)
      output.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
        range: NSRange(location: start, length: output.length - start))

    case .code(let language, let code):
      let container = NSTextBlock()
      container.backgroundColor = codeBackground
      container.setBorderColor(NSColor.separatorColor)
      container.setWidth(1, type: .absoluteValueType, for: .border)
      container.setWidth(10, type: .absoluteValueType, for: .padding)
      container.setValue(100, type: .percentageValueType, for: .width)
      // A filled block also paints its margin, so a clear outer block holds the spacing.
      let spacer = NSTextBlock()
      spacer.setValue(100, type: .percentageValueType, for: .width)
      spacer.setWidth(spacingBefore, type: .absoluteValueType, for: .padding, edge: .minY)
      let blocks = containers + [spacer, container]
      if let language {
        let style = paragraphStyle(containers: blocks, spacingBefore: 0, lineSpacing: 0)
        style.paragraphSpacing = 4
        appendLine(NSAttributedString(string: language.uppercased(), attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
          .foregroundColor: NSColor.secondaryLabelColor,
        ]), style: style, to: output)
      }
      let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
      for line in code.components(separatedBy: "\n") {
        let style = paragraphStyle(containers: blocks, spacingBefore: 0, lineSpacing: 1)
        style.lineBreakMode = .byCharWrapping
        appendLine(NSAttributedString(string: line, attributes: [
          .font: mono, .foregroundColor: NSColor.labelColor,
        ]), style: style, to: output)
      }

    case .table(let header, let alignments, let rows):
      let table = NSTextTable()
      table.numberOfColumns = header.count
      table.layoutAlgorithm = .automaticLayoutAlgorithm
      table.collapsesBorders = true
      table.hidesEmptyCells = false
      table.setValue(100, type: .percentageValueType, for: .width)
      table.setWidth(spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
      let shares = columnShares(header: header, rows: rows)
      for (rowIndex, cells) in ([header] + rows).enumerated() {
        for (column, cell) in cells.enumerated() {
          let cellBlock = NSTextTableBlock(
            table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
          cellBlock.setBorderColor(NSColor.separatorColor)
          cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
          cellBlock.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minX)
          cellBlock.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxX)
          cellBlock.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
          cellBlock.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
          if rowIndex == 0 { cellBlock.backgroundColor = codeBackground }
          cellBlock.setValue(shares[column], type: .percentageValueType, for: .width)
          let style = paragraphStyle(
            containers: containers + [cellBlock], spacingBefore: 0, lineSpacing: 1)
          switch column < alignments.count ? alignments[column] : .leading {
          case .leading: style.alignment = .natural
          case .center: style.alignment = .center
          case .trailing: style.alignment = .right
          }
          let font = rowIndex == 0 ? NSFont.systemFont(ofSize: 12, weight: .semibold)
            : NSFont.systemFont(ofSize: 12, weight: .light)
          appendLine(inline(cell, font: font), style: style, to: output)
        }
      }

    case .rule:
      let rule = NSTextBlock()
      rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
      rule.setBorderColor(NSColor.separatorColor, for: .minY)
      rule.setValue(100, type: .percentageValueType, for: .width)
      rule.setWidth(spacingBefore + 4, type: .absoluteValueType, for: .margin, edge: .minY)
      rule.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
      let style = paragraphStyle(containers: containers + [rule], spacingBefore: 0, lineSpacing: 0)
      style.minimumLineHeight = 1
      style.maximumLineHeight = 1
      appendLine(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 1)]),
        style: style, to: output)
    }
  }

  /// Splits the table width by each column's natural content width, so short
  /// columns such as "#" stay narrow and long text columns wrap less.
  private static func columnShares(header: [String], rows: [[String]]) -> [CGFloat] {
    let bold = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let light = NSFont.systemFont(ofSize: 12, weight: .light)
    let natural = header.indices.map { column -> CGFloat in
      let widths = [inline(header[column], font: bold).size().width]
        + rows.map { column < $0.count ? inline($0[column], font: light).size().width : 0 }
      return min(max(widths.max() ?? 0, 18), 320) + 14
    }
    let total = natural.reduce(0, +)
    // Percentages measure content only; leave room for cell padding and borders.
    return natural.map { total > 0 ? $0 / total * 88 : 88 / CGFloat(max(natural.count, 1)) }
  }

  private static func appendListItem(
    marker: String, text: String, level: Int, containers: [NSTextBlock],
    spacingBefore: CGFloat, to output: NSMutableAttributedString, struck: Bool = false
  ) {
    let body = NSFont.systemFont(ofSize: bodySize, weight: .light)
    let markerWidth: CGFloat = marker.count > 2 ? 28 : listIndent
    let leading = CGFloat(level) * listIndent
    let style = paragraphStyle(containers: containers, spacingBefore: spacingBefore)
    style.firstLineHeadIndent = leading
    style.headIndent = leading + markerWidth
    style.tabStops = [NSTextTab(textAlignment: .left, location: leading + markerWidth)]
    style.defaultTabInterval = listIndent
    let line = NSMutableAttributedString(string: "\(marker)\t", attributes: [
      .font: body, .foregroundColor: NSColor.secondaryLabelColor,
    ])
    let content = NSMutableAttributedString(attributedString: inline(text, font: body))
    if struck {
      content.addAttributes([
        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        .foregroundColor: NSColor.secondaryLabelColor,
      ], range: NSRange(location: 0, length: content.length))
    }
    line.append(content)
    appendLine(line, style: style, to: output)
  }

  private static func appendLine(
    _ line: NSAttributedString, style: NSParagraphStyle, to output: NSMutableAttributedString
  ) {
    let start = output.length
    output.append(line)
    output.append(NSAttributedString(string: "\n"))
    output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
  }

  static let codeBackground = NSColor(name: nil) { appearance in
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return NSColor.labelColor.withAlphaComponent(dark ? 0.09 : 0.055)
  }

  /// Converts inline Markdown (emphasis, code, links, strikethrough) to AppKit attributes.
  static func inline(_ markdown: String, font base: NSFont) -> NSAttributedString {
    let output = NSMutableAttributedString()
    // Hard breaks become line separators so the paragraph keeps one style.
    let segments = markdown.components(separatedBy: ChatMarkdown.lineBreak)
    for (index, segment) in segments.enumerated() {
      if index > 0 {
        output.append(NSAttributedString(string: "\u{2028}", attributes: [
          .font: base, .foregroundColor: NSColor.labelColor,
        ]))
      }
      let parsed = ChatMarkdown.inline(segment)
      for run in parsed.runs {
        let text = String(parsed[run.range].characters)
        let intent = run.inlinePresentationIntent ?? []
        var font = base
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
        if intent.contains(.code) {
          font = .monospacedSystemFont(ofSize: max(base.pointSize - 1, 9), weight: .regular)
          attributes[.chatInlineCode] = true
        } else {
          var traits: NSFontDescriptor.SymbolicTraits = []
          if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
          if intent.contains(.emphasized) { traits.insert(.italic) }
          if !traits.isEmpty {
            if traits.contains(.bold) {
              font = .systemFont(ofSize: base.pointSize, weight: .semibold)
            }
            if traits.contains(.italic) {
              let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
              font = NSFont(descriptor: descriptor, size: base.pointSize) ?? font
            }
          }
        }
        if intent.contains(.strikethrough) {
          attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link {
          attributes[.link] = link
        }
        attributes[.font] = font
        output.append(NSAttributedString(string: text, attributes: attributes))
      }
    }
    return output
  }
}

extension NSAttributedString.Key {
  static let chatInlineCode = NSAttributedString.Key("ChatInlineCode")
}

// MARK: - View

/// Draws inline code backgrounds tightly around the glyphs on each line.
/// The standard background attribute fills to the margins when a code span wraps.
final class ChatMarkdownLayoutManager: NSLayoutManager {
  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    guard let textStorage, let container = textContainers.first else { return }
    let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    textStorage.enumerateAttribute(.chatInlineCode, in: characters) { value, range, _ in
      guard value != nil else { return }
      let codeGlyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      ChatMarkdownRenderer.codeBackground.setFill()
      enumerateLineFragments(forGlyphRange: codeGlyphs) { _, _, _, lineGlyphs, _ in
        let overlap = NSIntersectionRange(lineGlyphs, codeGlyphs)
        guard overlap.length > 0 else { return }
        var rect = self.boundingRect(forGlyphRange: overlap, in: container)
        rect = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 0.5)
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
      }
    }
  }
}

/// A read-only TextKit 1 text view. TextKit 1 lays out NSTextTable and
/// NSTextBlock natively; TextKit 2 would fall back to it anyway.
final class ChatMarkdownNSTextView: NSTextView {
  private var measuredWidth: CGFloat = -1
  private var measuredHeight: CGFloat = 0

  /// The layout manager references its storage weakly, so the view keeps it alive.
  private let contentStorage: NSTextStorage

  convenience init() {
    let storage = NSTextStorage()
    let layoutManager = ChatMarkdownLayoutManager()
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(size: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = false
    container.lineFragmentPadding = 0
    layoutManager.addTextContainer(container)
    self.init(frame: .zero, textContainer: container)
  }

  override init(frame: NSRect, textContainer: NSTextContainer?) {
    contentStorage = textContainer?.layoutManager?.textStorage ?? NSTextStorage()
    super.init(frame: frame, textContainer: textContainer)
    isEditable = false
    isSelectable = true
    isRichText = true
    drawsBackground = false
    textContainerInset = .zero
    isVerticallyResizable = false
    isHorizontallyResizable = false
    usesFindBar = false
    linkTextAttributes = [
      .foregroundColor: NSColor.linkColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
      .cursor: NSCursor.pointingHand,
    ]
    setAccessibilityRole(.textArea)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private(set) var markdown: String?

  func setMarkdown(_ markdown: String) {
    guard markdown != self.markdown, let textStorage else { return }
    self.markdown = markdown
    textStorage.setAttributedString(ChatMarkdownRenderer.attributedString(for: markdown))
    measuredWidth = -1
  }

  func fittingHeight(for width: CGFloat) -> CGFloat {
    guard let layoutManager, let textContainer else { return 0 }
    if width == measuredWidth { return measuredHeight }
    // Text blocks and tables size against the view frame, so measure at the
    // proposed width rather than the frame SwiftUI has not assigned yet.
    if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
    textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    layoutManager.invalidateLayout(
      forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0), actualCharacterRange: nil)
    layoutManager.ensureLayout(for: textContainer)
    measuredWidth = width
    measuredHeight = ceil(layoutManager.usedRect(for: textContainer).height)
    return measuredHeight
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if textContainer?.containerSize.width != newSize.width {
      textContainer?.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
    }
  }

}

private struct ChatMarkdownTextView: NSViewRepresentable {
  let markdown: String

  func makeNSView(context: Context) -> ChatMarkdownNSTextView {
    let view = ChatMarkdownNSTextView()
    view.setMarkdown(markdown)
    return view
  }

  func updateNSView(_ nsView: ChatMarkdownNSTextView, context: Context) {
    nsView.setMarkdown(markdown)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: ChatMarkdownNSTextView, context: Context
  ) -> CGSize? {
    var width = proposal.width ?? 320
    if !width.isFinite || width <= 0 { width = 320 }
    return CGSize(width: width, height: nsView.fittingHeight(for: width))
  }
}

/// One selectable text view per message, so a drag can select and copy
/// several lines, list items, table cells, or code lines at once.
struct ChatMarkdownView: View {
  let markdown: String

  init(_ markdown: String) { self.markdown = markdown }

  var body: some View {
    ChatMarkdownTextView(markdown: markdown)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
