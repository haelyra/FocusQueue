import Foundation
import Testing

@testable import ECCFocusQueue

@Suite("Program log")
@MainActor
struct ProgramLogTests {
  @Test("A new log starts empty, formats events, and clears without retaining history")
  func sessionLifecycle() {
    let store = ProgramLogStore()
    #expect(store.entries.isEmpty)

    store.record(
      "Queue loaded", category: "Lifecycle",
      timestamp: Date(timeIntervalSince1970: 1_000)
    )
    store.record(
      "Dashboard missing", level: .error, category: "Queue",
      timestamp: Date(timeIntervalSince1970: 1_001)
    )

    #expect(store.entries.map(\.message) == ["Queue loaded", "Dashboard missing"])
    #expect(store.entries.map(\.level) == [.info, .error])
    #expect(store.renderedText.contains("[ERROR] [Queue] Dashboard missing"))

    store.clear()
    #expect(store.entries.isEmpty)
    #expect(store.renderedText.isEmpty)
  }

  @Test("The live log keeps a bounded newest-event window")
  func boundedHistory() {
    let store = ProgramLogStore(capacity: 2)
    store.record("one")
    store.record("two")
    store.record("three")

    #expect(store.entries.map(\.message) == ["two", "three"])
  }
}
