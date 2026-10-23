import Foundation
import Testing
@testable import FocusQueueCore

@Test("Project queue orders stay isolated and can read the legacy order until first save")
func projectScopedQueueOrder() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("queue-order-project-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let tickets = [
        DashboardTicket(id: "APP-1", title: "One", status: "open", summary: ""),
        DashboardTicket(id: "APP-2", title: "Two", status: "open", summary: ""),
    ]
    let legacy = QueueOrderStore(root: root)
    _ = try legacy.move("APP-2", to: .top, tickets: tickets, fallbackIDs: ["APP-1", "APP-2"])

    let first = QueueOrderStore(root: root, projectID: "first/project")
    let second = QueueOrderStore(root: root, projectID: "second/project")
    #expect(try first.load() == ["APP-2", "APP-1"])
    #expect(try second.load() == ["APP-2", "APP-1"])

    _ = try first.move("APP-1", to: .top, tickets: tickets, fallbackIDs: ["APP-2", "APP-1"])
    #expect(try first.load() == ["APP-1", "APP-2"])
    #expect(try second.load() == ["APP-2", "APP-1"])
}

@Suite("Saved queue order")
struct QueueOrderTests {
    private let tickets = (1...8).map {
        DashboardTicket(id: "ECC-\($0)", title: "Task \($0)", priority: $0 == 1 ? "critical" : "medium",
                        status: "open", summary: "", updatedAt: "2026-09-17")
    }

    @Test("Moving a task first keeps the previous first task second")
    func movePreservesOthersAndSurvivesReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueOrderStore(root: root)
        let ids = tickets.map(\.id)
        #expect(try store.load() == nil)
        #expect(try store.move("ECC-2", to: .top, tickets: tickets, fallbackIDs: ids)
                == ["ECC-2", "ECC-1", "ECC-3", "ECC-4", "ECC-5", "ECC-6", "ECC-7", "ECC-8"])
        let external = QueueOrderStore(root: root)
        #expect(try external.load() == store.load())
        // A second writer reads the first writer's latest order, even with a stale fallback.
        #expect(try external.move("ECC-8", to: .before("ECC-4"), tickets: tickets, fallbackIDs: ids)
                == ["ECC-2", "ECC-1", "ECC-3", "ECC-8", "ECC-4", "ECC-5", "ECC-6", "ECC-7"])
        #expect(try store.move("ECC-1", to: .after("ECC-6"), tickets: tickets, fallbackIDs: ids)
                == ["ECC-2", "ECC-3", "ECC-8", "ECC-4", "ECC-5", "ECC-6", "ECC-1", "ECC-7"])
        #expect(try store.move("ECC-2", to: .bottom, tickets: tickets, fallbackIDs: ids).last == "ECC-2")
    }

    @Test("Saved positions override updated priority and exclude stale or completed tasks")
    func refreshedDashboard() {
        var changed = tickets
        changed[0] = DashboardTicket(id: "ECC-1", title: "Completed", status: "resolved", summary: "")
        changed[2] = DashboardTicket(id: "ECC-3", title: "New critical", priority: "critical",
            status: "open", summary: "", updatedAt: "2026-10-01")
        let ordered = QueueOrderStore.orderedTickets(changed,
            savedIDs: ["missing", "ECC-2", "ECC-1", "ECC-2", "ECC-4", "ECC-3"])
        #expect(ordered.map(\.id) == ["ECC-2", "ECC-4", "ECC-3", "ECC-5", "ECC-6", "ECC-7", "ECC-8"])
    }

    @Test("Recent activity leads for two days, newest first, then priority orders the rest")
    func recentActivityTier() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let created = ISO8601DateFormatter().string(from: now.addingTimeInterval(-day))
        let stale = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10 * day))
        let baseline = [
            DashboardTicket(id: "A", title: "Low stale", priority: "low", status: "open", summary: "",
                createdAt: stale),
            DashboardTicket(id: "B", title: "High stale", priority: "high", status: "open", summary: "",
                createdAt: stale),
            DashboardTicket(id: "C", title: "New task", priority: "low", status: "open", summary: "",
                createdAt: created),
            DashboardTicket(id: "D", title: "Old prompt", priority: "critical", status: "open", summary: ""),
            DashboardTicket(id: "E", title: "Recent output", priority: "medium", status: "open", summary: "",
                createdAt: stale),
            DashboardTicket(id: "F", title: "Recent prompt", priority: "low", status: "open", summary: ""),
            DashboardTicket(id: "G", title: "Medium stale", priority: "medium", status: "open", summary: ""),
            DashboardTicket(id: "H", title: "Medium older output", priority: "medium", status: "open",
                summary: ""),
        ]
        let ordered = QueueOrderStore.prioritizingActivity(
            baseline,
            mode: .recentActivity,
            lastPromptAtByTicketID: ["D": now.addingTimeInterval(-3 * day), "F": now.addingTimeInterval(-60)],
            lastOutputAtByTicketID: ["E": now.addingTimeInterval(-2 * day + 60), "H": now.addingTimeInterval(-5 * day)],
            now: now)

        // F, C, E fall inside the window; D's prompt expired, so it sorts by priority.
        // Among stale medium tasks, H's older output still outranks G's none.
        #expect(ordered.map(\.id) == ["F", "C", "E", "D", "B", "H", "G", "A"])
    }

    @Test("Recent interactions have no expiry and deadline triage orders the remainder")
    func recentInteractionTier() {
        let baseline = QueueOrderStore.orderedTickets(
            tickets, savedIDs: ["ECC-8", "ECC-2", "ECC-5", "ECC-1"])
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let prompts = [
            "ECC-3": now.addingTimeInterval(-60),
            "ECC-6": now.addingTimeInterval(-3_600),
            "ECC-8": now.addingTimeInterval(-(3 * 24 * 60 * 60 + 1)),
            "ECC-2": now.addingTimeInterval(60),
        ]
        let ordered = QueueOrderStore.prioritizingActivity(
            baseline,
            mode: .recentInteraction,
            lastPromptAtByTicketID: prompts,
            lastOutputAtByTicketID: [:])

        #expect(ordered.map(\.id) == [
            "ECC-2", "ECC-3", "ECC-6", "ECC-8", "ECC-1", "ECC-4", "ECC-5", "ECC-7",
        ])
        #expect(QueueOrderStore.prioritizingActivity(
            baseline,
            mode: .manual,
            lastPromptAtByTicketID: prompts,
            lastOutputAtByTicketID: [:]) == baseline)
    }

    @Test("Recent output and triage modes use their explicit ordering rules")
    func outputAndTriageModes() {
        let baseline = QueueOrderStore.orderedTickets(
            tickets, savedIDs: ["ECC-8", "ECC-2", "ECC-5", "ECC-1"])
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let output = QueueOrderStore.prioritizingActivity(
            baseline,
            mode: .recentOutput,
            lastPromptAtByTicketID: [:],
            lastOutputAtByTicketID: [
                "ECC-5": now.addingTimeInterval(-10),
                "ECC-1": now.addingTimeInterval(-20),
            ])
        #expect(output.map(\.id) == [
            "ECC-5", "ECC-1", "ECC-2", "ECC-3", "ECC-4", "ECC-6", "ECC-7", "ECC-8",
        ])

        let triage = QueueOrderStore.prioritizingActivity(
            baseline,
            mode: .triage,
            lastPromptAtByTicketID: [:],
            lastOutputAtByTicketID: [:])
        #expect(triage.map(\.id) == tickets.map(\.id))
    }

    @Test("Invalid moves leave disk unchanged and reset clears legacy deferral")
    func invalidAndReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueOrderStore(root: root)
        let initial = try store.move("ECC-8", to: .top, tickets: tickets, fallbackIDs: [])
        #expect(throws: (any Error).self) {
            try store.move("missing", to: .top, tickets: tickets, fallbackIDs: [])
        }
        #expect(throws: (any Error).self) {
            try store.move("ECC-1", to: .after("missing"), tickets: tickets, fallbackIDs: [])
        }
        #expect(try store.move("ECC-8", to: .before("ECC-8"), tickets: tickets, fallbackIDs: []) == initial)
        #expect(try store.load() == initial)
        try store.reset()
        #expect(try store.load() == [])
        #expect(QueueOrderStore.orderedTickets(tickets, savedIDs: try store.load()!).map(\.id) == tickets.map(\.id))
    }

    @Test("First manual move retains other legacy deferred positions")
    func legacyOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = DashboardOrdering.openTickets(in: tickets, deferredTicketIDs: ["ECC-1", "ECC-3"]).map(\.id)
        let result = try QueueOrderStore(root: root).move("ECC-8", to: .top, tickets: tickets, fallbackIDs: old)
        #expect(result == ["ECC-8"] + old.filter { $0 != "ECC-8" })
    }
}

@Test("A sort mode saved under the old key resets once to recent activity")
func legacySortModeResets() throws {
    let legacy = try JSONDecoder().decode(LocalState.self, from: Data(#"{"queueActivitySortMode":"manual"}"#.utf8))
    #expect(legacy.queueActivitySortMode == nil)
    let saved = try JSONEncoder().encode(LocalState(queueActivitySortMode: .manual))
    #expect(try JSONDecoder().decode(LocalState.self, from: saved).queueActivitySortMode == .manual)
}
