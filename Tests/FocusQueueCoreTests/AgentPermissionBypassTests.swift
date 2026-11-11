import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Agent permission bypass setting (FOC-119)")
struct AgentPermissionBypassTests {
    private let context = TaskContext(
        ticketID: "FOC-1", title: "Bypass", summary: "", successCriteria: "Done",
        planPath: "/tmp/focus/tasks/FOC-1/plan.md", worktreePath: "/tmp/worktree", updatedAt: Date())

    private func command(_ provider: AgentProvider, bypass: Bool) throws -> [String] {
        try TaskAgentLauncher.command(
            context: context, subtask: TaskSubtask(title: "Agent", provider: provider),
            supportDirectory: URL(fileURLWithPath: "/tmp/support"), bypassPermissions: bypass)
    }

    @Test("Providers bypass by default; a provider setting and then a task choice override it")
    func resolution() throws {
        let starter = SetupEnvironment.starter(
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(AgentProvider.allCases.allSatisfy { starter.bypassesPermissions(for: $0) })
        var config = starter
        config.agentPermissionBypass[.codex] = false
        #expect(!config.bypassesPermissions(for: .codex))
        #expect(config.bypassesPermissions(for: .codex, taskOverride: true))
        #expect(!config.bypassesPermissions(for: .claude, taskOverride: false))

        // An untouched config writes no key, so older builds read it unchanged.
        let untouched = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(starter)) as? [String: Any])
        #expect(untouched["agentPermissionBypass"] == nil)
        let saved = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
        #expect(saved.agentPermissionBypass == [.codex: false])

        var task = context
        task.bypassPermissions = false
        let reloaded = try JSONDecoder().decode(TaskContext.self, from: JSONEncoder().encode(task))
        #expect(reloaded.bypassPermissions == false)
        let legacy = try JSONDecoder().decode(TaskContext.self, from: JSONEncoder().encode(context))
        #expect(legacy.bypassPermissions == nil)
    }

    @Test("Bypass adds each provider's no-prompt launch flags; off adds none")
    func launchFlags() throws {
        let claude = try command(.claude, bypass: true)
        #expect(claude.contains(["--permission-mode", "bypassPermissions"]))
        let settings = try #require(claude.firstIndex(of: "--settings").map { claude[$0 + 1] })
        let decoded = try #require(
            JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
        #expect(decoded["skipDangerousModePermissionPrompt"] as? Bool == true,
                "The Focus Queue setting is the consent, so the pasted prompt never lands in Claude's warning")
        #expect(claude.filter { $0 == "--settings" }.count == 1)

        let codex = try command(.codex, bypass: true)
        #expect(codex.contains(["-c", "sandbox_mode=\"danger-full-access\""]))
        #expect(codex.contains(["-c", "approval_policy=\"never\""]))
        #expect(!codex.contains("sandbox_mode=\"workspace-write\""))
        #expect(!codex.contains("--yolo") && !codex.contains("--dangerously-bypass-approvals-and-sandbox"),
                "A repeated flag would collide with a --yolo alias")

        #expect(try command(.kimi, bypass: true).contains("--yolo"))

        let claudeOff = try command(.claude, bypass: false)
        #expect(!claudeOff.contains("--permission-mode"))
        #expect(!claudeOff.joined().contains("skipDangerousModePermissionPrompt"))
        let codexOff = try command(.codex, bypass: false)
        #expect(codexOff.contains(["-c", "sandbox_mode=\"workspace-write\""]))
        #expect(!codexOff.contains("approval_policy=\"never\""))
        #expect(!(try command(.kimi, bypass: false)).contains("--yolo"))
    }
}
