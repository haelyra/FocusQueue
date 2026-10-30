import Foundation

/// Follows interaction-driven promotions without jumping on background output,
/// ordinary sorting, or project changes.
struct QueueScrollSnapshot: Equatable {
  let scopeID: String?
  let orderedIDs: [String]
  let interactions: [String: Date]

  func shouldScrollToTop(from previous: Self) -> Bool {
    guard scopeID == previous.scopeID,
          let firstID = orderedIDs.first,
          let previousIndex = previous.orderedIDs.firstIndex(of: firstID),
          previousIndex > 0,
          let interaction = interactions[firstID]
    else { return false }
    return interaction > (previous.interactions[firstID] ?? .distantPast)
  }
}
