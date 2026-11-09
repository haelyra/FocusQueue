import Foundation
import Testing
@testable import FocusQueueCore

private func stewardFixture() throws -> (root: URL, projectID: String, directory: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dev-steward-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = ProjectDefinition(id: "demo", name: "Demo", taskPrefix: "DEM",
        repositoryPath: "/tmp/demo-repo")
    let plan = try ProjectContextStore(root: root).ensurePlan(for: project)
    return (root, project.id, plan.deletingLastPathComponent())
}

private func ticket(_ id: String, open: Bool = true, title: String = "Work",
                    updatedAt: String? = nil) -> DevelopmentTicket {
    DevelopmentTicket(id: id, title: title, summary: "", status: open ? "in-progress" : "resolved",
                      isOpen: open, updatedAt: updatedAt)
}

@Test("Task status raises linked steps without a model and never accepts")
func reconcileFromTaskStatus() throws {
    var process = DevelopmentProcess()
    process.links["DEM-1"] = DevelopmentTaskLink(phase: .planning, step: "prd", source: .steward)
    process.links["DEM-2"] = DevelopmentTaskLink(phase: .planning, step: "prd", source: .steward)

    do { let changed = process.reconcile(tickets: [ticket("DEM-1"), ticket("DEM-2", open: false)]); #expect(changed) }
    #expect(process.steps["prd"]?.status == .inProgress)
    #expect(process.steps["prd"]?.source == .tasks)
    #expect(process.steps["prd"]?.note?.contains("DEM-1") == true)

    do { let changed = process.reconcile(tickets: [ticket("DEM-1", open: false), ticket("DEM-2", open: false)]); #expect(changed) }
    #expect(process.steps["prd"]?.status == .done)
    // Idempotent: a second pass with the same tasks changes nothing.
    do { let changed = process.reconcile(tickets: [ticket("DEM-1", open: false), ticket("DEM-2", open: false)]); #expect(!changed) }

    // A human acceptance is never lowered by an automatic pass.
    process.steps["prd"] = DevelopmentStepState(status: .accepted, source: .human)
    process.reconcile(tickets: [ticket("DEM-1"), ticket("DEM-2")])
    #expect(process.steps["prd"]?.status == .accepted)

    // Links to tasks that no longer exist are dropped.
    do { let changed = process.reconcile(tickets: [ticket("DEM-1")]); #expect(changed) }
    #expect(process.links["DEM-2"] == nil)
}

@Test("A human reset to pending holds against automatic raises")
func humanPendingHolds() {
    var process = DevelopmentProcess()
    process.links["DEM-1"] = DevelopmentTaskLink(phase: .planning, step: "concept", source: .steward)
    process.steps["concept"] = DevelopmentStepState(status: .pending, source: .human)
    do { let changed = process.reconcile(tickets: [ticket("DEM-1")]); #expect(!changed) }
    #expect(process.steps["concept"]?.status == .pending)
    // A human "active" step may still rise to done once its tasks close.
    process.steps["concept"] = DevelopmentStepState(status: .inProgress, source: .human)
    do { let changed = process.reconcile(tickets: [ticket("DEM-1", open: false)]); #expect(changed) }
    #expect(process.steps["concept"]?.status == .done)
}

@Test("Closed tasks linked to a module mark it implemented, never QA-accepted")
func moduleImplementedFromTasks() {
    var process = DevelopmentProcess(currentPhase: .implementation,
        modules: [DevelopmentModule(id: "auth", name: "Auth")])
    process.links["DEM-3"] = DevelopmentTaskLink(phase: .implementation, step: "build", moduleID: "auth",
                                                 source: .steward)
    process.reconcile(tickets: [ticket("DEM-3")])
    #expect(process.modules[0].implemented == false)
    process.reconcile(tickets: [ticket("DEM-3", open: false)])
    #expect(process.modules[0].implemented && !process.modules[0].qaAccepted)
    #expect(process.steps["build"]?.status == .done)
}

@Test("Steward proposals are validated: unknown tasks, steps, and acceptances are dropped; human links win")
func stewardApplyValidates() throws {
    var process = DevelopmentProcess(modules: [DevelopmentModule(id: "auth", name: "Auth")])
    process.links["DEM-9"] = DevelopmentTaskLink(phase: .planning, step: "concept", source: .human)
    let tickets = [ticket("DEM-1"), ticket("DEM-2"), ticket("DEM-3"), ticket("DEM-4"), ticket("DEM-9")]
    let reply = DevelopmentStewardReply(links: [
        .init(taskID: "dem-1", step: "prd", module: nil),
        .init(taskID: "DEM-2", step: nil, module: "Auth"),
        .init(taskID: "DEM-3", step: "beta", module: nil),       // a later phase's step
        .init(taskID: "DEM-4", step: "nonsense", module: nil),   // not a step
        .init(taskID: "DEM-404", step: "prd", module: nil),      // unknown task
        .init(taskID: "DEM-9", step: "prd", module: nil),        // human link
    ], steps: [
        .init(step: "research", status: "done", evidence: "research.md and design.md exist"),
        .init(step: "concept", status: "accepted", evidence: "looks great"),
        .init(step: "security", status: "done", evidence: "wrong phase"),
    ])
    let summary = DevelopmentSteward.apply(reply, to: &process, tickets: tickets)

    #expect(process.links["DEM-1"]?.step == "prd" && process.links["DEM-1"]?.source == .steward)
    #expect(process.links["DEM-2"] != nil && process.links["DEM-2"]?.step == nil)
    #expect(process.links["DEM-2"]?.moduleID == nil, "Outside-process tasks carry no module")
    #expect(process.links["DEM-3"]?.phase == .prerelease && process.links["DEM-3"]?.step == "beta")
    #expect(process.links["DEM-4"] == nil)
    let ahead = try #require(process.tasksAhead(tickets: tickets))
    #expect(ahead.phase == .prerelease && ahead.taskIDs == ["DEM-3"])
    #expect(process.links["DEM-404"] == nil)
    #expect(process.links["DEM-9"]?.step == "concept")
    #expect(process.steps["research"]?.status == .done)
    #expect(process.steps["research"]?.note == "research.md and design.md exist")
    #expect(process.steps["concept"]?.status == .inProgress, "Raised by the open human-linked task, never accepted")
    #expect(process.steps["security"] == nil)
    // Reconcile runs inside apply, so DEM-1 (open) makes prd active.
    #expect(process.steps["prd"]?.status == .inProgress)
    #expect(summary.hasPrefix("Linked 2 tasks; 1 outside the process; raised research → done"))
}

@Test("The signature ignores status changes but tracks new tasks, files, and phase")
func stewardSignature() {
    var process = DevelopmentProcess()
    process.links["DEM-1"] = DevelopmentTaskLink(phase: .planning, step: "prd", source: .steward)
    let files = [DevelopmentProjectFile(name: "prd.md", bytes: 10)]
    let base = DevelopmentSteward.signature(process: process, tickets: [ticket("DEM-1")], files: files)
    #expect(base == DevelopmentSteward.signature(process: process,
        tickets: [ticket("DEM-1", open: false)], files: files))
    #expect(base != DevelopmentSteward.signature(process: process,
        tickets: [ticket("DEM-1"), ticket("DEM-2")], files: files))
    #expect(base != DevelopmentSteward.signature(process: process, tickets: [ticket("DEM-1")],
        files: files + [DevelopmentProjectFile(name: "design.md", bytes: 5)]))
    process.currentPhase = .phase0
    #expect(base != DevelopmentSteward.signature(process: process, tickets: [ticket("DEM-1")], files: files))
}

@Test("A pass is due on a new signature after the minimum interval, and retries errors slowly")
func stewardDue() {
    let now = Date()
    var process = DevelopmentProcess()
    #expect(DevelopmentSteward.isDue(process: process, signature: "a", now: now))
    process.steward = DevelopmentStewardRun(signature: "a", ranAt: now.addingTimeInterval(-30))
    #expect(!DevelopmentSteward.isDue(process: process, signature: "b", now: now))
    process.steward?.ranAt = now.addingTimeInterval(-200)
    #expect(DevelopmentSteward.isDue(process: process, signature: "b", now: now))
    #expect(!DevelopmentSteward.isDue(process: process, signature: "a", now: now))
    process.steward?.error = "timed out"
    #expect(!DevelopmentSteward.isDue(process: process, signature: "a", now: now))
    process.steward?.ranAt = now.addingTimeInterval(-DevelopmentSteward.errorRetryInterval - 1)
    #expect(DevelopmentSteward.isDue(process: process, signature: "a", now: now))
    process.enabled = false
    #expect(!DevelopmentSteward.isDue(process: process, signature: "z", now: now))
}

@Test("The prompt lists the phase steps, unlinked tasks, and files with their headings")
func stewardMessage() throws {
    let (root, _, directory) = try stewardFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try "# Kairos PRD\n\n**Status:** ratified baseline.\n".write(
        to: directory.appendingPathComponent("prd.md"), atomically: true, encoding: .utf8)
    try "- a saved fact".write(to: directory.appendingPathComponent("data.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("modules"),
                                            withIntermediateDirectories: true)
    try "# Auth module\nLogin flow.".write(to: directory.appendingPathComponent("modules/auth.md"),
                                           atomically: true, encoding: .utf8)
    let files = DevelopmentSteward.projectFiles(directory: directory)
    #expect(files.contains { $0.name == "prd.md" && $0.heading == "Kairos PRD"
        && $0.lead == "**Status:** ratified baseline." })
    #expect(files.contains { $0.name == "modules/auth.md" })
    #expect(!files.contains { $0.name == "data.md" })

    var process = DevelopmentProcess()
    process.links["DEM-1"] = DevelopmentTaskLink(phase: .planning, step: "prd", source: .steward)
    let message = DevelopmentSteward.message(projectName: "Demo", process: process,
        tickets: [ticket("DEM-1", title: "Write PRD"), ticket("DEM-2", title: "Sketch concept"),
                  ticket("DEM-3", open: false, title: "Old research", updatedAt: "2026-11-01")],
        files: files)
    #expect(message.contains("Current development phase: Planning."))
    #expect(message.contains("prd | pending | Technical design & PRD"))
    #expect(message.contains("DEM-2 | in-progress | Sketch concept"))
    #expect(message.contains("DEM-3 | resolved | Old research"))
    #expect(message.contains("Already linked tasks (ID | status | step):\nDEM-1 | in-progress | prd"))
    #expect(message.contains("scaffolding | Phase 0 | Scaffolding & environment"))
    #expect(!message.contains("DEM-1 | in-progress | Write PRD"), "Linked tasks are not re-asked")
    #expect(message.contains("prd.md | "))
    #expect(message.contains("Kairos PRD — **Status:** ratified baseline."))
}

@Test("Store mutations share one locked read-modify-write and never overwrite a malformed file")
func storeMutateHardening() throws {
    let (root, projectID, _) = try stewardFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    let url = try store.url(projectID: projectID)

    // Files from the first release (no links or steward keys) still decode.
    try #"{"currentPhase":"phase0","enabled":true,"modules":[],"schemaVersion":1,"steps":{"scaffolding":{"status":"done","updatedAt":0}},"updatedAt":0}"#
        .write(to: url, atomically: true, encoding: .utf8)
    var process = try #require(try store.load(projectID: projectID))
    #expect(process.currentPhase == .phase0 && process.links.isEmpty && process.steward == nil)
    #expect(process.steps["scaffolding"]?.isAutomatic == false)

    process = try store.link(taskID: "dem-5", step: "scaffolding", projectID: projectID)
    #expect(process.links["DEM-5"]?.source == .human)
    #expect(throws: DevelopmentProcessError.self) {
        _ = try store.link(taskID: "DEM-5", step: "nonsense", projectID: projectID)
    }

    // Concurrent writers keep each other's changes.
    DispatchQueue.concurrentPerform(iterations: 8) { index in
        _ = try? store.addModule(name: "M\(index)", file: nil, projectID: projectID)
    }
    #expect(try store.load(projectID: projectID)?.modules.count == 8)

    try "{ not json".write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { _ = try store.setPhase(.release, projectID: projectID) }
    #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
}

private struct StubStewardProcess: ProcessRunning {
    let result: ProcessResult
    let seen: @Sendable (ProcessSpecification, String) -> Void
    func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
        let index = try #require(specification.arguments.firstIndex(of: "--message-file"))
        seen(specification, (try? String(contentsOfFile: specification.arguments[index + 1], encoding: .utf8)) ?? "")
        return result
    }
}

private final class Captured: @unchecked Sendable {
    var arguments: [String] = []
    var message = ""
}

@Test("A full pass sends the prompt through the placement script and applies the reply under lock")
func stewardRunPass() async throws {
    let (root, projectID, directory) = try stewardFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try "# PRD\nRatified.".write(to: directory.appendingPathComponent("prd.md"), atomically: true, encoding: .utf8)
    let store = DevelopmentProcessStore(root: root)
    _ = try store.setEnabled(true, projectID: projectID)
    let script = root.appendingPathComponent("focus_queue_placement.py")
    try "".write(to: script, atomically: true, encoding: .utf8)
    let captured = Captured()
    let reply = #"{"links":[{"taskID":"DEM-1","step":"prd","module":null}],"steps":[{"step":"prd","status":"done","evidence":"prd.md"}],"model":"claude/haiku"}"#
    let runner = DevelopmentStewardRunner(script: script, environment: [:], runner: StubStewardProcess(
        result: ProcessResult(exitCode: 0, standardOutput: reply, standardError: "", timedOut: false),
        seen: { specification, message in captured.arguments = specification.arguments; captured.message = message }))

    let process = try await DevelopmentSteward.runPass(projectID: projectID, projectName: "Demo", store: store,
        tickets: [ticket("DEM-1", title: "Write the PRD")], provider: .claude, runner: runner)
    #expect(captured.arguments.prefix(4) == [script.path, "develop", "--provider", "claude"])
    #expect(captured.message.contains("DEM-1 | in-progress | Write the PRD"))
    #expect(captured.message.contains("prd.md | "))
    #expect(process.links["DEM-1"]?.step == "prd")
    #expect(process.steps["prd"]?.status == .done && process.steps["prd"]?.note == "prd.md")
    #expect(process.steward?.model == "claude/haiku" && process.steward?.error == nil)
    #expect(try store.load(projectID: projectID) == process)

    // A failed call is recorded, keeps earlier state, and never throws.
    let failing = DevelopmentStewardRunner(script: script, environment: [:], runner: StubStewardProcess(
        result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "development: model unavailable (timed out)",
                              timedOut: false), seen: { _, _ in }))
    let after = try await DevelopmentSteward.runPass(projectID: projectID, projectName: "Demo", store: store,
        tickets: [ticket("DEM-1"), ticket("DEM-2")], provider: .claude, runner: failing)
    #expect(after.steward?.error?.contains("timed out") == true)
    #expect(after.steward?.summary == process.steward?.summary)
    #expect(after.links["DEM-1"]?.step == "prd")
}
