import AppKit
import FocusQueueCore
import SwiftUI

/// Monochrome provider marks: the Claude Code pixel mascot, the Codex terminal
/// cloud, and the Kimi "K". Paths come from the MIT-licensed LobeHub icon set
/// (24-unit viewBox, y down) with arcs pre-flattened to cubic curves, so only
/// `M L C Z` appear. Images are templates and take the surrounding foreground
/// color: white on the dark theme, dark on the light theme.
@MainActor
enum ProviderLogo {
  static func pathData(for provider: AgentProvider) -> String {
    ProviderMark.path(for: provider)
  }

  /// Parses the `M L C Z` subset in absolute coordinates.
  static func path(for provider: AgentProvider) -> NSBezierPath {
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    let tokens = pathData(for: provider).split(whereSeparator: \.isWhitespace)
    var index = tokens.startIndex
    func point() -> NSPoint {
      defer { index += 2 }
      return NSPoint(x: Double(tokens[index])!, y: Double(tokens[index + 1])!)
    }
    while index < tokens.endIndex {
      let command = tokens[index]
      index += 1
      switch command {
      case "M": path.move(to: point())
      case "L": path.line(to: point())
      case "C":
        let first = point(), second = point()
        path.curve(to: point(), controlPoint1: first, controlPoint2: second)
      default: path.close()
      }
    }
    return path
  }

  private static var cache: [String: NSImage] = [:]

  /// Wide marks (the Claude mascot) may grow this much past the box width so
  /// they read at the same optical weight as square marks.
  static let maxWidthRatio: CGFloat = 1.25

  /// A template image `size` points tall with the mark scaled to fit and
  /// centered, so marks of different proportions share one visual box.
  static func image(for provider: AgentProvider, size: CGFloat) -> NSImage {
    let key = "\(provider.rawValue)-\(size)"
    if let cached = cache[key] { return cached }
    let mark = path(for: provider)
    let bounds = mark.bounds
    let scale = min(size * maxWidthRatio / bounds.width, size / bounds.height)
    let width = max(size, (bounds.width * scale).rounded(.up))
    let image = NSImage(size: NSSize(width: width, height: size), flipped: true) { _ in
      var transform = AffineTransform(translationByX: -bounds.midX, byY: -bounds.midY)
      transform.append(AffineTransform(scaleByX: scale, byY: scale))
      transform.append(AffineTransform(translationByX: width / 2, byY: size / 2))
      let placed = mark.copy() as! NSBezierPath
      placed.transform(using: transform)
      NSColor.black.setFill()
      placed.fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = provider.displayName
    cache[key] = image
    return image
  }
}

@MainActor
extension AgentProvider {
  /// The provider's brand mark, tinted by the current foreground style.
  func iconImage(size: CGFloat = 12) -> Image {
    Image(nsImage: ProviderLogo.image(for: self, size: size))
  }

  func label(size: CGFloat = 12) -> some View {
    Label { Text(displayName) } icon: { iconImage(size: size) }
  }
}
