import Foundation
import Testing
@testable import FocusQueueCore

private func ticket(_ id: String, priority: String = "medium") -> DashboardTicket {
    DashboardTicket(id: id, title: id, priority: priority, status: "backlog", summary: "")
}

private func link(_ step: String?, phase: DevelopmentPhase) -> DevelopmentTaskLink {
    DevelopmentTaskLink(phase: phase, step: step, source: .human)
}

private func phasedProcess() -> DevelopmentProcess {
    DevelopmentProcess(currentPhase: .phase0, links: [
        "DEM-1": link("build", phase: .implementation),
        "DEM-2": link("scaffolding", phase: .phase0),
        "DEM-3": link("build", phase: .implementation),
        "DEM-4": link(nil, phase: .phase0),
        "DEM-6": link("concept", phase: .planning),
    ])
}

@Test("Phase order groups by phase, then unlinked, then outside the process")
func phaseOrderGroupsByPhase() {
    let tickets = ["DEM-1", "DEM-2", "DEM-3", "DEM-4", "DEM-5", "DEM-6"].map { ticket($0) }
    let ordered = QueueOrderStore.phaseOrdered(tickets, process: phasedProcess()).map(\.id)
    #expect(ordered == ["DEM-6", "DEM-2", "DEM-1", "DEM-3", "DEM-5", "DEM-4"])
}

@Test("Within a phase a task follows its prerequisites; ties keep the incoming order")
func phaseOrderFollowsDependencies() throws {
    var process = phasedProcess()
    try process.setDependencies(taskID: "DEM-1", prerequisites: ["DEM-3"])
    let tickets = ["DEM-1", "DEM-3", "DEM-2"].map { ticket($0) }
    #expect(QueueOrderStore.phaseOrdered(tickets, process: process).map(\.id) == ["DEM-2", "DEM-3", "DEM-1"])

    // Cross-phase and missing prerequisites never reorder a phase.
    try process.setDependencies(taskID: "DEM-2", prerequisites: ["DEM-1", "DEM-99"])
    #expect(QueueOrderStore.phaseOrdered(tickets, process: process).map(\.id) == ["DEM-2", "DEM-3", "DEM-1"])
}

@Test("An order that already satisfies phase and dependency rules is unchanged")
func phaseOrderIsStable() throws {
    var process = phasedProcess()
    try process.setDependencies(taskID: "DEM-1", prerequisites: ["DEM-3"])
    let manual = ["DEM-6", "DEM-2", "DEM-3", "DEM-1", "DEM-5", "DEM-4"].map { ticket($0) }
    #expect(QueueOrderStore.phaseOrdered(manual, process: process).map(\.id) == manual.map(\.id))
}

@Test("Pins lead only within their phase in phase order")
func pinsLeadWithinPhase() {
    let tickets = ["DEM-2", "DEM-1", "DEM-3"].map { ticket($0) }
    let pins = ["DEM-3": Date()]
    #expect(QueueOrderStore.prioritizingPins(tickets, pinnedAtByTicketID: pins).map(\.id)
        == ["DEM-3", "DEM-2", "DEM-1"])
    #expect(QueueOrderStore.prioritizingPins(tickets, pinnedAtByTicketID: pins, phases: phasedProcess()).map(\.id)
        == ["DEM-2", "DEM-3", "DEM-1"])
}

@Test("Automatic phase order starts from priority and applies only with a process")
func automaticPhaseOrder() {
    let tickets = [ticket("DEM-1"), ticket("DEM-2", priority: "low"), ticket("DEM-3", priority: "critical")]
    let phased = QueueOrderStore.automaticTickets(
        tickets, deferredTicketIDs: [], mode: .phase, contexts: [], phases: phasedProcess())
    #expect(phased.map(\.id) == ["DEM-2", "DEM-3", "DEM-1"])
    let unphased = QueueOrderStore.automaticTickets(
        tickets, deferredTicketIDs: [], mode: .recentActivity, contexts: [], phases: phasedProcess())
    #expect(unphased.map(\.id) == ["DEM-3", "DEM-1", "DEM-2"])
}

@Test("Phase order resolves to recent activity without phases")
func phaseModeResolves() {
    #expect(QueueActivitySortMode.phase.resolved(hasPhases: true) == .phase)
    #expect(QueueActivitySortMode.phase.resolved(hasPhases: false) == .recentActivity)
    #expect(QueueActivitySortMode.manual.resolved(hasPhases: true) == .recentActivity)
    #expect(QueueActivitySortMode.triage.resolved(hasPhases: false) == .triage)
}

@Test("Dependencies refuse self-references and cycles and dedupe IDs")
func dependencyValidation() throws {
    var process = DevelopmentProcess()
    try process.setDependencies(taskID: "dem-1", prerequisites: ["dem-2", "DEM-2", " "])
    #expect(process.prerequisites(of: "DEM-1") == ["DEM-2"])
    #expect(throws: DevelopmentProcessError.dependencyCycle(["DEM-3", "DEM-3"])) {
        var copy = process
        try copy.setDependencies(taskID: "DEM-3", prerequisites: ["DEM-3"])
    }
    try process.setDependencies(taskID: "DEM-2", prerequisites: ["DEM-3"])
    #expect(throws: DevelopmentProcessError.dependencyCycle(["DEM-3", "DEM-1", "DEM-2", "DEM-3"])) {
        var copy = process
        try copy.setDependencies(taskID: "DEM-3", prerequisites: ["DEM-1"])
    }
    #expect(process.prerequisites(of: "DEM-3").isEmpty)
    try process.setDependencies(taskID: "DEM-1", prerequisites: [])
    #expect(process.dependencies["DEM-1"] == nil)
}

@Test("The store persists dependencies, and files without them still decode")
func dependencyPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("phase-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = ProjectDefinition(id: "demo", name: "Demo", taskPrefix: "DEM", repositoryPath: "/tmp/demo-repo")
    _ = try ProjectContextStore(root: root).ensurePlan(for: project)
    let store = DevelopmentProcessStore(root: root)
    let url = try store.url(projectID: "demo")
    try Data(#"{"enabled": true, "currentPhase": "phase0"}"#.utf8).write(to: url)
    #expect(try store.load(projectID: "demo")?.dependencies == [:])

    _ = try store.setDependencies(taskID: "DEM-2", prerequisites: ["DEM-1"], projectID: "demo")
    #expect(try store.load(projectID: "demo")?.prerequisites(of: "DEM-2") == ["DEM-1"])
    #expect(throws: DevelopmentProcessError.self) {
        try store.setDependencies(taskID: "DEM-1", prerequisites: ["DEM-2"], projectID: "demo")
    }
}

@Test("Reconcile drops dependencies on tasks that left the dashboard")
func reconcileDropsDependencies() throws {
    var process = DevelopmentProcess(dependencies: ["DEM-1": ["DEM-2", "DEM-9"], "DEM-8": ["DEM-1"]])
    let tickets = ["DEM-1", "DEM-2"].map {
        DevelopmentTicket(id: $0, title: $0, status: "backlog", isOpen: true)
    }
    let changed = process.reconcile(tickets: tickets)
    #expect(changed)
    #expect(process.dependencies == ["DEM-1": ["DEM-2"]])
}
