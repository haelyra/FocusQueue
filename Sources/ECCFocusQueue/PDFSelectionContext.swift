import AppKit
import PDFKit

/// Turns a PDFKit selection into the same select-and-type action the Markdown
/// viewer posts, located by page and position because PDFs have no selectors.
enum PDFSelectionContext {
  static let excerptLimit = 1_000
  static let surroundingLimit = 1_200
  /// Characters PDFKit adds on each side of the selection for surrounding text.
  static let surroundingReach = 280

  static func action(
    for selection: PDFSelection, in document: PDFDocument, sourceURL: URL, initialText: String
  ) -> PlanCanvasSelectionAction? {
    let excerpt = clean(selection.string ?? "", limit: excerptLimit)
    guard !excerpt.isEmpty else { return nil }
    let indices = selection.pages.map { document.index(for: $0) }.filter { $0 != NSNotFound }.sorted()
    guard let firstIndex = indices.first, let page = document.page(at: firstIndex) else { return nil }

    let surrounding = (selection.copy() as? PDFSelection).map { wider in
      wider.extend(atStart: surroundingReach)
      wider.extend(atEnd: surroundingReach)
      return clean(wider.string ?? "", limit: surroundingLimit)
    }
    let selectionModel = PlanCanvasSelection(
      kind: .pdf,
      documentPath: sourceURL.standardizedFileURL.path,
      selector: location(
        pages: firstIndex...(indices.last ?? firstIndex), pageCount: document.pageCount,
        label: page.label, selectionBounds: selection.bounds(for: page),
        pageBounds: page.bounds(for: .cropBox)),
      tag: "pdf",
      excerpt: excerpt,
      surroundingText: surrounding.flatMap { $0.count > excerpt.count ? $0 : nil },
      pageNumber: firstIndex + 1
    )
    return PlanCanvasSelectionAction(selection: selectionModel, initialText: String(initialText.prefix(1)))
  }

  /// "page 3 of 12, labeled “iv”, about 20% down the page".
  static func location(
    pages: ClosedRange<Int>, pageCount: Int, label: String?, selectionBounds: CGRect, pageBounds: CGRect
  ) -> String {
    var parts = [
      pages.count == 1
        ? "page \(pages.lowerBound + 1) of \(pageCount)"
        : "pages \(pages.lowerBound + 1)–\(pages.upperBound + 1) of \(pageCount)"
    ]
    if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
      label != String(pages.lowerBound + 1)
    {
      parts.append("labeled “\(label)”")
    }
    if pageBounds.height > 0, !selectionBounds.isEmpty {
      // PDF space puts the origin at the bottom left.
      let fromTop = (pageBounds.maxY - selectionBounds.maxY) / pageBounds.height
      parts.append("about \(Int((min(1, max(0, fromTop)) * 100).rounded()))% down the page")
    }
    return parts.joined(separator: ", ")
  }

  /// The first printable character of an unmodified key press, the key that
  /// starts a message. Space keeps scrolling the page.
  static func typedCharacter(_ event: NSEvent) -> String? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers.isDisjoint(with: [.command, .control, .option, .function]),
      let characters = event.characters, characters.count == 1,
      let scalar = characters.unicodeScalars.first,
      !CharacterSet.controlCharacters.contains(scalar),
      !CharacterSet.whitespacesAndNewlines.contains(scalar),
      !(0xF700...0xF8FF).contains(scalar.value)
    else { return nil }
    return characters
  }

  private static func clean(_ value: String, limit: Int) -> String {
    String(
      value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
  }
}
