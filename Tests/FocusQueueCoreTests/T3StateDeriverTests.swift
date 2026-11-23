import Foundation
import Testing
@testable import FocusQueueCore

@Suite("T3StateDeriver")
struct T3StateDeriverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let previous = T3Samples.reference()

    private func derive(_ snapshot: T3ThreadSnapshot, questions: [String] = [],
                        previous: T3ThreadReference? = nil, pausedAt: Date? = nil) -> T3Derived {
        T3StateDeriver.derive(snapshot: snapshot, questionIds: questions, previous: previous ?? self.previous,
                              pausedAt: pausedAt, now: now)
    }

    private func run(_ id: String, _ ordinal: Int, _ status: String) -> T3Run {
        T3Run(runId: id, ordinal: ordinal, status: status)
    }

    // MARK: Rule 1: question and approval counts

    @Test func twoQuestionsAndOneApprovalAreBlockedOnQuestion() {
        let derived = derive(T3Samples.snapshot(status: "running", active: "R1", pending: 3), questions: ["Q1", "Q2"])
        #expect(derived.status == .blocked)
        #expect(derived.attention == .question)
        #expect(derived.reference.openQuestionIds == ["Q1", "Q2"])
        #expect(derived.reference.pendingApprovalCount == 1)
    }

    @Test func approvalCountNeverGoesNegative() {
        // The question list can be fresher than the snapshot's count.
        let derived = derive(T3Samples.snapshot(pending: 1), questions: ["Q1", "Q2"])
        #expect(derived.reference.pendingApprovalCount == 0)
        #expect(derived.attention == .question)
    }

    // MARK: Rule 2: latest terminal run

    @Test func latestTerminalIsTheHighestOrdinalTerminalRun() {
        let runs = [run("R3", 3, "failed"), run("R5", 5, "running"), run("R4", 4, "completed"), run("R1", 1, "cancelled")]
        let derived = derive(T3Samples.snapshot(status: "running", active: "R5", runs: runs))
        #expect(derived.reference.latestTerminalRunId == "R4")
        #expect(derived.reference.latestTerminalOutcome == "completed")
    }

    @Test func noTerminalRunKeepsTheLastOneSeen() {
        var earlier = previous
        earlier.latestTerminalRunId = "R1"
        earlier.latestTerminalOutcome = "completed"
        let derived = derive(T3Samples.snapshot(status: "running", active: "R2", runs: [run("R2", 2, "running")]),
                             previous: earlier)
        #expect(derived.reference.latestTerminalRunId == "R1")
        #expect(derived.reference.latestTerminalOutcome == "completed")
        #expect(!derived.markUnread)
    }

    // MARK: Rule 3: status

    @Test(arguments: [
        (T3Samples.snapshot(pending: 1), [String](), TaskSubtaskStatus.blocked),
        (T3Samples.snapshot(pending: 1), ["Q1"], .blocked),
        (T3Samples.snapshot(status: "idle", active: "R1"), [], .working),
        (T3Samples.snapshot(status: "preparing"), [], .working),
        (T3Samples.snapshot(status: "running"), [], .working),
        (T3Samples.snapshot(status: "queued"), [], .idle),
        (T3Samples.snapshot(status: "idle"), [], .idle),
        (T3Samples.snapshot(status: "completed"), [], .idle),
    ])
    func status(snapshot: T3ThreadSnapshot, questions: [String], expected: TaskSubtaskStatus) {
        #expect(derive(snapshot, questions: questions).status == expected)
    }

    // MARK: Rule 4: attention

    @Test func approvalOnlyNeedsApproval() {
        let derived = derive(T3Samples.snapshot(status: "running", active: "R1", pending: 1))
        #expect(derived.status == .blocked)
        #expect(derived.attention == .approval)
        #expect(derived.reference.pendingApprovalCount == 1)
        #expect(derived.reference.openQuestionIds.isEmpty)
    }

    @Test func idleAfterFailureIsFailed() {
        #expect(derive(T3Samples.snapshot(runs: [run("R1", 1, "failed")])).attention == .failed)
    }

    @Test func idleAfterInterruptIsInterrupted() {
        #expect(derive(T3Samples.snapshot(runs: [run("R1", 1, "interrupted")])).attention == .interrupted)
    }

    @Test func pausedAndInterruptedHasNoAttention() {
        let derived = derive(T3Samples.snapshot(runs: [run("R1", 1, "interrupted")]), pausedAt: now)
        #expect(derived.status == .idle)
        #expect(derived.attention == nil)
    }

    @Test(arguments: ["completed", "cancelled"])
    func idleAfterCleanEndHasNoAttention(outcome: String) {
        #expect(derive(T3Samples.snapshot(runs: [run("R1", 1, outcome)])).attention == nil)
    }

    @Test func idleWithNoRunsHasNoAttention() {
        #expect(derive(T3Samples.snapshot()).attention == nil)
    }

    @Test func workingHidesAnEarlierFailure() {
        let derived = derive(T3Samples.snapshot(status: "running", active: "B", runs: [run("A", 1, "failed"), run("B", 2, "running")]))
        #expect(derived.status == .working)
        #expect(derived.attention == nil)
    }

    @Test func terminalRunADoesNotClearQuestionOnRunB() {
        let runs = [run("A", 1, "completed"), run("B", 2, "running")]
        let derived = derive(T3Samples.snapshot(status: "running", active: "B", pending: 1, runs: runs), questions: ["Q1"])
        #expect(derived.status == .blocked)
        #expect(derived.attention == .question)
        #expect(derived.reference.activeRunId == "B")
        #expect(derived.reference.latestTerminalRunId == "A")
        #expect(!derived.markUnread)
    }

    // MARK: Rule 5: unread

    @Test func newCompletedTerminalRunMarksUnreadOnceOnly() {
        let snapshot = T3Samples.snapshot(runs: [run("R1", 1, "completed")])
        let first = derive(snapshot)
        #expect(first.markUnread)
        let second = derive(snapshot, previous: first.reference)
        #expect(!second.markUnread)
        #expect(second.reference.latestTerminalRunId == "R1")
    }

    @Test(arguments: ["failed", "interrupted", "cancelled"])
    func newNonCompletedTerminalRunIsNotUnread(outcome: String) {
        #expect(!derive(T3Samples.snapshot(runs: [run("R1", 1, outcome)])).markUnread)
    }

    @Test func completedRunIsNotUnreadWhileWorkingOrBlocked() {
        let runs = [run("R1", 1, "completed"), run("R2", 2, "running")]
        #expect(!derive(T3Samples.snapshot(status: "running", active: "R2", runs: runs)).markUnread)
        #expect(!derive(T3Samples.snapshot(pending: 1, runs: [run("R1", 1, "completed")])).markUnread)
    }

    @Test func noTerminalRunIsNotUnread() {
        #expect(!derive(T3Samples.snapshot()).markUnread)
    }

    // MARK: Rule 6: reference fields

    @Test func referenceIsUpdatedAndMarkedReachable() {
        var stale = previous
        stale.reachability = .unreachable
        stale.openQuestionIds = ["OLD"]
        stale.pendingApprovalCount = 4
        stale.acknowledgedTerminalRunId = "R0"
        let derived = derive(T3Samples.snapshot(status: "running", active: "R2", runs: [run("R1", 1, "failed")]),
                             previous: stale)
        let reference = derived.reference
        #expect(reference.observedStatus == "running")
        #expect(reference.activeRunId == "R2")
        #expect(reference.latestTerminalRunId == "R1")
        #expect(reference.latestTerminalOutcome == "failed")
        #expect(reference.openQuestionIds.isEmpty)
        #expect(reference.pendingApprovalCount == 0)
        #expect(reference.lastSnapshotAt == now)
        #expect(reference.reachability == .reachable)
        // Identity and user state carry over.
        #expect(reference.threadId == stale.threadId)
        #expect(reference.environmentId == stale.environmentId)
        #expect(reference.link == stale.link)
        #expect(reference.acknowledgedTerminalRunId == "R0")
    }

    @Test func lastSnapshotAtDefaultsToTheCurrentTime() {
        let before = Date()
        let derived = T3StateDeriver.derive(snapshot: T3Samples.snapshot(), questionIds: [], previous: previous, pausedAt: nil)
        #expect((derived.reference.lastSnapshotAt ?? .distantPast) >= before)
    }

    // MARK: Rule 7: never completed

    @Test func noInputProducesCompleted() {
        let statuses = ["preparing", "running", "queued", "completed", "idle", "failed", "interrupted", "unknown"]
        let outcomes: [String?] = [nil, "completed", "failed", "interrupted", "cancelled", "running"]
        for status in statuses {
            for active in [nil, "R9"] as [String?] {
                for pending in 0...2 {
                    for questions in [[], ["Q1"]] as [[String]] {
                        for outcome in outcomes {
                            let runs = outcome.map { [run("R1", 1, $0)] } ?? []
                            let snapshot = T3Samples.snapshot(status: status, active: active, pending: pending, runs: runs)
                            for paused in [nil, now] as [Date?] {
                                #expect(derive(snapshot, questions: questions, pausedAt: paused).status != .completed)
                            }
                        }
                    }
                }
            }
        }
    }
}
