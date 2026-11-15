import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Agent pause and resume")
struct AgentPauseTests {
    private func store(_ root: URL, agent: TaskSubtask) async throws -> TaskContextStore {
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-870", title: "Task", status: "open", summary: ""))
        _ = try await store.upsertSubtask(ticketID: "ECC-870", subtask: agent)
        return store
    }

    @Test("A pause survives its own interrupt echo and clears on the next prompt")
    func pauseLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = TaskSubtask(id: "worker", title: "Worker", provider: .claude,
            sessionID: UUID().uuidString, status: .working, lastHeartbeatAt: Date(timeIntervalSinceReferenceDate: 100))
        let store = try await store(root, agent: agent)

        let pausedAt = Date(timeIntervalSinceReferenceDate: 200)
        var saved = try await store.setPaused(ticketID: "ECC-870", subtaskID: agent.id, paused: true, at: pausedAt)
        #expect(saved.subtasks[0].isPaused)
        #expect(saved.subtasks[0].status == .idle)

        // Esc writes an interrupted-turn record and can flush a late tool event.
        for (id, kind) in [("echo", AgentActivityEvent.Kind.attention(.interrupted)), ("late-tool", .working)] {
            saved = try await store.observeActivity(ticketID: "ECC-870", subtaskID: agent.id,
                event: AgentActivityEvent(id: id, date: pausedAt.addingTimeInterval(1), kind: kind, summary: "x", source: .hook))
        }
        #expect(saved.subtasks[0].isPaused)
        #expect(saved.subtasks[0].status == .idle)
        #expect(saved.subtasks[0].attention == nil)

        // Typing into the pane resumes it as surely as the Resume button.
        saved = try await store.observeActivity(ticketID: "ECC-870", subtaskID: agent.id,
            event: AgentActivityEvent(id: "typed", date: pausedAt.addingTimeInterval(5), kind: .prompt, summary: "go on"))
        #expect(!saved.subtasks[0].isPaused)
        #expect(saved.subtasks[0].status == .working)
    }

    @Test("Resume without a prompt only clears the pause; completion clears it too")
    func clearingPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = TaskSubtask(id: "worker", title: "Worker", provider: .codex, status: .working)
        let store = try await store(root, agent: agent)

        _ = try await store.setPaused(ticketID: "ECC-870", subtaskID: agent.id, paused: true)
        var saved = try await store.setPaused(ticketID: "ECC-870", subtaskID: agent.id, paused: false, promptSent: false)
        #expect(!saved.subtasks[0].isPaused)
        #expect(saved.subtasks[0].status == .idle)

        _ = try await store.setPaused(ticketID: "ECC-870", subtaskID: agent.id, paused: true)
        saved = try await store.updateProgress(ticketID: "ECC-870", subtaskID: agent.id, status: .completed, summary: "Done")
        #expect(saved.subtasks[0].pausedAt == nil)
    }

    @Test("Records saved before pause support still decode, and the pause round-trips")
    func coding() throws {
        let legacy = #"{"id":"a","title":"A","provider":"kimi","status":"working"}"#
        let decoded = try JSONDecoder().decode(TaskSubtask.self, from: Data(legacy.utf8))
        #expect(decoded.pausedAt == nil)
        var paused = decoded
        paused.pausedAt = Date(timeIntervalSinceReferenceDate: 42)
        let roundTrip = try JSONDecoder().decode(TaskSubtask.self, from: JSONEncoder().encode(paused))
        #expect(roundTrip.pausedAt == paused.pausedAt)
    }

    @Test("Only Kimi waits for its input box before a resume paste")
    func readiness() {
        #expect(AgentPauseController.inputIsReady(for: .claude)(""))
        #expect(AgentPauseController.inputIsReady(for: .codex)(""))
        #expect(!AgentPauseController.inputIsReady(for: .kimi)("loading"))
        #expect(AgentPauseController.inputIsReady(for: .kimi)("│ > "))
    }

    @Test("Pause refuses a folder-trust prompt, where Esc would quit the agent")
    func startupPrompt() {
        // Screens captured from Claude Code 2.1.312 and Kimi Code 2.3.3 on first launch.
        #expect(AgentPauseController.showsStartupPrompt("❯ No, exit\n   Yes, I trust this folder\n Enter to confirm · Esc to cancel"))
        #expect(AgentPauseController.showsStartupPrompt("  Trust this folder?\n  ↑↓ navigate · Enter select · Esc exit"))
        #expect(!AgentPauseController.showsStartupPrompt("• Working (12s • esc to interrupt)"))
    }

    @Test("An agent without a managed pane reports why it cannot pause")
    func noManagedPane() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = TaskSubtask(id: "worker", title: "Worker", provider: .claude, status: .working, runtimeMode: .terminal)
        let store = try await store(root, agent: agent)
        await #expect(throws: AgentPauseController.PauseError.noManagedPane("Worker")) {
            try await AgentPauseController(store: store).pause(ticketID: "ECC-870", subtaskID: agent.id)
        }
    }

    @Test("Pause presses Esc in the live pane and Resume pastes the continue prompt",
        .enabled(if: SetupEnvironment.executable("tmux") != nil))
    func livePaneRoundTrip() async throws {
        let executable = try #require(SetupEnvironment.executable("tmux"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fq-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let serverName = "fq-pause-\(UUID().uuidString.prefix(8))"
        defer {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: executable)
            cleanup.arguments = ["-L", serverName, "kill-server"]
            cleanup.environment = ["TMUX_TMPDIR": "/tmp", "PATH": "/usr/bin:/bin"]
            cleanup.standardError = FileHandle.nullDevice
            try? cleanup.run(); cleanup.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        // The fake TUI records every byte it receives, including Esc.
        let output = root.appendingPathComponent("received.bin")
        let script = "stty -icanon -echo min 1 time 0; printf '│ >\\n'; cat > \"$1\""
        let tmux = TmuxController(serverName: serverName)
        let reference = try await tmux.start(
            name: "fq-pause", directory: root.path,
            command: ["/bin/sh", "-c", script, "fake-agent", output.path], executable: executable)
        var agent = TaskSubtask(id: "worker", title: "Worker", provider: .kimi, status: .working)
        agent.tmux = reference
        let contexts = TaskContextStore(root: root.appendingPathComponent("support"))
        _ = try await contexts.ensureContext(ticket: DashboardTicket(
            id: "ECC-870", title: "Task", status: "open", summary: ""))
        _ = try await contexts.upsertSubtask(ticketID: "ECC-870", subtask: agent)
        let controller = AgentPauseController(store: contexts, tmux: tmux)

        let paused = try await controller.pause(ticketID: "ECC-870", subtaskID: agent.id)
        #expect(paused.subtasks[0].isPaused)
        let resumed = try await controller.resume(ticketID: "ECC-870", subtaskID: agent.id)
        #expect(!resumed.subtasks[0].isPaused)
        #expect(resumed.subtasks[0].status == .working)

        let expected = "\u{1b}\n\n" + AgentPauseController.resumePrompt + "\n"
        for _ in 0..<40 where (try? String(contentsOf: output, encoding: .utf8)) != expected {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == expected)
    }

    @Test("A resumed launch carries Play's text; Kimi's stays out of argv for a paste")
    func resumeCommandCarriesPlayText() throws {
        let context = TaskContext(ticketID: "ECC-870", title: "Task", summary: "",
            successCriteria: "", planPath: "/tmp/support/tasks/ECC-870/plan.md",
            worktreePath: "/tmp/worktree", updatedAt: Date())
        let support = URL(fileURLWithPath: "/tmp/support")
        let claude = TaskSubtask(title: "Claude", provider: .claude,
            sessionID: "11111111-2222-4333-8444-555555555555")
        let claudeCommand = try TaskAgentLauncher.command(context: context, subtask: claude,
            supportDirectory: support, resumePrompt: "Ship it")
        #expect(claudeCommand.contains("--resume"))
        #expect(Array(claudeCommand.suffix(2)) == ["--", "Ship it"])
        let plain = try TaskAgentLauncher.command(context: context, subtask: claude, supportDirectory: support)
        #expect(!plain.contains("Ship it") && !plain.contains("--"))
        let codex = TaskSubtask(title: "Codex", provider: .codex,
            sessionID: "11111111-2222-4333-8444-555555555555")
        #expect(try TaskAgentLauncher.command(context: context, subtask: codex,
            supportDirectory: support, resumePrompt: "Ship it").last == "Ship it")
        let kimi = TaskSubtask(title: "Kimi", provider: .kimi, sessionID: "01HZ8KJ9X0AVBR1C2D3E4F5G6H")
        let kimiCommand = try TaskAgentLauncher.command(context: context, subtask: kimi,
            supportDirectory: support, resumePrompt: "Ship it")
        #expect(!kimiCommand.contains("Ship it") && !kimiCommand.contains("--prompt"))
    }

    @Test("Play types its text into a live pane; a closed pane never forks a running conversation",
        .enabled(if: SetupEnvironment.executable("tmux") != nil))
    func playLiveAndClosedPane() async throws {
        let executable = try #require(SetupEnvironment.executable("tmux"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fq-play-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let serverName = "fq-play-\(UUID().uuidString.prefix(8))"
        func killServer() {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: executable)
            cleanup.arguments = ["-L", serverName, "kill-server"]
            cleanup.environment = ["TMUX_TMPDIR": "/tmp", "PATH": "/usr/bin:/bin"]
            cleanup.standardError = FileHandle.nullDevice
            try? cleanup.run(); cleanup.waitUntilExit()
        }
        defer { killServer(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("received.bin")
        let script = "stty -icanon -echo min 1 time 0; printf '│ >\\n'; cat > \"$1\""
        let tmux = TmuxController(serverName: serverName)
        let reference = try await tmux.start(
            name: "fq-play", directory: root.path,
            command: ["/bin/sh", "-c", script, "fake-agent", output.path], executable: executable)
        var agent = TaskSubtask(id: "worker", title: "Worker", provider: .kimi,
            sessionID: "01HZ8KJ9X0AVBR1C2D3E4F5G6H", status: .idle)
        agent.tmux = reference
        let support = root.appendingPathComponent("support")
        let contexts = TaskContextStore(root: support)
        _ = try await contexts.ensureContext(ticket: DashboardTicket(
            id: "ECC-870", title: "Task", status: "open", summary: ""))
        _ = try await contexts.upsertSubtask(ticketID: "ECC-870", subtask: agent)
        let controller = AgentPauseController(store: contexts, tmux: tmux)

        let (played, outcome) = try await controller.play(
            ticketID: "ECC-870", subtaskID: agent.id, prompt: "  Ship it  ",
            supportDirectory: support, tmuxExecutable: executable,
            isRunningElsewhere: { _, _ in Issue.record("A live pane needs no process scan"); return false })
        #expect(outcome == .sent)
        #expect(played.subtasks[0].status == .working)
        let expected = "\n\nShip it\n"
        for _ in 0..<40 where (try? String(contentsOf: output, encoding: .utf8)) != expected {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == expected)

        killServer()
        await #expect(throws: AgentPauseController.PauseError.runningElsewhere("Worker")) {
            try await controller.play(ticketID: "ECC-870", subtaskID: agent.id,
                supportDirectory: support, tmuxExecutable: executable,
                isRunningElsewhere: { provider, sessionID in
                    #expect(provider == .kimi && sessionID == "01HZ8KJ9X0AVBR1C2D3E4F5G6H")
                    return true
                })
        }
        agent.sessionID = nil
        _ = try await contexts.upsertSubtask(ticketID: "ECC-870", subtask: agent)
        await #expect(throws: AgentPauseController.PauseError.noSavedConversation("Worker")) {
            try await controller.play(ticketID: "ECC-870", subtaskID: agent.id,
                supportDirectory: support, tmuxExecutable: executable,
                isRunningElsewhere: { _, _ in false })
        }
    }
}
