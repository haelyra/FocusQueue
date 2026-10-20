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
    switch provider {
    case .claude:
      """
      M 20.998 10.949 L 24 10.949 L 24 14.051 L 21 14.051 L 21 17.079 L 19.513 17.079 L 19.513 20 L 18
      20 L 18 17.079 L 16.513 17.079 L 16.513 20 L 15 20 L 15 17.079 L 9 17.079 L 9 20 L 7.488 20 L
      7.488 17.079 L 6 17.079 L 6 20 L 4.487 20 L 4.487 17.079 L 3 17.079 L 3 14.05 L 0 14.05 L 0
      10.95 L 3 10.95 L 3 5 L 20.998 5 L 20.998 10.949 Z M 6 10.949 L 7.488 10.949 L 7.488 8.102 L 6
      8.102 L 6 10.949 Z M 16.51 10.949 L 18 10.949 L 18 8.102 L 16.51 8.102 L 16.51 10.949 Z
      """
    case .codex:
      """
      M 8.086 0.457 C 9.049 0.061 10.098 -0.082 11.132 0.042 C 12.465 0.195 13.653 0.762 14.696 1.742
      C 14.725 1.769 14.765 1.78 14.803 1.771 C 16.211 1.425 17.565 1.547 18.864 2.137 L 18.927 2.167
      L 19.081 2.243 C 20.438 2.946 21.411 4.013 21.999 5.441 C 22.277 6.12 22.417 6.829 22.42 7.567 C
      22.44 8.117 22.379 8.666 22.24 9.198 C 22.226 9.253 22.241 9.312 22.28 9.353 C 23.066 10.15
      23.613 11.152 23.858 12.244 C 24.243 14.145 23.848 15.859 22.675 17.384 L 22.493 17.604 C 21.716
      18.494 20.696 19.137 19.559 19.455 C 19.509 19.47 19.468 19.508 19.451 19.557 C 19.196 20.293
      18.94 20.921 18.464 21.549 C 17.265 23.131 15.502 24.011 13.516 24 C 11.933 23.992 10.53 23.413
      9.306 22.264 C 9.268 22.229 9.215 22.217 9.166 22.232 C 8.648 22.399 8.126 22.423 7.562 22.417 C
      6.661 22.41 5.773 22.197 4.967 21.795 C 4.123 21.376 3.388 20.766 2.821 20.014 C 2.618 19.745
      2.417 19.492 2.27 19.193 C 2.067 18.781 1.902 18.352 1.775 17.91 C 1.509 16.907 1.503 15.852
      1.758 14.846 C 1.766 14.822 1.769 14.797 1.766 14.772 C 1.761 14.747 1.748 14.725 1.729 14.708 C
      1.113 14.084 0.641 13.333 0.349 12.506 C 0.155 11.997 0.043 11.461 0.016 10.917 C -0.032 10.201
      0.031 9.482 0.204 8.785 C 0.654 7.301 1.513 6.137 2.781 5.292 C 3.063 5.104 3.331 4.958 3.583
      4.854 C 3.869 4.734 4.156 4.634 4.444 4.55 C 4.486 4.538 4.519 4.505 4.531 4.463 C 4.749 3.678
      5.125 2.945 5.635 2.31 C 6.315 1.464 7.132 0.846 8.086 0.457 Z M 7.282 8.307 C 7.049 7.9 6.531
      7.759 6.125 7.992 C 5.718 8.224 5.576 8.742 5.809 9.149 L 7.503 12.114 L 5.815 14.962 C 5.6
      15.363 5.739 15.862 6.131 16.094 C 6.522 16.326 7.027 16.207 7.275 15.826 L 9.215 12.554 C 9.371
      12.291 9.373 11.965 9.222 11.7 L 7.282 8.307 Z M 12.728 14.547 C 12.279 14.574 11.929 14.945
      11.929 15.395 C 11.929 15.844 12.279 16.215 12.728 16.242 L 17.576 16.242 C 18.028 16.22 18.384
      15.847 18.384 15.394 C 18.384 14.941 18.028 14.568 17.576 14.546 L 12.728 14.546 Z
      """
    case .kimi:
      """
      M 21.846 0 C 22.908 0 23.769 0.861 23.769 1.923 C 23.769 2.985 22.908 3.846 21.846 3.846 L 20.15
      3.846 C 20.09 3.846 20.032 3.823 19.99 3.78 C 19.947 3.738 19.923 3.68 19.923 3.62 L 19.923
      1.923 C 19.923 0.861 20.784 0 21.846 0 Z M 11.065 11.199 L 18.322 3.999 C 18.459 3.863 18.382
      3.589 18.206 3.589 L 14.3 3.589 C 14.256 3.59 14.214 3.608 14.183 3.64 L 6.363 11.396 C 6.241
      11.516 6.061 11.409 6.061 11.217 L 6.061 3.82 C 6.061 3.693 5.978 3.59 5.876 3.59 L 3.186 3.59 C
      3.083 3.59 3 3.693 3 3.82 L 3 19.77 C 3 19.898 3.083 20 3.186 20 L 5.876 20 C 5.979 20 6.062
      19.898 6.062 19.77 L 6.062 16.52 C 6.062 16.451 6.087 16.385 6.131 16.342 L 8.555 13.936 C 8.608
      13.879 8.695 13.869 8.76 13.913 L 15.244 18.685 C 16.274 19.387 17.459 19.827 18.697 19.968 C
      18.805 19.98 18.897 19.873 18.897 19.738 L 18.897 16.678 C 18.897 16.561 18.827 16.466 18.733
      16.451 C 18.006 16.334 17.314 16.058 16.706 15.644 L 11.093 11.58 C 10.976 11.502 10.961 11.301
      11.065 11.199 Z
      """
    }
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
