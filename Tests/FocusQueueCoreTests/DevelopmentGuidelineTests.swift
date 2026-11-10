import Foundation
import Testing
@testable import FocusQueueCore

private func guidelineFixture() throws -> (root: URL, project: ProjectDefinition, directory: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dev-guidelines-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = ProjectDefinition(id: "demo", name: "Demo", taskPrefix: "DEM", repositoryPath: "/tmp/demo-repo")
    let plan = try ProjectContextStore(root: root).ensurePlan(for: project)
    _ = try DevelopmentProcessStore(root: root).ensure(projectID: project.id)
    return (root, project, plan.deletingLastPathComponent())
}

private let guidelineTicket = DashboardTicket(id: "DEM-001", title: "Draft module files", status: "open",
                                              summary: "Write the module design files.")

@Test("Every bundled guideline is compiled in byte for byte from Config/development-guidelines")
func guidelinesMatchConfig() throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Config/development-guidelines")
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".md") }.sorted()
    #expect(names == DevelopmentGuidelines.fileNames)
    #expect(names.count == 8)
    for name in names {
        let source = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        #expect(DevelopmentGuidelines.text(name) == source, "\(name) drifted from its Config file")
    }
}

@Test("The bundle is project-agnostic: no project names, owners, task IDs, or personal paths")
func guidelinesAreProjectAgnostic() throws {
    // Hash names look like task IDs but are technical terms.
    let allowed: Set<String> = ["SHA-256", "SHA-384", "SHA-512"]
    let taskID = try NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]{1,5}-\d{2,5}\b"#)
    for name in DevelopmentGuidelines.fileNames {
        let text = try #require(DevelopmentGuidelines.text(name))
        let lowered = text.lowercased()
        for word in ["kairos", "haelyra", "/users/", "mac16"] {
            #expect(!lowered.contains(word), "\(name) contains project-specific text: \(word)")
        }
        let ids = taskID.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .filter { !allowed.contains($0) }
        #expect(ids.isEmpty, "\(name) names task IDs: \(ids)")
    }
}

@Test("Prompts come from each guideline's Prompt block with the shared conventions filled")
func guidelinePromptsFillConventions() throws {
    #expect(DevelopmentGuidelines.conventions.hasPrefix("Conventions for every planning file:"))
    for name in DevelopmentGuidelines.fileNames where name != DevelopmentGuidelines.readmeName {
        let prompt = try #require(DevelopmentGuidelines.prompt(name), "\(name) has no prompt block")
        #expect(!prompt.contains("{{CONVENTIONS}}"))
        #expect(prompt.contains("Conventions for every planning file:"))
        #expect(prompt.contains("{{PROJECT}}"))
    }
    #expect(DevelopmentGuidelines.prompt("README.md") == nil)
    // Every guideline the catalog names is bundled.
    let named = DevelopmentProcessCatalog.steps(in: .planning).flatMap { $0.guidelines() }
    #expect(Set(named) == Set(DevelopmentGuidelines.fileNames).subtracting(["README.md"]))
}

@Test("With guidelines off, the file, the PRD step, and briefs are exactly as before")
func guidelinesOffChangesNothing() async throws {
    let (root, project, _) = try guidelineFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    var process = try store.link(taskID: "DEM-001", step: "modules", projectID: project.id)
    let json = String(decoding: try Data(contentsOf: store.url(projectID: project.id)), as: UTF8.self)
    #expect(!json.contains("planningGuidelines") && !json.contains("artifactNames"))
    let prd = try #require(DevelopmentProcessCatalog.step(id: "prd", in: .planning))
    #expect(process.artifacts(of: prd) == ["prd.md"])
    #expect(DevelopmentProcessCatalog.step(forArtifact: "technical-design.md") == nil)
    #expect(process.fileName(forArtifact: "technical-design.md") == "technical-design.md")
    let context = try await TaskContextStore(root: root).ensureContext(ticket: guidelineTicket, project: project)
    #expect(context.planningGuidelineLines().isEmpty)
    #expect(!context.agentPrompt(subtask: TaskSubtask(title: "Modules")).contains("-guideline.md"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("development-guidelines").path))

    // A map set while off has no effect until guidelines are on.
    process.artifactNames = ["technical-design.md": "master.md"]
    #expect(process.fileName(forArtifact: "technical-design.md") == "technical-design.md")
    process = try store.setPlanningGuidelines(false, projectID: project.id)
    #expect(process.planningGuidelines == nil)
}

@Test("A task linked to a Planning step gets exactly one guideline line, pointing at the installed file")
func guidelineBriefLine() async throws {
    let (root, project, _) = try guidelineFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    _ = try store.setPlanningGuidelines(true, projectID: project.id)
    _ = try store.link(taskID: "DEM-001", step: "modules", projectID: project.id)
    let context = try await TaskContextStore(root: root).ensureContext(ticket: guidelineTicket, project: project)
    let installed = root.appendingPathComponent("development-guidelines")
    let expected = "Follow \(installed.appendingPathComponent("module-guideline.md").path) for modules/<id>-<slug>.md."
    #expect(context.planningGuidelineLines() == [expected])
    let agent = TaskSubtask(title: "Modules")
    for brief in [context.agentPrompt(subtask: agent), context.agentBootstrap(subtask: agent)] {
        #expect(brief.components(separatedBy: "\n").filter { $0.hasPrefix("Follow ") && $0.contains("guideline") } == [expected])
        #expect(!brief.contains("Conventions for every planning file"))
    }

    // A linked module names its own file; a two-document step names both in one line.
    let (_, module) = try store.registerModule(name: "Context scoped data", file: nil, projectID: project.id)
    _ = try store.link(taskID: "DEM-001", step: "modules", module: module.name, projectID: project.id)
    #expect(context.planningGuidelineLines().first?.hasSuffix("for modules/m1-context-scoped-data.md.") == true)
    _ = try store.link(taskID: "DEM-001", step: "research", projectID: project.id)
    #expect(context.planningGuidelineLines() == ["Follow \(installed.appendingPathComponent("research-guideline.md").path) for research.md and \(installed.appendingPathComponent("design-guideline.md").path) for design.md."])

    // Contracts have their own generator, and steps after Planning have no guideline.
    _ = try store.link(taskID: "DEM-001", step: "contract", projectID: project.id)
    #expect(context.planningGuidelineLines().isEmpty)
    _ = try store.link(taskID: "DEM-001", step: "scaffolding", projectID: project.id)
    #expect(context.planningGuidelineLines().isEmpty)
}

@Test("Guidelines install read-only and an edited copy is restored to the bundled text")
func guidelinesInstallReadOnly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("guideline-install-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try DevelopmentGuidelines.url("prd-guideline.md", root: root)
    #expect(try String(contentsOf: url, encoding: .utf8) == DevelopmentGuidelines.text("prd-guideline.md"))
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o444)
    #expect(DevelopmentGuidelines.isInstalledGuideline(url, root: root))
    #expect(!DevelopmentGuidelines.isInstalledGuideline(root.appendingPathComponent("prd-guideline.md"), root: root))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    try "edited".write(to: url, atomically: true, encoding: .utf8)
    _ = try DevelopmentGuidelines.install(root: root)
    #expect(try String(contentsOf: url, encoding: .utf8) == DevelopmentGuidelines.text("prd-guideline.md"))
}

@Test("artifactNames maps a catalog document to the project's file for chips, check-off, and step completion")
func artifactNamesResolveCheckOff() throws {
    let (root, project, directory) = try guidelineFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    try "# PRD\n".write(to: directory.appendingPathComponent("prd.md"), atomically: true, encoding: .utf8)
    try "# Master\n".write(to: directory.appendingPathComponent("technical-design-master-plan.md"),
                           atomically: true, encoding: .utf8)
    _ = try store.setPlanningGuidelines(true, projectID: project.id)
    // Unmapped, the guideline-only document is missing and cannot be checked off.
    #expect(throws: DevelopmentProcessError.missingArtifact("technical-design.md")) {
        try store.setArtifactChecked(true, stepID: "prd", artifact: "technical-design.md", projectID: project.id)
    }
    var process = try store.setArtifactName("technical-design-master-plan.md", artifact: "technical-design.md",
                                            projectID: project.id)
    #expect(process.artifactNames == ["technical-design.md": "technical-design-master-plan.md"])
    #expect(try store.artifactURL(projectID: project.id, artifact: "technical-design.md", process: process).lastPathComponent
        == "technical-design-master-plan.md")
    #expect(process.catalogArtifact(forFile: "technical-design-master-plan.md") == "technical-design.md")
    #expect(process.catalogArtifact(forFile: "prd.md") == "prd.md")
    #expect(process.catalogArtifact(forFile: "notes.md") == nil)

    process = try store.setArtifactChecked(true, stepID: "prd", artifact: "prd.md", projectID: project.id)
    #expect(process.steps["prd"]?.status != .done)  // technical-design.md is still unreviewed
    process = try store.setArtifactChecked(true, stepID: "prd", artifact: "technical-design.md", projectID: project.id)
    #expect(process.steps["prd"]?.status == .done)
    #expect(process.steps["prd"]?.checkedArtifacts == ["prd.md", "technical-design.md"])

    #expect(throws: (any Error).self) {
        try store.setArtifactName("../escape.md", artifact: "technical-design.md", projectID: project.id)
    }
    #expect(throws: (any Error).self) {
        try store.setArtifactName("x.md", artifact: "agent-contract.md", projectID: project.id)
    }
    process = try store.setArtifactName(nil, artifact: "technical-design.md", projectID: project.id)
    #expect(process.artifactNames == nil)
}

@Test("Registered modules get stable m<N> IDs and default modules/<id>-<slug>.md files")
func registerModules() throws {
    let (root, project, _) = try guidelineFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    let (_, first) = try store.registerModule(name: "Session engine", file: nil, projectID: project.id)
    #expect(first.id == "m1" && first.file == "modules/m1-session-engine.md")
    let (process, second) = try store.registerModule(name: "Context & scoped data", file: "modules/m6-context.md",
                                                     projectID: project.id)
    #expect(second.id == "m2" && second.file == "modules/m6-context.md")
    #expect(process.modules.map(\.name) == ["Session engine", "Context & scoped data"])
    #expect(DevelopmentGuidelines.moduleFile(id: "M3", name: "  PTY host / daemon ") == "modules/m3-pty-host-daemon.md")
    #expect(throws: (any Error).self) {
        try store.registerModule(name: "session engine", file: nil, projectID: project.id)
    }
    #expect(throws: (any Error).self) {
        try store.registerModule(name: "Escape", file: "/etc/passwd", projectID: project.id)
    }
}
