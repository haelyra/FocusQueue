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

    @Test("Older configured model choices gain new built-in providers and keep custom entries")
    func modelChoiceMigration() throws {
        let starter = SetupEnvironment.starter(
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(starter)) as? [String: Any])
        object["agentModelChoices"] = [
            ["provider": "codex", "label": "Default"],
            ["provider": "codex", "label": "gpt-5.5", "model": "gpt-5.5"],
            ["provider": "codex", "label": "Custom build", "model": "custom-model"],
        ]
        let decoded = try JSONDecoder().decode(
            AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.agentModelChoices.contains(
            AgentModelChoice(provider: .kimi, label: "K3", model: "kimi-code/k3")))
        #expect(decoded.agentModelChoices.contains(
            AgentModelChoice(provider: .codex, label: "Custom build", model: "custom-model")))
        #expect(decoded.agentModelChoices.first == AgentModelChoice(provider: .codex, label: "Default"))
        #expect(decoded.agentModelChoices.last == AgentModelChoice(
            provider: .codex, label: "Custom build", model: "custom-model"))
    }

    @Test("Default agent efforts survive a configuration round-trip")
    func defaultAgentEffortRoundTrip() throws {
        var configuration = AppConfiguration.eccDefault()
        configuration.defaultAgentEfforts[.claude] = "high"
        let decoded = try JSONDecoder().decode(
            AppConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(decoded.defaultAgentEfforts[.claude] == "high")
        #expect(decoded.defaultAgentEfforts[.codex] == nil)
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

    @Test("An objective naming a project routes to it even from another project's repository")
    func promptMentionSelectsProject() async throws {
        let fixture = try await RoutingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (configuration, eccRepository) = try await fixture.addingProject(
            id: "ecc", name: "ECC", prefix: "ECC")

        let packet = try await AgentRouteCoordinator(root: fixture.support).inspect(
            .init(prompt: "Resolve the open ECC PRs", provider: .codex,
                  source: .init(cwd: fixture.repository.path, tmuxName: "router")),
            configuration: configuration)

        #expect(packet.inferredProjectID == "ecc")
        #expect(packet.repositoryPath == eccRepository.path)
        #expect(packet.newTaskCommand.contains("--project ecc"))
        #expect(packet.projects.map(\.id).contains("focus"))
        #expect(packet.projects.map(\.id).contains("ecc"))
        #expect(packet.projects.map(\.id).contains("other"))
        // A ticket ID names its project through the prefix.
        let byTicket = try await AgentRouteCoordinator(root: fixture.support).inspect(
            .init(prompt: "Finish ECC-041 before Friday", provider: .codex,
                  source: .init(cwd: fixture.repository.path, tmuxName: "router")),
            configuration: configuration)
        #expect(byTicket.inferredProjectID == "ecc")
    }

    @Test("An objective naming two projects falls back to launch-directory inference")
    func ambiguousPromptFallsBackToCwd() async throws {
        let fixture = try await RoutingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (configuration, _) = try await fixture.addingProject(id: "ecc", name: "ECC", prefix: "ECC")

        let packet = try await AgentRouteCoordinator(root: fixture.support).inspect(
            .init(prompt: "Sync the ECC changes into Focus", provider: .codex,
                  source: .init(cwd: fixture.repository.path, tmuxName: "router")),
            configuration: configuration)

        #expect(packet.inferredProjectID == "focus")
    }

    @Test("An objective with no project signal lands in Other with the launch directory recorded")
    func noSignalGoesToOther() async throws {
        let fixture = try await RoutingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plain = fixture.root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let packet = try await AgentRouteCoordinator(root: fixture.support).inspect(
            .init(prompt: "Organize the vacation photos", provider: .codex,
                  source: .init(cwd: plain.path, tmuxName: "router")),
            configuration: fixture.configuration)

        #expect(packet.inferredProjectID == "other")
        #expect(packet.repositoryPath == plain.path)
    }

    @Test("A failed launch can roll back only its own unclaimed routed task and destination")
    func routeRollbackPrimitives() async throws {
        let fixture = try await RoutingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ProjectTaskStore(dashboardURL: fixture.dashboard, supportDirectory: fixture.support)
        let project = try #require(fixture.configuration.projects.first { $0.id == "focus" })
        let routeID = UUID().uuidString.lowercased()
        let created = try store.create(title: "Routed", summary: "s", project: project, routeID: routeID)

        // A different route must not remove it.
        try store.removeUnclaimedRouteTask(ticketID: created, routeID: UUID().uuidString.lowercased())
        var document = try await JSONDashboardRepository().load(from: fixture.dashboard)
        #expect(document.tickets.contains { $0.id == created })

        // The owning route removes it while the marker is intact.
        try store.removeUnclaimedRouteTask(ticketID: created, routeID: routeID)
        document = try await JSONDashboardRepository().load(from: fixture.dashboard)
        #expect(!document.tickets.contains { $0.id == created })

        // clearDestination only clears a matching destination.
        let routeStore = AgentRouteStore(root: fixture.support)
        let packet = try await AgentRouteCoordinator(root: fixture.support).inspect(
            .init(prompt: "Roll back a failed launch", provider: .codex,
                  source: .init(cwd: fixture.repository.path, tmuxName: "router")),
            configuration: fixture.configuration)
        try routeStore.claim(routeID: packet.routeID, subtaskID: UUID().uuidString.lowercased())
        try routeStore.setDestination(routeID: packet.routeID, taskID: "FOC-900")
        try routeStore.clearDestination(routeID: packet.routeID, taskID: "FOC-901")
        #expect(try routeStore.load(routeID: packet.routeID)?.taskID == "FOC-900")
        try routeStore.clearDestination(routeID: packet.routeID, taskID: "FOC-900")
        #expect(try routeStore.load(routeID: packet.routeID)?.taskID == nil)
    }

    @Test("An explicit queue composer route remains available when shell interception is disabled")
    func explicitComposerRoute() async throws {
        let fixture = try await RoutingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var configuration = fixture.configuration
        configuration.automaticAgentRouting = false
        let objective = "Add a router prompt above the focus queue"
        let capability = UUID().uuidString.lowercased()
        try QueueRouterRuntimeStore(root: fixture.support).save(try .init(
            tmuxName: "fq-router-test", tmuxExecutable: "/mock/tmux", startedAt: Date(),
            capability: capability,
            objectiveSHA256: AgentStartupReceipt.promptDigest(objective)))

        let packet = try await AgentRouteCoordinator(root: fixture.support).inspect(
            .init(
                prompt: objective,
                provider: .codex,
                source: .init(cwd: fixture.repository.path, tmuxName: "fq-router-test"),
                origin: .queueComposer, composerCapability: capability),
            configuration: configuration)

        #expect(packet.status == .ready)
        #expect(packet.automaticRoutingEnabled == false)
        let intent = try #require(try AgentRouteStore(root: fixture.support).load(routeID: packet.routeID))
        #expect(intent.origin == .queueComposer)
        #expect(intent.composerCapability == capability)
        #expect(intent.allowsRouting(automaticAgentRouting: false))
        await #expect(throws: TaskContextError.self) {
            try await AgentRouteCoordinator(root: fixture.support).inspect(
                .init(
                    prompt: objective, provider: .codex,
                    source: .init(cwd: fixture.repository.path, tmuxName: "fq-router-test"),
                    origin: .queueComposer, composerCapability: capability),
                configuration: configuration)
        }
    }

    @Test("A failed composer inspection releases its one-use claim for one safe retry")
    func composerInspectionFailureReleasesClaim() async throws {
        let fixture = try await RoutingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let objective = "Retry inspection after a damaged dashboard"
        let capability = UUID().uuidString.lowercased()
        try QueueRouterRuntimeStore(root: fixture.support).save(try .init(
            tmuxName: "fq-router-retry", tmuxExecutable: "/mock/tmux", startedAt: Date(),
            capability: capability,
            objectiveSHA256: AgentStartupReceipt.promptDigest(objective)))
        let dashboard = try Data(contentsOf: fixture.dashboard)
        try Data("not-json".utf8).write(to: fixture.dashboard, options: .atomic)
        let request = AgentRouteInspectionRequest(
            prompt: objective, provider: .codex,
            source: .init(cwd: fixture.repository.path, tmuxName: "fq-router-retry"),
            origin: .queueComposer, composerCapability: capability)

        await #expect(throws: Error.self) {
            try await AgentRouteCoordinator(root: fixture.support).inspect(
                request, configuration: fixture.configuration)
        }
        #expect(try QueueRouterRuntimeStore(root: fixture.support).load()?.claimedRouteID == nil)
        try dashboard.write(to: fixture.dashboard, options: .atomic)
        let inspection = try await AgentRouteCoordinator(root: fixture.support).inspect(
            request, configuration: fixture.configuration)
        #expect(inspection.status == .ready)
        #expect(try QueueRouterRuntimeStore(root: fixture.support).load()?.claimedRouteID
            == inspection.routeID)
    }

    @Test("Legacy route intents remain governed by the automatic routing preference")
    func legacyRouteOrigin() throws {
        let routeID = UUID().uuidString.lowercased()
        let legacy = """
        {
          "schemaVersion": 1,
          "routeID": "\(routeID)",
          "prompt": "Legacy route",
          "provider": "codex",
          "source": {"cwd": "/repo"},
          "createdAt": "2026-09-23T12:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let intent = try decoder.decode(AgentRouteIntent.self, from: Data(legacy.utf8))

        #expect(intent.origin == .automaticShell)
        #expect(!intent.allowsRouting(automaticAgentRouting: false))
        #expect(intent.allowsRouting(automaticAgentRouting: true))
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

    @Test("A pre-receipt launch failure can retry without changing its destination or agent")
    func failedClaimRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("route-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let routeID = UUID().uuidString
        let store = AgentRouteStore(root: root)
        _ = try store.save(AgentRouteIntent(
            routeID: routeID, prompt: "Retry safely", provider: .codex,
            source: .init(cwd: "/tmp/repo"), inferredProjectID: "focus",
            repositoryPath: "/tmp/repo"))

        try store.claim(routeID: routeID, subtaskID: "agent-one")
        try store.setDestination(routeID: routeID, taskID: "FOC-1")
        try store.releaseClaim(routeID: routeID, subtaskID: "another-agent")
        #expect(try store.load(routeID: routeID)?.startedAt != nil)
        try store.releaseClaim(routeID: routeID, subtaskID: "agent-one")

        let released = try #require(try store.load(routeID: routeID))
        #expect(released.startedAt == nil)
        #expect(released.taskID == "FOC-1")
        #expect(released.subtaskID == "agent-one")
        try store.claim(routeID: routeID, subtaskID: "agent-one")
        #expect(try store.load(routeID: routeID)?.startedAt != nil)
    }

    @Test("An unconfirmed tmux start retains its route claim to prevent duplicate agents")
    func uncertainStartRetainsClaim() {
        #expect(TmuxError.startedButUnconfirmed(
            name: "fq-task", executable: "/opt/homebrew/bin/tmux",
            attempts: 1, lastDetail: "pane still starting").mayHaveStarted)
        #expect(!TmuxError.unavailable("tmux is missing").mayHaveStarted)
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
                tmuxServerPID: 101, tmuxCreatedAt: 102,
                tmuxPaneID: "%3", tmuxPanePID: 111, tty: "/dev/ttys003",
                terminalApplication: "Terminal", terminalPaneID: nil, terminalSocketPath: nil,
                attachCommand: ["tmux", "-L", "focus-queue", "attach", "-t", "fq-task-foc-1"]),
            context: context, source: .init(providerSessionID: "router-id", cwd: "/repo"))
        let url = try store.save(receipt)
        #expect(url.lastPathComponent == "a1.json")
        #expect(try Data(contentsOf: url).count < 8_192)
        #expect(try String(contentsOf: url).contains("Make exact recovery deterministic"))
        #expect(!String(data: try Data(contentsOf: url), encoding: .utf8)!.contains("fullInitialPrompt"))

        try store.reserveProviderSession(
            taskID: "FOC-1", subtaskID: "a1",
            providerSessionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let reservedLoaded = try store.load(taskID: "FOC-1", subtaskID: "a1")
        let reserved = try #require(reservedLoaded)
        #expect(reserved.status == .launched)
        #expect(reserved.providerSessionID == nil)
        #expect(reserved.reservedProviderSessionID
            == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        #expect(throws: TaskContextError.self) {
            try store.reserveProviderSession(
                taskID: "FOC-1", subtaskID: "a1",
                providerSessionID: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")
        }
        try store.register(
            taskID: "FOC-1", subtaskID: "a1",
            providerSessionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        #expect(throws: TaskContextError.self) {
            try store.completeHandoff(
                taskID: "FOC-1", subtaskID: "a1",
                expectedSessionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        }
        try store.markOrchestrationPrepared(taskID: "FOC-1", subtaskID: "a1")
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 2) {
                try? store.completeHandoff(
                    taskID: "FOC-1", subtaskID: "a1",
                    expectedSessionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
            } else {
                try? store.register(
                    taskID: "FOC-1", subtaskID: "a1",
                    providerSessionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
            }
        }
        let loaded = try store.load(taskID: "FOC-1", subtaskID: "a1")
        let registered = try #require(loaded)
        #expect(registered.status == .registered)
        #expect(registered.orchestrationPreparedAt != nil)
        #expect(registered.handoffCompletedAt != nil)
        #expect(registered.providerSessionID == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        #expect(registered.projectID == "focus")
        #expect(registered.taskTitle == "Exact recall")
        #expect(registered.providerResumeCommand?.prefix(3) == ["codex", "resume", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"])
        #expect(registered.runtime?.attachCommand == receipt.runtime?.attachCommand)
        #expect(registered.context == context)
        #expect(throws: TaskContextError.self) {
            try store.register(
                taskID: "FOC-1", subtaskID: "a1",
                providerSessionID: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")
        }
        try store.save(receipt)
        let monotonicLoaded = try store.load(taskID: "FOC-1", subtaskID: "a1")
        let monotonic = try #require(monotonicLoaded)
        #expect(monotonic.status == .registered)
        #expect(monotonic.providerSessionID == registered.providerSessionID)
        #expect(monotonic.handoffCompletedAt == registered.handoffCompletedAt)
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

    @Test("The startup repair sweep completes observed stuck receipts and fails abandoned ones")
    func startupRepairSweep() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-startup-repair-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStartupReceiptStore(root: root)
        let old = Date(timeIntervalSinceNow: -3_600)
        let registeredSession = "11111111-2222-4333-8444-555555555555"
        let launchedSession = "22222222-3333-4444-8555-666666666666"
        let registeredReceipt = repairReceipt(
            routeID: UUID().uuidString.lowercased(), status: .registered, taskID: "FOC-201",
            subtaskID: "aaaaaaaa-0000-4000-8000-000000000001",
            providerSessionID: registeredSession, at: old)
        try store.save(registeredReceipt)
        let launchedReceipt = repairReceipt(
            routeID: UUID().uuidString.lowercased(), status: .launched, taskID: "FOC-202",
            subtaskID: "aaaaaaaa-0000-4000-8000-000000000002",
            providerSessionID: launchedSession, at: old)
        try store.save(launchedReceipt)
        let abandonedReceipt = repairReceipt(
            routeID: UUID().uuidString.lowercased(), status: .launched, taskID: "FOC-203",
            subtaskID: "aaaaaaaa-0000-4000-8000-000000000003",
            providerSessionID: nil, at: old)
        try store.save(abandonedReceipt)
        let freshReceipt = repairReceipt(
            routeID: UUID().uuidString.lowercased(), status: .launched, taskID: "FOC-204",
            subtaskID: "aaaaaaaa-0000-4000-8000-000000000004",
            providerSessionID: nil, at: Date())
        try store.save(freshReceipt)
        let registrationsDirectory = root.appendingPathComponent(
            "external-agent-sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: registrationsDirectory, withIntermediateDirectories: true)
        for (id, taskID, subtaskID, sessionID) in [
            ("reg-one", "FOC-201", registeredReceipt.subtaskID, registeredSession),
            ("reg-two", "FOC-202", launchedReceipt.subtaskID, launchedSession),
        ] {
            let registration = ExternalAgentRegistration(
                id: id, provider: .codex, sessionID: sessionID,
                agentID: nil, parentSessionID: nil, cwd: "/repo/worktree", title: "Routed",
                taskID: taskID, subtaskID: subtaskID, reason: nil,
                eventName: "ProcessDiscovery", updatedAt: Date(),
                tmux: nil, paneID: nil, socketPath: nil)
            try JSONEncoder().encode(registration).write(
                to: registrationsDirectory.appendingPathComponent("\(id).json"),
                options: .atomic)
        }

        let report = try await AgentStartupRepair(root: root, launchedTimeout: 30).run()

        #expect(report.completedHandoffs.map(\.taskID).sorted() == ["FOC-201", "FOC-202"])
        #expect(report.failedReceipts.map(\.taskID) == ["FOC-203"])
        let completedRegistered = try #require(try store.load(
            taskID: "FOC-201", subtaskID: registeredReceipt.subtaskID))
        #expect(completedRegistered.status == .registered)
        #expect(completedRegistered.handoffCompletedAt != nil)
        let completedLaunched = try #require(try store.load(
            taskID: "FOC-202", subtaskID: launchedReceipt.subtaskID))
        #expect(completedLaunched.status == .registered)
        #expect(completedLaunched.providerSessionID == launchedSession)
        #expect(completedLaunched.handoffCompletedAt != nil)
        let failed = try #require(try store.load(
            taskID: "FOC-203", subtaskID: abandonedReceipt.subtaskID))
        #expect(failed.status == .failed)
        let untouched = try #require(try store.load(
            taskID: "FOC-204", subtaskID: freshReceipt.subtaskID))
        #expect(untouched.status == .launched)
        #expect(untouched.handoffCompletedAt == nil)
        // The sweep is idempotent: nothing remains stuck on a second pass.
        let secondPass = try await AgentStartupRepair(root: root, launchedTimeout: 30).run()
        #expect(secondPass.completedHandoffs.isEmpty)
        #expect(secondPass.failedReceipts.isEmpty)
    }

    @Test("The startup repair sweep fails a stuck registered receipt with no observed registration")
    func startupRepairFailsUnobservedRegisteredReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-startup-repair-stale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStartupReceiptStore(root: root)
        let receipt = repairReceipt(
            routeID: UUID().uuidString.lowercased(), status: .registered, taskID: "FOC-205",
            subtaskID: "aaaaaaaa-0000-4000-8000-000000000005",
            providerSessionID: "33333333-4444-4555-8666-777777777777",
            at: Date(timeIntervalSinceNow: -3_600))
        try store.save(receipt)

        let report = try await AgentStartupRepair(root: root, launchedTimeout: 30).run()

        #expect(report.completedHandoffs.isEmpty)
        #expect(report.failedReceipts.map(\.taskID) == ["FOC-205"])
        #expect(try store.load(taskID: "FOC-205", subtaskID: receipt.subtaskID)?
            .status == .failed)
    }

    @Test("The startup repair sweep flags an incomplete registration and records it on the receipt")
    func startupRepairFlagsIncompleteRegistration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-startup-repair-incomplete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStartupReceiptStore(root: root)
        let sessionID = "44444444-5555-4666-8777-888888888888"
        let subtaskID = "aaaaaaaa-0000-4000-8000-000000000006"
        let receipt = repairReceipt(
            routeID: UUID().uuidString.lowercased(), status: .registered, taskID: "FOC-206",
            subtaskID: subtaskID, providerSessionID: sessionID,
            at: Date(timeIntervalSinceNow: -3_600))
        try store.save(receipt)
        // The observed registration is missing the managed tmux reference.
        let registrationsDirectory = root.appendingPathComponent(
            "external-agent-sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: registrationsDirectory, withIntermediateDirectories: true)
        let registration = ExternalAgentRegistration(
            id: "reg-incomplete", provider: .codex, sessionID: sessionID,
            cwd: "/repo/worktree", title: "Routed", taskID: "FOC-206",
            subtaskID: subtaskID, eventName: "ProcessDiscovery", updatedAt: Date())
        try JSONEncoder().encode(registration).write(
            to: registrationsDirectory.appendingPathComponent("reg-incomplete.json"),
            options: .atomic)
        let contextStore = TaskContextStore(root: root)
        _ = try await contextStore.ensureContext(ticket: DashboardTicket(
            id: "FOC-206", title: "FOC-206", status: "open", summary: ""))
        _ = try await contextStore.upsertSubtask(ticketID: "FOC-206", subtask: TaskSubtask(
            id: subtaskID, title: "Routed", provider: .codex,
            sessionID: sessionID, status: .working, runtimeMode: .tmux))

        let report = try await AgentStartupRepair(root: root, launchedTimeout: 30).run()

        #expect(report.completedHandoffs.map(\.taskID) == ["FOC-206"])
        #expect(report.failedReceipts.isEmpty)
        #expect(report.registrationIssues.count == 1)
        #expect(report.registrationIssues.first?.missingFields == ["tmux session"])
        #expect(report.registrationIssues.first?.taskID == "FOC-206")
        let saved = try #require(try store.load(taskID: "FOC-206", subtaskID: subtaskID))
        #expect(saved.registrationIssue == "tmux session")
        #expect(saved.status == .registered)
    }

    @Test("Routed launch hints bind by session or exact tmux identity and carry the objective")
    func routedLaunchHints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "routed-launch-hints-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let tmux = TmuxSessionReference(name: "fq-task-ecc-101", serverPID: 10,
            createdAt: 20, paneID: "%3", panePID: 30, tty: "/dev/ttys003",
            executable: "/mock/tmux")
        let sessionID = UUID().uuidString.lowercased()
        let receiptStore = AgentStartupReceiptStore(root: root)
        try receiptStore.save(AgentStartupReceipt(
            routeID: UUID().uuidString.lowercased(), status: .launched, taskID: "ECC-101",
            subtaskID: "agent-1", title: "Repair tracking", description: "Repair it.",
            provider: .codex, providerSessionID: sessionID,
            promptByteCount: 10, promptSHA256: AgentStartupReceipt.promptDigest("Review it"),
            promptHint: "Review the registration flow",
            workspace: AgentWorkspace(
                path: "/tmp/wt", repositoryPath: "/tmp", branch: "fq/x", managed: true),
            runtime: .init(
                tmux: tmux, tmuxServerName: "focus-queue",
                terminalApplication: "WezTerm", terminalSocketPath: nil,
                attachCommand: ["tmux", "attach"]),
            context: AgentStartupContextPaths(
                taskPlan: "/tmp/plan.md", taskContext: "/tmp/context.json",
                taskLog: "/tmp/log.md"),
            source: .init(cwd: "/tmp")))
        // Failed receipts carry no binding authority.
        var failed = try #require(try receiptStore.load(taskID: "ECC-101", subtaskID: "agent-1"))
        failed.subtaskID = "agent-failed"
        failed.status = .failed
        try receiptStore.save(failed)
        try AgentPlacementCapsuleStore(root: root).save(AgentPlacementCapsule(
            launchID: UUID().uuidString.lowercased(), generatedAt: Date(), status: .placed,
            projectID: "focus", projectName: "Focus", taskPrefix: "ECC",
            taskID: "ECC-102", assignmentID: "agent-2", agentID: "agent-2",
            provider: .claude, sessionID: nil, repositoryPath: nil,
            repositoryRemote: nil, workspacePath: "/tmp", branch: nil,
            tmuxName: "fq-task-ecc-102", tmuxPaneID: "%9",
            projectPlanPath: "/tmp/p.md", taskPlanPath: nil, taskLogPath: nil,
            capsulePath: "/tmp/c.json", reason: nil,
            promptHint: "Fix the capsule naming"))

        let hints = RoutedLaunchHintStore.hints(root: root)

        #expect(Set(hints.map(\.subtaskID)) == ["agent-1", "agent-2"])
        let bySession = try #require(RoutedLaunchHintStore.match(
            sessionID: sessionID, provider: .codex, tmux: nil, hints: hints))
        #expect(bySession.taskID == "ECC-101")
        #expect(bySession.promptHint == "Review the registration flow")
        let byTmux = try #require(RoutedLaunchHintStore.match(
            sessionID: UUID().uuidString, provider: .codex, tmux: tmux, hints: hints))
        #expect(byTmux.subtaskID == "agent-1")
        let byPane = try #require(RoutedLaunchHintStore.match(
            sessionID: UUID().uuidString, provider: .claude,
            tmux: TmuxSessionReference(name: "fq-task-ecc-102", serverPID: 99,
                createdAt: 1, paneID: "%9", panePID: 2, tty: "/dev/ttys099",
                executable: "/mock/tmux"),
            hints: hints))
        #expect(byPane.taskID == "ECC-102")
        #expect(byPane.promptHint == "Fix the capsule naming")
        #expect(RoutedLaunchHintStore.match(
            sessionID: UUID().uuidString, provider: .claude, tmux: nil, hints: hints) == nil)
    }
}

private func repairReceipt(
    routeID: String, status: AgentStartupStatus, taskID: String, subtaskID: String,
    providerSessionID: String?, at date: Date
) -> AgentStartupReceipt {
    AgentStartupReceipt(
        routeID: routeID, status: status, taskID: taskID, subtaskID: subtaskID,
        title: "Repair \(taskID)", description: "Stuck routed startup",
        provider: .codex, providerSessionID: providerSessionID, promptByteCount: 12,
        promptSHA256: AgentStartupReceipt.promptDigest("Repair \(taskID)"),
        workspace: AgentWorkspace(path: "/repo/worktree", repositoryPath: "/repo"),
        runtime: .init(
            mode: .tmux, tmuxExecutable: "/mock/tmux", tmuxServerName: "focus-queue",
            tmuxName: "fq-task-\(taskID.lowercased())", tmuxServerPID: 101,
            tmuxCreatedAt: 102, tmuxPaneID: "%3", tmuxPanePID: 111, tty: "/dev/ttys003",
            terminalApplication: "WezTerm", attachCommand: ["tmux", "attach"]),
        context: AgentStartupContextPaths(
            taskPlan: "/support/tasks/\(taskID)/plan.md",
            taskContext: "/support/tasks/\(taskID)/context.json",
            taskLog: "/support/tasks/\(taskID)/agent-log.md"),
        source: .init(cwd: "/repo"), createdAt: date, updatedAt: date)
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

    func addingProject(id: String, name: String, prefix: String) async throws
        -> (configuration: AppConfiguration, repository: URL) {
        let repo = root.appendingPathComponent("repository-\(id)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let runner = FoundationProcessRunner()
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"],
        ] {
            let result = try await runner.run(.init(
                executable: "/usr/bin/git", arguments: arguments, workingDirectory: repo.path))
            guard result.succeeded else { throw TaskContextError.commandFailed(result.standardError) }
        }
        let dashboardURL = root.appendingPathComponent("dashboard-\(id).json")
        try Data("{\"tickets\": []}".utf8).write(to: dashboardURL)
        var updated = configuration
        updated.projects = ProjectCatalog.ensuringOther(
            in: updated.projects.filter { $0.id != ProjectCatalog.otherID } + [ProjectDefinition(
                id: id, name: name, dashboardPath: dashboardURL.path,
                workspacePath: repo.path, taskPrefix: prefix, repositoryPath: repo.path)],
            supportDirectory: support)
        return (try updated.validated(), repo)
    }
}
