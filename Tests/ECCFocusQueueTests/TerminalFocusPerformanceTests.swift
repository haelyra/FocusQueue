import CoreGraphics
import Testing

@testable import ECCFocusQueue

@Suite("Terminal focus scheduling")
struct TerminalFocusPerformanceTests {
    @Test("Centering an unchanged-size terminal does not request repeated resizes")
    func placementSkipsUnchangedSize() {
        let current = CGRect(x: 10, y: 20, width: 900, height: 700)
        let target = CGRect(x: 300, y: 140, width: 900, height: 700)
        let placement = TerminalFocusPlacement(from: current, to: target)
        #expect(!placement.resize)
        #expect(placement.reposition)
        let unchanged = TerminalFocusPlacement(from: target, to: target)
        #expect(!unchanged.resize)
        #expect(!unchanged.reposition)
    }

    @Test("Moving to a smaller display requests both necessary placement changes")
    func placementResizesForSmallerDisplay() {
        let placement = TerminalFocusPlacement(
            from: CGRect(x: -1_200, y: 0, width: 1_400, height: 1_000),
            to: CGRect(x: 80, y: 100, width: 840, height: 672)
        )
        #expect(placement.resize)
        #expect(placement.reposition)
    }

    @Test("Dismissal invalidation crosses actors and leaves a new focus request usable")
    func invalidationCrossesActors() async throws {
        let old = TerminalFocusOperation()
        let new = TerminalFocusOperation()
        try old.checkCancellation()
        old.cancel()
        let rejected = await Task.detached {
            do { try old.checkCancellation(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(rejected)
        try new.checkCancellation()
        old.cancel()
        try new.checkCancellation()
    }

    @Test("Caller task cancellation also stops focus work")
    func callerCancellation() async {
        let operation = TerminalFocusOperation()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            do { try operation.checkCancellation(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        #expect(await task.value)
    }
}
