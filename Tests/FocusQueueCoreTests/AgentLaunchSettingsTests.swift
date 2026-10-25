import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Agent launch settings and launch hints")
struct AgentLaunchSettingsTests {
    @Test("A configuration saved with the retired automatic-routing flag still loads")
    func retiredRoutingFlag() throws {
        let starter = SetupEnvironment.starter(
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(starter)) as? [String: Any])
        object["automaticAgentRouting"] = true
        let decoded = try JSONDecoder().decode(
            AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.placementProvider == starter.placementProvider)
        let saved = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(saved["automaticAgentRouting"] == nil)
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

    @Test("Saved configs gain current models and drop retired built-in entries")
    func retiredModelChoicesDropOnDecode() throws {
        let starter = SetupEnvironment.starter(
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(starter)) as? [String: Any])
        object["agentModelChoices"] = [
            ["provider": "codex", "label": "gpt-5.5", "model": "gpt-5.5"],
            ["provider": "codex", "label": "gpt-5.2", "model": "gpt-5.2"],
            ["provider": "codex", "label": "gpt-5.4", "model": "gpt-5.4-custom"],
        ]
        let decoded = try JSONDecoder().decode(
            AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        let models = decoded.agentModelChoices.compactMap(\.model)

        #expect(!models.contains("gpt-5.5"))
        #expect(!models.contains("gpt-5.2"))
        #expect(models.contains("gpt-5.4-custom"))
        for model in ["gpt-6.1-sol", "claude-fable-5-1", "claude-haiku-5-5", "fable",
                      "kimi-code/k3.1-pro", "kimi-code/k3.1-pro-highspeed"] {
            #expect(models.contains(model))
        }
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

    @Test("Placement models and efforts default per provider and survive a round-trip")
    func placementSettingsRoundTrip() throws {
        var configuration = AppConfiguration.eccDefault()
        #expect(configuration.placementModel(for: .claude) == "haiku")
        #expect(configuration.placementModel(for: .codex) == "gpt-6-luna")
        #expect(configuration.placementModel(for: .kimi) == "kimi-code/kimi-for-coding-highspeed")
        #expect(configuration.placementEffort(for: .claude) == "low")
        #expect(configuration.placementEffort(for: .codex) == "low")

        configuration.placementModelEnabled = false
        configuration.placementProvider = .kimi
        configuration.placementModels[.codex] = "gpt-5.6-luna"
        configuration.placementEfforts[.claude] = "medium"
        configuration.placementEfforts[.kimi] = "high"
        configuration.placementTimeoutSeconds = 12
        let decoded = try JSONDecoder().decode(
            AppConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(decoded.placementModelEnabled == false)
        #expect(decoded.placementProvider == .kimi)
        #expect(decoded.placementModel(for: .codex) == "gpt-5.6-luna")
        #expect(decoded.placementModel(for: .claude) == "haiku")
        #expect(decoded.placementEffort(for: .claude) == "medium")
        #expect(decoded.placementEffort(for: .kimi) == nil, "Kimi has no effort flag")
        #expect(decoded.placementTimeoutSeconds == 12)

        let blank = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(
            withJSONObject: try #require(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(AppConfiguration.eccDefault())) as? [String: Any])
                .merging(["placementModels": ["claude": "  ", "future": "x"]]) { $1 }))
        #expect(blank.placementModels.isEmpty)
        #expect(blank.placementModel(for: .claude) == "haiku")
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
        #expect(!context.agentPrompt(subtask: persisted).contains("agent-startups"),
            "A legacy routed agent resumes with its capsule, not a retired startup receipt")

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

    @Test("Placement capsules bind a launch by session or exact tmux pane and carry the objective")
    func launchHints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "launch-hints-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID().uuidString.lowercased()
        let store = AgentPlacementCapsuleStore(root: root)
        func capsule(taskID: String?, agentID: String?, provider: AgentProvider, sessionID: String?,
                     tmuxName: String?, paneID: String?, hint: String) -> AgentPlacementCapsule {
            AgentPlacementCapsule(
                launchID: UUID().uuidString.lowercased(), generatedAt: Date(), status: .placed,
                projectID: "focus", projectName: "Focus", taskPrefix: "ECC",
                taskID: taskID, assignmentID: agentID, agentID: agentID,
                provider: provider, sessionID: sessionID, repositoryPath: nil,
                repositoryRemote: nil, workspacePath: "/tmp", branch: nil,
                tmuxName: tmuxName, tmuxPaneID: paneID,
                projectPlanPath: "/tmp/p.md", taskPlanPath: nil, taskLogPath: nil,
                capsulePath: "/tmp/c.json", reason: nil, promptHint: hint)
        }
        try store.save(capsule(taskID: "ECC-101", agentID: "agent-1", provider: .codex,
            sessionID: sessionID, tmuxName: nil, paneID: nil, hint: "Review the registration flow"))
        try store.save(capsule(taskID: "ECC-102", agentID: "agent-2", provider: .claude,
            sessionID: nil, tmuxName: "fq-task-ecc-102", paneID: "%9", hint: "Fix the capsule naming"))
        // A taskless capsule carries no binding authority.
        try store.save(capsule(taskID: nil, agentID: nil, provider: .claude,
            sessionID: nil, tmuxName: "fq-task-ecc-102", paneID: "%9", hint: "Unplaced"))

        let hints = LaunchHintStore.hints(root: root)

        #expect(Set(hints.map(\.subtaskID)) == ["agent-1", "agent-2"])
        let bySession = try #require(LaunchHintStore.match(
            sessionID: sessionID, provider: .codex, tmux: nil, hints: hints))
        #expect(bySession.taskID == "ECC-101")
        #expect(bySession.promptHint == "Review the registration flow")
        let byPane = try #require(LaunchHintStore.match(
            sessionID: UUID().uuidString, provider: .claude,
            tmux: TmuxSessionReference(name: "fq-task-ecc-102", serverPID: 99,
                createdAt: 1, paneID: "%9", panePID: 2, tty: "/dev/ttys099",
                executable: "/mock/tmux"),
            hints: hints))
        #expect(byPane.taskID == "ECC-102")
        #expect(byPane.promptHint == "Fix the capsule naming")
        #expect(LaunchHintStore.match(
            sessionID: UUID().uuidString, provider: .claude, tmux: nil, hints: hints) == nil)
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
