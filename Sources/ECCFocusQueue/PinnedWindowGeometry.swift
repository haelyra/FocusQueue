import Foundation

/// Keeps the top-left window anchor when content changes, clamping only enough
/// to keep the window reachable after a display or size change.
enum PinnedWindowGeometry {
  static func frame(current: CGRect, size: CGSize, visibleFrame: CGRect) -> CGRect {
    let width = min(size.width, visibleFrame.width)
    let height = min(size.height, visibleFrame.height)
    return CGRect(
      x: min(max(current.minX, visibleFrame.minX), visibleFrame.maxX - width),
      y: min(max(current.maxY - height, visibleFrame.minY), visibleFrame.maxY - height),
      width: width, height: height)
  }
}
