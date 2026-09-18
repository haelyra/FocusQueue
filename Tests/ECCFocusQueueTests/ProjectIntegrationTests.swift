import AppKit
import Foundation
import FocusQueueCore
import SwiftUI
import Testing
@testable import ECCFocusQueue

private actor ProjectChatRecorder: QueueAgentChatting {
    var requests: [(String, [String], String?)] = []
    func send(message: String, dashboardPath: String, workspace: String, visibleOrder: [String],
              deferredTicketIDs: [String], configuration: VerifierConfiguration) async throws -> QueueAgentReply {
        requests.append((message, visibleOrder, configuration.projectScopeID))
        return QueueAgentReply(message: "Scope checked", log: "")
    }
}

@Suite("Project workflow")
@MainActor
struct ProjectIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECC_PROJECT_SNAPSHOT_ROOT"] != nil))
    func copiedDashboardSanity() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ECC_PROJECT_SNAPSHOT_ROOT"])
        let root = URL(fileURLWithPath: path)
        // This explicitly supplied fixture is an isolated copy; it never points at the live support directory.
        #expect(root.lastPathComponent.hasPrefix("ecc-project-render-snapshot-"))
        let model = QueueViewModel(paths: .live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": path]),
            discoverExternalAgents: { [] }, locateExistingAgent: { _, _ in nil })
        await model.bootstrap()
        #expect(model.loadError == nil)
        let total = model.dashboard.tickets.count
        model.selectProject("ecc-focus-queue")
        #expect(model.projectTickets.map(\.id) == ["ECC-035"])
        #expect(model.openTickets.first?.id == "ECC-035")
        model.selectProject("ecc")
        #expect(model.projectTickets.count == total - 1)
        #expect(!model.projectTickets.contains { $0.id == "ECC-035" })
        let exception = try #require(model.projectTickets.first { $0.id == "ECC-044" })
        #expect(exception.worktree?.hasSuffix("ECCFocusQueue") == true)
        model.revealReportTask("ECC-035")
        #expect(model.selectedProjectID == "ecc-focus-queue")
        for scope in [nil, "ecc-focus-queue", "ecc"] as [String?] {
            model.selectProject(scope)
            let host = NSHostingView(rootView: QueueView(model: model).frame(width: 440, height: 950))
            host.frame = NSRect(x: 0, y: 0, width: 440, height: 950)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("render-\(scope ?? "all").png"))
        }
        print("PROJECT_WORKFLOW_SANITY: \(total) preserved tasks; Focus Queue=1; ECC=\(total - 1); cross-repository workspace retained; report navigation changes scope; all three views rendered offscreen.")
    }

    @Test func selectionPersistenceNotificationsAndDeepLinks() async throws {
        let f = try await ProjectFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = await f.model()
        #expect(model.openTickets.count == 4)
        #expect(model.agentUpdates.count == 2)
        model.selectProject("focus")
        #expect(model.openTickets.map(\.id) == ["ECC-035"])
        #expect(model.completedTickets.map(\.id) == ["ECC-034"])
        #expect(model.agentUpdates.map(\.ticketID) == ["ECC-035"])
        #expect(model.visibleRoutines.map(\.id) == ["global"])
        #expect(model.showsReportNotification)
        try await Task.sleep(for: .milliseconds(80))
        let restarted = await f.model()
        #expect(restarted.selectedProjectID == "focus")
        restarted.revealReportTask("ECC-044")
        #expect(restarted.selectedProjectID == "ecc")
        #expect(restarted.openTickets.map(\.id) == ["ECC-044"])
        #expect(restarted.defaultRepository(for: f.tickets[1]) == "/existing-cross-repository-worktree")
        restarted.selectProject(ProjectCatalog.otherID)
        #expect(Set(restarted.openTickets.map(\.id)) == ["ECC-040", "ECC-041"])
        restarted.selectProject(nil)
        #expect(restarted.agentUpdates.count == 2)
        #expect(restarted.localState.dismissedNotificationIDs.isEmpty)
    }

    @Test func managementCreationAndScopedChat() async throws {
        let f = try await ProjectFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let agent = ProjectChatRecorder(), model = await f.model(agent: agent)
        model.selectProject("focus")
        #expect(model.sendQueueAgentMessage("Explain these tasks"))
        for _ in 0..<100 where model.isQueueAgentResponding { try await Task.sleep(for: .milliseconds(10)) }
        let request = try #require(await agent.requests.first)
        #expect(request.1 == ["ECC-035"] && request.2 == "focus")
        #expect(request.0.contains("Allowed task IDs: ECC-035, ECC-034"))
        #expect(!request.0.contains("ECC-044"))
        var renamed = f.projects[0]; renamed.name = "Focus renamed"
        #expect(await model.saveProject(renamed))
        #expect(model.projectScopeName == "Focus renamed")
        let context = try #require(try await TaskContextStore(root: f.root).load(ticketID: "ECC-035"))
        #expect(context.projectName == "Focus renamed")
        #expect(context.projectRepositoryPath == f.root.path)
        #expect(await model.createTask(title: "New project task", summary: "", projectID: "focus"))
        #expect(model.openTickets.contains { $0.id == "FOC-001" && $0.title == "New project task" && $0.projectID == "focus" })
        #expect(await model.assignProject("ecc", to: "ECC-035"))
        #expect(!model.openTickets.contains { $0.id == "ECC-035" })
        var archived = f.projects[1]; archived.archivedAt = Date()
        #expect(await !model.saveProject(archived))
        let empty = ProjectDefinition(id: "empty", name: "Empty", repositoryPath: f.root.path)
        #expect(await model.saveProject(empty))
        model.selectProject("empty")
        #expect(model.openTickets.isEmpty)
        var archiveEmpty = empty; archiveEmpty.archivedAt = Date()
        #expect(await model.saveProject(archiveEmpty))
        #expect(model.selectedProjectID == nil)
    }

    @Test func renderedQueueScopes() async throws {
        let f = try await ProjectFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = await f.model()
        for scope in [nil, "focus", "ecc", ProjectCatalog.otherID] as [String?] {
            model.selectProject(scope)
            for width in [CGFloat(440), CGFloat(620)] {
                let host = NSHostingView(rootView: QueueView(model: model).frame(width: width, height: 900))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                host.layoutSubtreeIfNeeded()
                let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let data = try #require(image.representation(using: .png, properties: [:]))
                #expect(!data.isEmpty)
                if let output = ProcessInfo.processInfo.environment["ECC_PROJECT_RENDER_DIR"] {
                    let directory = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent("\(scope ?? "all")-\(Int(width)).png"))
                }
            }
        }
    }
}

@MainActor
private struct ProjectFixture {
    let root: URL
    let paths: AppPaths
    let tickets: [DashboardTicket]
    let projects: [ProjectDefinition]
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID())")
        try SetupEnvironment.createStarterWorkspace(supportDirectory: root)
        paths = AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path])
        projects = [ProjectDefinition(id: "focus", name: "ECC Focus Queue", repositoryPath: root.path),
                    ProjectDefinition(id: "ecc", name: "ECC", repositoryPath: root.path)]
        tickets = [
            DashboardTicket(id: "ECC-035", title: "Focus task", projectID: "focus", status: "in-progress", summary: "Focus work"),
            DashboardTicket(id: "ECC-044", title: "ECC task", projectID: "ecc", status: "in-progress", summary: "ECC work", worktree: "/existing-cross-repository-worktree"),
            DashboardTicket(id: "ECC-034", title: "Completed focus task", projectID: "focus", status: "resolved", summary: "Done"),
            DashboardTicket(id: "ECC-040", title: "Unassigned task", status: "backlog", summary: "Waiting"),
            DashboardTicket(id: "ECC-041", title: "Unknown project task", projectID: "missing", status: "backlog", summary: "Retained")]
        var config = SetupEnvironment.starter(supportDirectory: root)
        config.projects = projects; config.setupCompleted = true; config.refreshIntervalSeconds = 300
        config.dailyRoutines = [.init(id: "ecc-pr", title: "ECC PRs", projectID: "ecc"), .init(id: "global", title: "Global routine")]
        try JSONEncoder().encode(DashboardDocument(tickets: tickets)).write(to: URL(fileURLWithPath: config.dashboardPath))
        try await JSONConfigurationRepository(url: paths.configurationFile).save(config)
        let store = TaskContextStore(root: root)
        for ticket in tickets.prefix(2) {
            _ = try await store.ensureContext(ticket: ticket)
            _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: TaskSubtask(id: "agent", title: "Agent", status: .working,
                progressSummary: "Update for \(ticket.title)", completionUnread: true))
        }
    }
    func model(agent: ProjectChatRecorder = ProjectChatRecorder()) async -> QueueViewModel {
        let model = QueueViewModel(paths: paths, queueAgent: agent, discoverExternalAgents: { [] }, locateExistingAgent: { _, _ in nil })
        await model.bootstrap()
        #expect(model.loadError == nil)
        return model
    }
}
