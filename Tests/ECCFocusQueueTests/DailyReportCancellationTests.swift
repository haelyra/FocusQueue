import Testing

@testable import ECCFocusQueue

@Suite("Daily report cancellation")
@MainActor
struct DailyReportCancellationTests {
  @Test("The coordinator cancels the owned report task and becomes reusable")
  func coordinatorCancellation() async {
    let coordinator = DailyReportRunCoordinator()
    var observedCancellation = false
    let run = Task { @MainActor in
      await coordinator.run {
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          observedCancellation = Task.isCancelled
        }
        return nil
      }
    }

    for _ in 0..<100 where !coordinator.hasActiveRun { await Task.yield() }
    #expect(coordinator.hasActiveRun)
    coordinator.cancel()
    _ = await run.value

    #expect(observedCancellation)
    #expect(!coordinator.hasActiveRun)

    let second = await coordinator.run { nil }
    #expect(second == nil)
    #expect(!coordinator.hasActiveRun)
  }
}
