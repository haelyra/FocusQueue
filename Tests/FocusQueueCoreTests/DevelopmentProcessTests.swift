import Foundation
import Testing
@testable import FocusQueueCore

private func processFixture() throws -> (root: URL, projectID: String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dev-process-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = ProjectDefinition(id: "demo", name: "Demo", taskPrefix: "DEM",
        repositoryPath: "/tmp/demo-repo")
    _ = try ProjectContextStore(root: root).ensurePlan(for: project)
    return (root, project.id)
}

@Test("The catalog covers all five phases in order with the designed steps")
func catalogCoversPhases() {
    #expect(DevelopmentPhase.allCases.map(\.rawValue)
        == ["planning", "phase0", "implementation", "prerelease", "release"])
    #expect(DevelopmentPhase.planning.next == .phase0)
    #expect(DevelopmentPhase.release.next == nil)

    let planning = DevelopmentProcessCatalog.steps(in: .planning)
    #expect(planning.map(\.id) == ["concept", "research", "prd", "modules", "devplan", "contract"])
    #expect(planning.first { $0.id == "concept" }?.artifacts == ["concept.md"])
    #expect(planning.first { $0.id == "modules" }?.summary.contains("success criteria") == true)

    #expect(DevelopmentProcessCatalog.steps(in: .phase0).map(\.id) == ["scaffolding", "phase0-qa"])
    #expect(DevelopmentProcessCatalog.steps(in: .implementation).map(\.id) == ["build", "module-qa"])
    // Step state is keyed by ID alone, so no ID may repeat across phases.
    let ids = DevelopmentPhase.allCases.flatMap { DevelopmentProcessCatalog.steps(in: $0).map(\.id) }
    #expect(Set(ids).count == ids.count)
    #expect(DevelopmentProcessCatalog.steps(in: .prerelease).map(\.id) == ["beta", "latency"])
    #expect(DevelopmentProcessCatalog.steps(in: .release).map(\.id) == ["security", "staging", "deployment"])
}

@Test("Ensure creates development.json beside the project plan with secure permissions")
func ensureCreatesFile() throws {
    let (root, projectID) = try processFixture()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = DevelopmentProcessStore(root: root)
    #expect(try store.load(projectID: projectID) == nil)

    let process = try store.ensure(projectID: projectID)
    #expect(process.enabled && process.currentPhase == .planning)
    #expect(process.phaseIsAccepted == false)

    let url = try store.url(projectID: projectID)
    #expect(url.lastPathComponent == "development.json")
    #expect(url.deletingLastPathComponent().lastPathComponent == projectID)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    // A second ensure keeps the saved state instead of resetting it.
    _ = try store.setStepStatus(.done, stepID: "concept", projectID: projectID)
    let kept = try store.ensure(projectID: projectID)
    #expect(kept.steps["concept"]?.status == .done)
}

@Test("Step status moves through pending, done, and accepted within the current phase only")
func stepStatusFlow() throws {
    let (root, projectID) = try processFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)

    var process = try store.setStepStatus(.inProgress, stepID: "concept", projectID: projectID)
    #expect(process.status(of: DevelopmentProcessCatalog.step(id: "concept", in: .planning)!) == .inProgress)
    #expect(process.pendingSteps.map(\.id).first == "concept")

    process = try store.setStepStatus(.accepted, stepID: "concept", projectID: projectID)
    #expect(process.pendingSteps.map(\.id).first == "research")

    // Unknown step in the current phase throws.
    #expect(throws: DevelopmentProcessError.self) {
        _ = try store.setStepStatus(.done, stepID: "beta", projectID: projectID)
    }
    // Unknown step id entirely throws.
    #expect(throws: DevelopmentProcessError.self) {
        _ = try store.setStepStatus(.done, stepID: "nope", projectID: projectID)
    }

    for step in DevelopmentProcessCatalog.steps(in: .planning) {
        process = try store.setStepStatus(.accepted, stepID: step.id, projectID: projectID)
    }
    // Accepting the last Planning step advances the project to Phase 0.
    #expect(process.currentPhase == .phase0 && !process.phaseIsAccepted)
    process = try store.setPhase(.planning, projectID: projectID)
    #expect(process.phaseIsAccepted)
}

@Test("Module criteria acceptance is sequential")
func sequentialModuleAcceptance() throws {
    let (root, projectID) = try processFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)

    var process = try store.addModule(name: "Auth", file: "modules/auth.md", projectID: projectID)
    process = try store.addModule(name: "Sync", file: "modules/sync.md", projectID: projectID)
    let auth = process.modules[0], sync = process.modules[1]

    // Accepting Sync before Auth is rejected and names both modules.
    do {
        _ = try store.acceptCriteria(moduleID: sync.id, projectID: projectID)
        Issue.record("Expected out-of-order acceptance to throw")
    } catch DevelopmentProcessError.outOfOrderAcceptance(let module, let blockedBy) {
        #expect(module == "Sync" && blockedBy == "Auth")
    }

    process = try store.acceptCriteria(moduleID: auth.id, projectID: projectID)
    #expect(process.modules[0].criteriaAccepted)
    process = try store.acceptCriteria(moduleID: sync.id, projectID: projectID)
    #expect(process.modules[1].criteriaAccepted)

    #expect(throws: DevelopmentProcessError.self) {
        _ = try store.acceptCriteria(moduleID: "missing", projectID: projectID)
    }

    // Implementation and QA flags persist independently.
    process = try store.setModuleImplemented(true, moduleID: auth.id, projectID: projectID)
    process = try store.setModuleQAAccepted(true, moduleID: auth.id, projectID: projectID)
    let reloaded = try #require(try store.load(projectID: projectID))
    #expect(reloaded.modules[0].implemented && reloaded.modules[0].qaAccepted)
    #expect(reloaded.modules[1].implemented == false)
}

@Test("The enabled flag round-trips and defaults on for new processes")
func enabledFlag() throws {
    let (root, projectID) = try processFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)

    var process = try store.setEnabled(true, projectID: projectID)
    #expect(process.enabled)
    process = try store.setEnabled(false, projectID: projectID)
    #expect(!process.enabled)
    let reloaded = try #require(try store.load(projectID: projectID))
    #expect(!reloaded.enabled)
}

@Test("Brief guidance exists for every phase and stays concise")
func phaseBriefs() {
    for phase in DevelopmentPhase.allCases {
        let brief = DevelopmentProcessCatalog.brief(for: phase)
        #expect(!brief.isEmpty)
        #expect(brief.count < 300, "\(phase) brief should stay concise")
    }
    #expect(DevelopmentProcessCatalog.brief(for: .planning).contains("planning artifacts"))
    #expect(DevelopmentProcessCatalog.brief(for: .implementation).contains("success criteria"))
}

@Test("Checking off every existing artifact marks the step done; partial check-offs do not")
func artifactCheckOffCompletesStep() throws {
    let (root, projectID) = try processFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    let directory = try store.url(projectID: projectID).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["research.md", "design.md"] {
        try Data("# \(name)\n".utf8).write(to: directory.appendingPathComponent(name))
    }

    // One of two documents reviewed: the step stays pending.
    var process = try store.setArtifactChecked(true, stepID: "research", artifact: "research.md", projectID: projectID)
    #expect(process.status(of: DevelopmentProcessCatalog.step(id: "research", in: .planning)!) == .pending)
    #expect(process.steps["research"]?.checkedArtifacts == ["research.md"])

    // The second document completes the step with a human-sourced note.
    process = try store.setArtifactChecked(true, stepID: "research", artifact: "design.md", projectID: projectID)
    #expect(process.status(of: DevelopmentProcessCatalog.step(id: "research", in: .planning)!) == .done)
    #expect(process.steps["research"]?.note == "All documents reviewed.")
    #expect(process.steps["research"]?.isAutomatic == false)

    // Unchecking keeps the status; reopening the step is the marker's job.
    process = try store.setArtifactChecked(false, stepID: "research", artifact: "design.md", projectID: projectID)
    #expect(process.status(of: DevelopmentProcessCatalog.step(id: "research", in: .planning)!) == .done)
    #expect(process.steps["research"]?.checkedArtifacts == ["research.md"])

    // Check-offs survive status changes and automatic raises.
    process = try store.setStepStatus(.pending, stepID: "research", projectID: projectID)
    #expect(process.steps["research"]?.checkedArtifacts == ["research.md"])
    #expect(process.steps["research"]?.status == .pending)
    var mutable = process
    let raisedFromHumanReset = mutable.raise(stepID: "research", to: .inProgress, source: .tasks, note: nil)
    #expect(raisedFromHumanReset == false,
            "A human reset to pending holds against automatic raises")
    mutable.steps["research"]?.source = .steward
    let raisedBySteward = mutable.raise(stepID: "research", to: .done, source: .steward, note: "evidence")
    #expect(raisedBySteward)
    #expect(mutable.steps["research"]?.checkedArtifacts == ["research.md"])

    // Checking a document that does not exist is rejected.
    #expect(throws: DevelopmentProcessError.missingArtifact("prd.md")) {
        _ = try store.setArtifactChecked(true, stepID: "prd", artifact: "prd.md", projectID: projectID)
    }
    // A document that belongs to a different step is rejected.
    #expect(throws: DevelopmentProcessError.unknownStep("prd")) {
        _ = try store.setArtifactChecked(true, stepID: "prd", artifact: "design.md", projectID: projectID)
    }
}

@Test("Step state files written before artifact reviews decode as unchecked")
func stepStateDecodesWithoutCheckedArtifacts() throws {
    let json = #"{"status": "done", "note": "older file", "updatedAt": 815948870.78, "source": "human"}"#
    let state = try JSONDecoder().decode(DevelopmentStepState.self, from: Data(json.utf8))
    #expect(state.status == .done && state.checkedArtifacts == [] && state.source == .human)
}
