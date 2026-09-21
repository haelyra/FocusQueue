import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Automatic agent routing")
struct AgentRoutingTests {
    @Test("Legacy configuration is opt-out and the routing preference round-trips")
    func configurationCompatibility() throws {
        let legacy = SetupEnvironment.starter(
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let legacyData = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: legacyData)
        #expect(decoded.automaticAgentRouting == false)

        var enabled = decoded
        enabled.automaticAgentRouting = true
        let roundTrip = try JSONDecoder().decode(
            AppConfiguration.self, from: JSONEncoder().encode(enabled))
        #expect(roundTrip.automaticAgentRouting == true)
    }

    @Test("Inspection is read-only and returns enough information for one start command")
    func inspectRoute() async throws {
        let fixture = try await RoutingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let beforeDashboard = try Data(contentsOf: fixture.dashboard)
        let beforeContexts = try await TaskContextStore(root: fixture.support).loadAll()
        let source = AgentRouteSource(
            providerSessionID: "11111111-2222-4333-8444-555555555555",
            cwd: fixture.repository.path, tmuxName: "router", tmuxPaneID: "%7",
            terminalPaneID: 91, terminalSocketPath: "/tmp/wez.sock")

        let packet = try await AgentRouteCoordinator(root: fixture.support).inspect(
            .init(prompt: "Fix exact session recall", provider: .codex, source: source),
            configuration: fixture.configuration)

        #expect(packet.status == .ready)
        #expect(packet.automaticRoutingEnabled)
        #expect(packet.inferredProjectID == "focus")
        #expect(packet.repositoryPath == fixture.repository.path)
        #expect(packet.candidates.map(\.taskID) == ["FOC-001"])
        #expect(packet.candidates.first?.taskPlanPath.hasSuffix("tasks/FOC-001/plan.md") == true)
        #expect(packet.projectPlanPath?.hasSuffix("projects/focus/plan.md") == true)
        #expect(packet.startCommand.hasPrefix("focus-queue-session route start \(packet.routeID) "))
        #expect(try Data(contentsOf: fixture.dashboard) == beforeDashboard)
        #expect(try await TaskContextStore(root: fixture.support).loadAll() == beforeContexts)
        #expect(try AgentRouteStore(root: fixture.support).load(routeID: packet.routeID)?.prompt == "Fix exact session recall")
    }

    @Test("Provider model and effort are persisted and passed as literal arguments")
    func launchProfile() throws {
        let context = TaskContext(
            ticketID: "FOC-1", title: "Routing", summary: "", successCriteria: "Registered",
            planPath: "/tmp/focus/tasks/FOC-1/plan.md", worktreePath: "/tmp/worktree",
            updatedAt: Date())
        var codex = TaskSubtask(title: "Route Codex", provider: .codex)
        codex.launchConfiguration = AgentLaunchConfiguration(
            routeID: "route-1", model: "gpt-5", effort: "high", providerVersion: "codex-cli 1.2.3")
        let persisted = try JSONDecoder().decode(
            TaskSubtask.self, from: JSONEncoder().encode(codex))
        #expect(persisted.launchConfiguration == codex.launchConfiguration)
        let codexCommand = try TaskAgentLauncher.command(
            context: context, subtask: persisted,
            supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(codexCommand.contains(["--model", "gpt-5"]))
        #expect(codexCommand.contains(["-c", "model_reasoning_effort=high"]))

        var claude = TaskSubtask(title: "Route Claude", provider: .claude)
        claude.launchConfiguration = .init(
            routeID: "route-2", model: "opus", effort: "max", providerVersion: "2.1.0")
        let claudeCommand = try TaskAgentLauncher.command(
            context: context, subtask: claude,
            supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(claudeCommand.contains(["--model", "opus"]))
        #expect(claudeCommand.contains(["--effort", "max"]))
    }

    @Test("The concise startup receipt becomes an exact recovery locator at registration")
    func startupReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("route-receipt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStartupReceiptStore(root: root)
        let workspace = AgentWorkspace(
            path: "/repo-worktrees/foc-1/agents/a1", repositoryPath: "/repo",
            branch: "focus-queue/foc-1-a1", baseBranch: "main", baseCommit: "abc123",
            managed: true, gitDirectory: "/repo/.git/worktrees/a1", repositoryIdentity: "repo-id")
        let context = AgentStartupContextPaths(
            capsule: "/support/placements/r1.json", projectPlan: "/support/projects/focus/plan.md",
            taskPlan: "/support/tasks/FOC-1/plan.md", taskContext: "/support/tasks/FOC-1/context.json",
            taskLog: "/support/tasks/FOC-1/agent-log.md")
        let receipt = AgentStartupReceipt(
            routeID: "r1", status: .launched, taskID: "FOC-1", subtaskID: "a1",
            title: "Fix recall", description: "Make exact recovery deterministic",
            provider: .codex, model: "gpt-5", effort: "high", providerVersion: "codex-cli 1.2.3",
            promptByteCount: 19, promptSHA256: String(repeating: "a", count: 64),
            workspace: workspace, runtime: .init(
                mode: .tmux, tmuxServerName: "focus-queue", tmuxName: "fq-task-foc-1",
                tmuxPaneID: "%3", tmuxPanePID: 111, tty: "/dev/ttys003",
                terminalApplication: "Terminal", terminalPaneID: nil, terminalSocketPath: nil,
                attachCommand: ["tmux", "-L", "focus-queue", "attach", "-t", "fq-task-foc-1"]),
            context: context, source: .init(providerSessionID: "router-id", cwd: "/repo"))
        let url = try store.save(receipt)
        #expect(url.lastPathComponent == "a1.json")
        #expect(try Data(contentsOf: url).count < 8_192)
        #expect(try String(contentsOf: url).contains("Make exact recovery deterministic"))
        #expect(!String(data: try Data(contentsOf: url), encoding: .utf8)!.contains("fullInitialPrompt"))

        try store.register(
            taskID: "FOC-1", subtaskID: "a1",
            providerSessionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let registered = try #require(store.load(taskID: "FOC-1", subtaskID: "a1"))
        #expect(registered.status == .registered)
        #expect(registered.providerSessionID == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        #expect(registered.runtime.attachCommand == receipt.runtime.attachCommand)
        #expect(registered.context == context)
    }
}

private extension Array where Element == String {
    func contains(_ consecutive: [String]) -> Bool {
        guard !consecutive.isEmpty, consecutive.count <= count else { return false }
        return indices.contains { start in
            let end = index(start, offsetBy: consecutive.count, limitedBy: endIndex) ?? endIndex
            return end - start == consecutive.count && Array(self[start..<end]) == consecutive
        }
    }
}

private struct RoutingFixture {
    let root: URL
    let support: URL
    let repository: URL
    let dashboard: URL
    let configuration: AppConfiguration

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-route-\(UUID())")
        support = root.appendingPathComponent("support")
        repository = root.appendingPathComponent("repository")
        try SetupEnvironment.createStarterWorkspace(supportDirectory: support)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let runner = FoundationProcessRunner()
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"],
        ] {
            let result = try await runner.run(.init(
                executable: "/usr/bin/git", arguments: arguments, workingDirectory: repository.path))
            guard result.succeeded else { throw TaskContextError.commandFailed(result.standardError) }
        }
        var configuration = SetupEnvironment.starter(supportDirectory: support)
        let project = ProjectDefinition(
            id: "focus", name: "Focus", dashboardPath: configuration.dashboardPath,
            workspacePath: repository.path, taskPrefix: "FOC", repositoryPath: repository.path)
        configuration.projects = ProjectCatalog.ensuringOther(
            in: [project], supportDirectory: support)
        configuration.selectedProjectID = "focus"
        configuration.automaticAgentRouting = true
        self.configuration = try configuration.validated()
        dashboard = URL(fileURLWithPath: self.configuration.dashboardPath)
        let taskID = try ProjectTaskStore(dashboardURL: dashboard, supportDirectory: support)
            .create(title: "Exact session recall", summary: "Restore the precise runtime", project: project)
        let document = try await JSONDashboardRepository().load(from: dashboard)
        let ticket = try #require(document.tickets.first { $0.id == taskID })
        _ = try await TaskContextStore(root: support).ensureContext(ticket: ticket, project: project)
    }
}
