import Foundation
import Testing
@testable import ECCFocusQueue

struct QueueScrollSnapshotTests {
  @Test("Only a fresh interaction promoting an existing task follows the queue top")
  func interactionPromotion() {
    let earlier = Date(timeIntervalSinceReferenceDate: 100)
    let later = earlier.addingTimeInterval(1)
    let previous = QueueScrollSnapshot(scopeID: "project", orderedIDs: ["A", "B"],
      interactions: ["B": earlier])
    let promoted = QueueScrollSnapshot(scopeID: "project", orderedIDs: ["B", "A"],
      interactions: ["B": later])
    #expect(promoted.shouldScrollToTop(from: previous))
    // Background output or manual sorting can reorder cards without an interaction.
    #expect(!QueueScrollSnapshot(scopeID: "project", orderedIDs: ["B", "A"],
      interactions: ["B": earlier]).shouldScrollToTop(from: previous))
    #expect(!QueueScrollSnapshot(scopeID: "other", orderedIDs: ["B", "A"],
      interactions: ["B": later]).shouldScrollToTop(from: previous))
    #expect(!QueueScrollSnapshot(scopeID: "project", orderedIDs: ["A", "B"],
      interactions: ["A": later, "B": earlier]).shouldScrollToTop(from: previous))
    #expect(!QueueScrollSnapshot(scopeID: "project", orderedIDs: ["C", "A", "B"],
      interactions: ["C": later]).shouldScrollToTop(from: previous))
    #expect(!promoted.shouldScrollToTop(from:
      QueueScrollSnapshot(scopeID: "project", orderedIDs: [], interactions: [:])))
    #expect(!QueueScrollSnapshot(scopeID: "project", orderedIDs: [], interactions: [:])
      .shouldScrollToTop(from: previous))
  }
}
