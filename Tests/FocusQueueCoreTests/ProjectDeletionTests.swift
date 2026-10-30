import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Project deletion")
struct ProjectDeletionTests {
    @Test("Deletion preserves unknown config fields, other queue bytes, external dashboards and working folders", arguments: ["private", "external", "shared", "symlink", "workspace"])
    func preservesUnrelatedData(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("projects/remove")
        let workspace = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let external = mode != "private"
        let dashboard = (mode == "external" ? workspace : directory).appendingPathComponent("dashboard.json")
        let bytes = Data("{\"tickets\":[],\"unknown\":42}".utf8)
        if mode == "symlink" {
            let target = workspace.appendingPathComponent("dashboard.json")
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(at: dashboard, withDestinationURL: target)
        } else { try bytes.write(to: dashboard) }
        let configURL = root.appendingPathComponent("config.json")
        var config = SetupEnvironment.starter(supportDirectory: root)
        config.projects = ProjectCatalog.ensuringOther(in: [], supportDirectory: root)
        let project = ProjectDefinition(id: "remove", name: "Remove", dashboardPath: dashboard.path,
            workspacePath: mode == "workspace" ? directory.path : workspace.path,
            taskPrefix: "REM", repositoryPath: workspace.path)
        if mode == "shared" { config.projects[0].dashboardPath = dashboard.path }
        config.projects.append(project)
        _ = config.selectProject(id: project.id)
        try await JSONConfigurationRepository(url: configURL).save(config)
        let otherDashboard = URL(fileURLWithPath: config.projects[0].dashboardPath)
        try FileManager.default.createDirectory(at: otherDashboard.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: otherDashboard)
        let state = root.appendingPathComponent("state.json")
        try Data("{\"queueOrder\":[\"KEEP-001\"]}".utf8).write(to: state)
        let stateBytes = try Data(contentsOf: state)
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        raw["future"] = ["keep": 42]
        var projects = try #require(raw["focusQueueProjects"] as? [[String: Any]])
        projects[0]["futureProjectField"] = "keep"
        raw["focusQueueProjects"] = projects
        try JSONSerialization.data(withJSONObject: raw).write(to: configURL)
        let plan = directory.appendingPathComponent("plan.md")
        try Data("authored".utf8).write(to: plan)
        let result = try ProjectDeletion(supportDirectory: root, configurationURL: configURL).delete(projectID: "remove")
        #expect(result.selectedProjectID == ProjectCatalog.otherID)
        #expect(result.projects.count == 1)
        #expect(try Data(contentsOf: otherDashboard) == bytes)
        #expect(try Data(contentsOf: state) == stateBytes)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        #expect((saved["future"] as? [String: Int])?["keep"] == 42)
        #expect((saved["focusQueueProjects"] as? [[String: Any]])?.first?["futureProjectField"] as? String == "keep")
        #expect(try String(contentsOf: plan, encoding: .utf8) == "authored")
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        #expect(FileManager.default.fileExists(atPath: dashboard.path) == external)
        if external { #expect(try Data(contentsOf: dashboard) == bytes) }
    }
    @Test("Active tasks and damaged queues refuse deletion without modifying storage", arguments: [false, true])
    func rejectsUnsafeDeletion(damaged: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("projects/remove")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dashboard = directory.appendingPathComponent("dashboard.json")
        let bytes = Data((damaged ? "invalid" : "{\"tickets\":[{\"id\":\"REM-001\",\"title\":\"Active\",\"status\":\"in-progress\"}]}").utf8)
        try bytes.write(to: dashboard)
        var config = SetupEnvironment.starter(supportDirectory: root)
        config.projects = ProjectCatalog.ensuringOther(in: [], supportDirectory: root)
        config.projects.append(ProjectDefinition(id: "remove", name: "Remove", dashboardPath: dashboard.path,
            workspacePath: root.appendingPathComponent("source").path, taskPrefix: "REM", repositoryPath: ""))
        let url = root.appendingPathComponent("config.json")
        try await JSONConfigurationRepository(url: url).save(config)
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) {
            try ProjectDeletion(supportDirectory: root, configurationURL: url).delete(projectID: "remove")
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try Data(contentsOf: dashboard) == bytes)
    }

}
