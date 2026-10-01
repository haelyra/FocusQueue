import Foundation
import SwiftUI

enum ChatMarkdownBlock: Equatable {
  case paragraph(String)
  case heading(Int, String)
  case bullet(String)
  case numbered(String, String)
  case quote(String)
  case code(String?, String)
  case rule
}

enum ChatMarkdown {
  static func blocks(in markdown: String) -> [ChatMarkdownBlock] {
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    var blocks: [ChatMarkdownBlock] = []
    var index = 0
    while index < lines.count {
      let line = lines[index].trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { index += 1; continue }

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
          code.append(lines[index])
          index += 1
        }
        blocks.append(.code(fence.language, code.joined(separator: "\n")))
        continue
      }
      if let heading = heading(in: line) {
        blocks.append(.heading(heading.level, heading.text)); index += 1; continue
      }
      if isRule(line) { blocks.append(.rule); index += 1; continue }
      if let text = bullet(in: line) { blocks.append(.bullet(text)); index += 1; continue }
      if let numbered = numbered(in: line) {
        blocks.append(.numbered(numbered.number, numbered.text)); index += 1; continue
      }
      if line.hasPrefix(">") {
        var quoted: [String] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          guard candidate.hasPrefix(">") else { break }
          quoted.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
          index += 1
        }
        blocks.append(.quote(quoted.joined(separator: "\n")))
        continue
      }

      var paragraph = [line]
      index += 1
      while index < lines.count {
        let next = lines[index].trimmingCharacters(in: .whitespaces)
        guard !next.isEmpty, !startsBlock(next) else { break }
        paragraph.append(next)
        index += 1
      }
      blocks.append(.paragraph(paragraph.joined(separator: " ")))
    }
    return blocks
  }

  static func inline(_ markdown: String) -> AttributedString {
    var rendered = (try? AttributedString(markdown: markdown, options: .init(
      interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    let codeRanges = rendered.runs.compactMap { run in
      run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
    }
    for range in codeRanges {
      rendered[range].font = .system(size: 12, design: .monospaced)
      rendered[range].backgroundColor = Color.primary.opacity(0.08)
    }
    return rendered
  }

  private static func startsBlock(_ line: String) -> Bool {
    fence(in: line) != nil || heading(in: line) != nil || isRule(line)
      || bullet(in: line) != nil || numbered(in: line) != nil || line.hasPrefix(">")
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
    return (count, String(line.dropFirst(count + 1)))
  }

  private static func bullet(in line: String) -> String? {
    guard line.count >= 2, ["-", "*", "+"].contains(String(line.prefix(1))),
          line.dropFirst().first == " " else { return nil }
    return String(line.dropFirst(2))
  }

  private static func numbered(in line: String) -> (number: String, text: String)? {
    let digits = line.prefix(while: { $0.isNumber })
    guard !digits.isEmpty else { return nil }
    let suffix = line.dropFirst(digits.count)
    guard suffix.first == "." || suffix.first == ")", suffix.dropFirst().first == " " else { return nil }
    return (String(digits) + ".", String(suffix.dropFirst(2)))
  }

  private static func isRule(_ line: String) -> Bool {
    let compact = line.filter { !$0.isWhitespace }
    guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(String(first)) else { return false }
    return compact.allSatisfy { $0 == first }
  }
}

struct ChatMarkdownView: View {
  let blocks: [ChatMarkdownBlock]
  @Environment(\.colorScheme) private var colorScheme

  init(_ markdown: String) { blocks = ChatMarkdown.blocks(in: markdown) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }

  @ViewBuilder private func blockView(_ block: ChatMarkdownBlock) -> some View {
    switch block {
    case .paragraph(let text):
      Text(ChatMarkdown.inline(text)).font(.system(size: 13, weight: .light))
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    case .heading(let level, let text):
      Text(ChatMarkdown.inline(text))
        .font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 13, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
    case .bullet(let text):
      listRow(marker: "•", text: text)
    case .numbered(let number, let text):
      listRow(marker: number, text: text)
    case .quote(let text):
      HStack(alignment: .top, spacing: 10) {
        Rectangle().fill(Color.accentColor.opacity(0.65)).frame(width: 2)
        Text(ChatMarkdown.inline(text)).font(.system(size: 13, weight: .light))
          .lineSpacing(3)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, 3)
    case .code(let language, let code):
      VStack(alignment: .leading, spacing: 0) {
        if let language {
          Text(language.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 9)
        }
        Text(code)
          .font(.system(size: 11.5, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .background(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055),
        in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.11), lineWidth: 1))
    case .rule:
      Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1)
    }
  }

  private func listRow(marker: String, text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(marker).foregroundStyle(.secondary).frame(minWidth: 15, alignment: .trailing)
      Text(ChatMarkdown.inline(text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
    .font(.system(size: 13, weight: .light))
  }
}
