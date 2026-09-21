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
        #expect(packet.newTaskCommand.contains("--project focus"))
        #expect(packet.requiredParameters == ["task-or-project", "title", "description", "provider", "workspace"])
        #expect(try Data(contentsOf: fixture.dashboard) == beforeDashboard)
        #expect(try await TaskContextStore(root: fixture.support).loadAll() == beforeContexts)
        #expect(try AgentRouteStore(root: fixture.support).load(routeID: packet.routeID)?.prompt == "Fix exact session recall")
        await #expect(throws: TaskContextError.self) {
            try await AgentRouteCoordinator(root: fixture.support).inspect(
                .init(prompt: "  ", provider: .codex, source: source),
                configuration: fixture.configuration)
        }
    }

    @Test("Existing task routing trusts its unique dashboard project instead of its ID prefix")
    func dashboardOwnsTaskPlacement() async throws {
        let fixture = try await RoutingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var mismatched = try #require(
            fixture.configuration.projects.first { $0.id == "focus" })
        mismatched.taskPrefix = "ECC"

        let location = try await AgentRouteTaskLocator.locate(
            taskID: "FOC-001", projects: [mismatched])

        #expect(location.project.id == "focus")
        #expect(location.ticket.id == "FOC-001")
        #expect(location.ticket.title == "Exact session recall")
    }

    @Test("Provider model and effort are persisted and passed as literal arguments")
    func launchProfile() throws {
        let context = TaskContext(
            ticketID: "FOC-1", title: "Routing", summary: "", successCriteria: "Registered",
            planPath: "/tmp/focus/tasks/FOC-1/plan.md", worktreePath: "/tmp/worktree",
            updatedAt: Date())
        var codex = TaskSubtask(title: "Route Codex", provider: .codex)
        codex.launchConfiguration = AgentLaunchConfiguration(
            routeID: "11111111-2222-4333-8444-555555555555", model: "gpt-5", effort: "high",
            providerVersion: "codex-cli 1.2.3")
        let persisted = try JSONDecoder().decode(
            TaskSubtask.self, from: JSONEncoder().encode(codex))
        #expect(persisted.launchConfiguration == codex.launchConfiguration)
        let codexCommand = try TaskAgentLauncher.command(
            context: context, subtask: persisted,
            supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(codexCommand.contains(["--model", "gpt-5"]))
        #expect(codexCommand.contains(["-c", "model_reasoning_effort=high"]))
        #expect(codexCommand.contains("FOCUS_QUEUE_LAUNCH_ID=11111111-2222-4333-8444-555555555555"))
        #expect(codexCommand.contains("FOCUS_QUEUE_AGENT_CONTEXT=/tmp/support/tracking/placements/11111111-2222-4333-8444-555555555555.json"))
        #expect(context.agentPrompt(subtask: persisted).contains(
            "/tmp/focus/logs/agent-startups/FOC-1/\(persisted.id.lowercased()).json"))

        var claude = TaskSubtask(title: "Route Claude", provider: .claude)
        claude.launchConfiguration = .init(
            routeID: "22222222-3333-4444-8555-666666666666", model: "opus", effort: "max",
            providerVersion: "2.1.0")
        let claudeCommand = try TaskAgentLauncher.command(
            context: context, subtask: claude,
            supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(claudeCommand.contains(["--model", "opus"]))
        #expect(claudeCommand.contains(["--effort", "max"]))
    }

    @Test("A route can be claimed only once before any provider starts")
    func routeClaim() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("route-claim-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let routeID = UUID().uuidString.lowercased()
        let store = AgentRouteStore(root: root)
        try store.save(.init(routeID: routeID, prompt: "Route once", provider: .codex,
                             source: .init(cwd: "/repo"), inferredProjectID: "focus",
                             repositoryPath: "/repo"))
        try store.claim(routeID: routeID, subtaskID: "agent-one")
        #expect(throws: TaskContextError.self) {
            try store.claim(routeID: routeID, subtaskID: "agent-two")
        }
        try store.setDestination(routeID: routeID, taskID: "FOC-1")
        #expect(throws: TaskContextError.self) {
            try store.setDestination(routeID: routeID, taskID: "FOC-2")
        }
        let loaded = try store.load(routeID: routeID)
        let claimed = try #require(loaded)
        #expect(claimed.subtaskID == "agent-one")
        #expect(claimed.taskID == "FOC-1")
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
            routeID: "r1", status: .launched, projectID: "focus", projectName: "Focus Queue",
            taskID: "FOC-1", taskTitle: "Exact recall", subtaskID: "a1",
            title: "Fix recall", description: "Make exact recovery deterministic",
            provider: .codex, model: "gpt-5", effort: "high", providerVersion: "codex-cli 1.2.3",
            promptByteCount: 19, promptSHA256: String(repeating: "a", count: 64),
            workspace: workspace, runtime: .init(
                mode: .tmux, tmuxExecutable: "/opt/homebrew/bin/tmux",
                tmuxServerName: "focus-queue", tmuxName: "fq-task-foc-1",
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
        let loaded = try store.load(taskID: "FOC-1", subtaskID: "a1")
        let registered = try #require(loaded)
        #expect(registered.status == .registered)
        #expect(registered.providerSessionID == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        #expect(registered.projectID == "focus")
        #expect(registered.taskTitle == "Exact recall")
        #expect(registered.providerResumeCommand?.prefix(3) == ["codex", "resume", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"])
        #expect(registered.runtime.attachCommand == receipt.runtime.attachCommand)
        #expect(registered.context == context)
        #expect(AgentStartupReceipt.promptDigest("abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(throws: TaskContextError.self) {
            _ = try store.url(taskID: "../FOC-1", subtaskID: "a1")
        }

        var claude = receipt
        claude.subtaskID = "a2"
        claude.provider = .claude
        claude.model = "opus"
        claude.effort = "max"
        try store.save(claude)
        try store.register(
            taskID: "FOC-1", subtaskID: "a2",
            providerSessionID: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")
        let loadedClaude = try store.load(taskID: "FOC-1", subtaskID: "a2")
        let claudeLoaded = try #require(loadedClaude)
        #expect(claudeLoaded.providerResumeCommand?.prefix(3)
            == ["claude", "--resume", "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"])
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
