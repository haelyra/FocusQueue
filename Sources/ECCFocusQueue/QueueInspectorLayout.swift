import FocusQueueCore
import Foundation

/// Shared window constraints keep the document and conversation side by side.
/// Narrow displays can scroll the inspector horizontally without hiding a pane.
struct QueueInspectorLayout: Equatable {
  let minimumWidth: CGFloat
  let maximumWidth: CGFloat
  let expansionWidth: CGFloat

  static let closed = Self(minimumWidth: 400, maximumWidth: 620, expansionWidth: 0)
  static let chat = Self(minimumWidth: 790, maximumWidth: 1_200, expansionWidth: 580)
  static let report = Self(minimumWidth: 790, maximumWidth: 1_200, expansionWidth: 580)
  static let analytics = Self(minimumWidth: 1_120, maximumWidth: 1_680, expansionWidth: 800)
  static let plan = Self(minimumWidth: 1_260, maximumWidth: 2_200, expansionWidth: 1_360)
  static let documentMinimumWidth: CGFloat = 500
  static let chatMinimumWidth: CGFloat = 240
  static let documentPairMinimumWidth: CGFloat = 1_040
  static let inspectorMinimumWidth = documentMinimumWidth + chatMinimumWidth + 12

  func preferredWidth(compactWidth: CGFloat) -> CGFloat {
    min(maximumWidth, max(minimumWidth, compactWidth + expansionWidth))
  }
}

/// The collapsed control and NSPanel share exactly the same bounds.
enum CollapsedQueueGeometry {
  static let size = CGSize(width: 52, height: 44)

  static func frame(visibleFrame: CGRect, placement: QueueWindowPlacement) -> CGRect {
    let x: CGFloat
    switch placement {
    case .upperLeft: x = visibleFrame.minX + 12
    case .upperRight: x = visibleFrame.maxX - size.width - 12
    case .center: x = visibleFrame.midX - size.width / 2
    }
    let y = placement == .center
      ? visibleFrame.midY - size.height / 2 : visibleFrame.maxY - size.height - 4
    return CGRect(x: x, y: y, width: size.width, height: size.height)
  }
}

enum TopTaskQueueGeometry {
  static let height: CGFloat = 238

  static func size(preferredWidth: CGFloat) -> CGSize {
    CGSize(width: min(max(preferredWidth, 400), 620), height: height)
  }

  static func frame(
    preferredWidth: CGFloat,
    visibleFrame: CGRect,
    placement: QueueWindowPlacement
  ) -> CGRect {
    let size = size(preferredWidth: preferredWidth)
    let x: CGFloat
    switch placement {
    case .upperLeft: x = visibleFrame.minX + 12
    case .upperRight: x = visibleFrame.maxX - size.width - 12
    case .center: x = visibleFrame.midX - size.width / 2
    }
    let y = placement == .center
      ? visibleFrame.midY - size.height / 2 : visibleFrame.maxY - size.height - 4
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }
}
