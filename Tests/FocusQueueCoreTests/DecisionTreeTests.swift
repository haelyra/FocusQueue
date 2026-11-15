import Foundation
import Testing
@testable import FocusQueueCore

// MARK: - Fixtures

private struct DecisionGitFixture {
    let root: URL
    let repository: URL
    let remote: URL

    init(branch: String = "focus-queue/tst-1-agent") async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("decision-tree-\(UUID().uuidString)")
        repository = root.appendingPathComponent("repo")
        remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try await git(["init", "-q", "--bare", remote.path], in: root)
        _ = try await git(["init", "-q", "-b", branch])
        try write("base\n", to: "a.txt")
        try write("build/\n", to: ".gitignore")
        try await commit("base")
        _ = try await git(["remote", "add", "origin", remote.path])
    }

    func write(_ text: String, to path: String) throws {
        let url = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: repository.appendingPathComponent(path).path)
    }

    func commit(_ message: String) async throws {
        _ = try await git(["add", "-A"])
        _ = try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                           "-c", "core.hooksPath=/dev/null", "commit", "-qm", message])
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let result = try await FoundationProcessRunner().run(.init(
            executable: "/usr/bin/git", arguments: arguments, workingDirectory: (directory ?? repository).path))
        try #require(result.succeeded, "\(arguments): \(result.standardError)")
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteRefs() async throws -> [String] {
        try await git(["for-each-ref", "--format=%(refname)"], in: remote).split(separator: "\n").map(String.init)
    }
}

private actor RecordingControl: DecisionAgentControlling {
    var delivered: [(agent: String, text: String)] = []
    var restarted: [(agent: String, session: String?, prompt: String, deferred: Bool)] = []

    func deliver(_ text: String, taskID: String, agentID: String) async throws -> String {
        delivered.append((agentID, text))
        return "sent"
    }

    func restart(taskID: String, agentID: String, provider: AgentProvider, sessionID: String?,
                 forkNatively: Bool, prompt: String, deferred: Bool) async throws -> String {
        restarted.append((agentID, sessionID, prompt, deferred))
        return deferred ? "scheduled" : "reopened"
    }
}

private let agentID = "AAAAAAAA-1111-2222-3333-444444444444"
private let sessionID = "11111111-2222-3333-4444-555555555555"

/// A support folder with task TST-1, one Claude agent in `workspace`, and that agent's transcript.
private func serviceFixture(workspace: URL, claudeRoot: URL, settings: [String: Any] = [:]) async throws -> URL {
    let support = workspace.deletingLastPathComponent().appendingPathComponent("support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let store = TaskContextStore(root: support)
    _ = try await store.ensureContext(ticket: DashboardTicket(
        id: "TST-1", title: "Decision fixture", status: "in-progress", summary: "Exercise decision trees."))
    var agent = TaskSubtask(id: agentID, title: "Fixture agent", provider: .claude, sessionID: sessionID, status: .working)
    agent.workspace = AgentWorkspace(path: workspace.path, repositoryPath: workspace.path, branch: "focus-queue/tst-1-agent")
    _ = try await store.upsertSubtask(ticketID: "TST-1", subtask: agent)
    var config: [String: Any] = ["tmuxExecutable": "/usr/bin/false", "setupCompleted": true]
    config.merge(settings) { $1 }
    try JSONSerialization.data(withJSONObject: config).write(to: support.appendingPathComponent("config.json"))
    let project = claudeRoot.appendingPathComponent("projects")
        .appendingPathComponent(DecisionConversations.claudeProjectDirectoryName(forWorkingDirectory: workspace.path))
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let lines = [
        #"{"type":"user","uuid":"u1","parentUuid":null,"sessionId":"\#(sessionID)","message":{"role":"user","content":"start"}}"#,
        #"{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"\#(sessionID)","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
        #"{"type":"user","uuid":"u2","parentUuid":"a1","sessionId":"\#(sessionID)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done"}]}}"#,
        #"{"type":"assistant","uuid":"a2","parentUuid":"u2","sessionId":"\#(sessionID)","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}]}}"#,
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: project.appendingPathComponent("\(sessionID).jsonl"))
    return support
}

// MARK: - Tree model

@Test("Rewinding abandons the old path and switches ancestors to the new branch")
func decisionTreeRewindAcrossBranches() throws {
    var tree = DecisionTree(taskID: "TST-1", agentID: agentID, agentTitle: nil, provider: "claude", now: "t0")
    let options = [DecisionOption(id: "A", label: "First"), DecisionOption(id: "B", label: "Second")]
    let d1 = tree.addNode(title: "D1", divergence: .taskPlan, detail: nil, options: options, now: "t1")
    #expect(d1.id == "D1" && d1.parentID == nil && tree.head == DecisionHead(nodeID: "D1", optionID: nil))
    try tree.choose(nodeID: "D1", optionID: "a", by: .user, now: "t2")
    let d2 = tree.addNode(title: "D2", divergence: .userInstruction, detail: nil, options: [
        DecisionOption(id: "A", label: "X"), DecisionOption(id: "B", label: "Y")], now: "t3")
    #expect(d2.parentID == "D1" && d2.parentOptionID == "A")
    try tree.choose(nodeID: "D2", optionID: "A", by: .agent, now: "t4")
    #expect(throws: DecisionTreeError.alreadyDecided("D2", "A")) {
        try tree.choose(nodeID: "D2", optionID: "B", by: .user, now: "t5")
    }

    try tree.rewind(to: "D1", optionID: "B", by: .user, reason: "A failed", rewoundFrom: nil, sessionID: "fork-1", now: "t6")
    #expect(tree.head == DecisionHead(nodeID: "D1", optionID: "B"))
    #expect(tree.node("D2")?.attempts.map(\.state) == [.abandoned])
    #expect(tree.node("D1")?.attempts.map(\.state) == [.abandoned, .active])
    #expect(tree.node("D1")?.attempts.last?.sessionID == "fork-1")
    #expect(tree.node("D1")?.nextUntriedOptionID == nil)

    let d3 = tree.addNode(title: "D3", divergence: .masterPlan, detail: nil, options: options, now: "t7")
    #expect(d3.parentID == "D1" && d3.parentOptionID == "B")
    // Back onto the abandoned branch: D1 follows A again and D3's path is abandoned.
    try tree.rewind(to: "D2", optionID: "B", by: .user, reason: nil, rewoundFrom: nil, sessionID: nil, now: "t8")
    #expect(tree.head == DecisionHead(nodeID: "D2", optionID: "B"))
    #expect(tree.node("D1")?.chosenOptionID == "A")
    #expect(tree.node("D1")?.activeAttempt?.optionID == "A")
    #expect(tree.node("D2")?.attempts.map(\.optionID) == ["A", "B"])
    #expect(tree.children(of: "D1", option: "B").map(\.id) == ["D3"])
}

@Test("Options keep recommendation order and split an em-dash detail")
func decisionOptionsParse() {
    let options = DecisionTreeService.options(from: ["JSON file — the app draws it", "  ", "Markdown file"])
    #expect(options.map(\.id) == ["A", "B"])
    #expect(options[0].label == "JSON file" && options[0].detail == "the app draws it")
    #expect(options[1].detail == nil)
    var node = DecisionNode(id: "D1", parentID: nil, parentOptionID: nil, title: "t", divergence: .other,
                            detail: nil, options: options, createdAt: "t")
    #expect(DecisionTreeService.resolve("recommended", in: node) == "A")
    #expect(DecisionTreeService.resolve("next", in: node) == "A")
    node.attempts = [DecisionAttempt(optionID: "A", state: .abandoned, startedAt: "t", startedBy: .user)]
    #expect(DecisionTreeService.resolve("next", in: node) == "B")
    #expect(DecisionTreeService.resolve("markdown FILE", in: node) == "B")
    #expect(DecisionTreeService.resolve("Z", in: node) == nil)
}

@Test("Decision settings default to a one-hour auto-decide with auto-rewind on")
func decisionSettingsDefaults() throws {
    let starter = SetupEnvironment.starter(supportDirectory: FileManager.default.temporaryDirectory)
    let decoded = try JSONDecoder().decode(AppConfiguration.self, from: try JSONEncoder().encode(starter))
    #expect(decoded.decisionAutomation == DecisionAutomationSettings(autoDecide: true, autoDecideMinutes: 60, autoRewind: true))
    #expect(decoded.decisionAutomation.windowDescription == "1 hour")
    var configuration = decoded
    configuration.decisionAutoDecide = false
    configuration.decisionAutoDecideMinutes = 90
    configuration.decisionAutoRewind = false
    let round = try JSONDecoder().decode(AppConfiguration.self, from: try JSONEncoder().encode(configuration))
    #expect(round.decisionAutomation == DecisionAutomationSettings(autoDecide: false, autoDecideMinutes: 90, autoRewind: false))
    #expect(round.decisionAutomation.windowDescription == "90 minutes")
    #expect(DecisionAutomationSettings(autoDecideMinutes: 0).autoDecideMinutes == 1)
    // The settings file is read by its own keys, whatever else the file holds.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("decision-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"decisionAutoRewind": false, "decisionAutoDecideMinutes": 15, "appName": 7}"#.utf8)
        .write(to: folder.appendingPathComponent("config.json"))
    #expect(DecisionAutomationSettings.load(supportDirectory: folder)
        == DecisionAutomationSettings(autoDecide: true, autoDecideMinutes: 15, autoRewind: false))
    #expect(DecisionAutomationSettings.load(supportDirectory: folder.appendingPathComponent("none")) == DecisionAutomationSettings())
}

// MARK: - Git checkpoints

@Test("A checkpoint captures uncommitted and untracked work without touching the checkout, and is pushed")
func decisionCheckpointLeavesCheckoutAlone() async throws {
    let fixture = try await DecisionGitFixture()
    try fixture.write("base\nedited\n", to: "a.txt")
    try fixture.write("new\n", to: "untracked.txt")
    let before = try await fixture.git(["status", "--porcelain"])
    let checkpoint = try await DecisionCheckpointing().checkpoint(
        workspace: fixture.repository.path, ref: "refs/focus-queue/decisions/TST-1/AGENT/D1", message: "D1", push: true)
    #expect(try await fixture.git(["status", "--porcelain"]) == before)
    #expect(checkpoint.parent == (try await fixture.git(["rev-parse", "HEAD"])))
    #expect(checkpoint.branch == "focus-queue/tst-1-agent")
    #expect(checkpoint.pushed && checkpoint.pushError == nil)
    #expect(try await fixture.remoteRefs() == ["refs/focus-queue/decisions/TST-1/AGENT/D1"])
    #expect(try await fixture.git(["show", "\(checkpoint.commit):untracked.txt"]) == "new")
}

@Test("A failed push is recorded and the local checkpoint still stands")
func decisionCheckpointRecordsPushFailure() async throws {
    let fixture = try await DecisionGitFixture()
    _ = try await fixture.git(["remote", "set-url", "origin", fixture.root.appendingPathComponent("missing.git").path])
    let checkpoint = try await DecisionCheckpointing().checkpoint(
        workspace: fixture.repository.path, ref: "refs/focus-queue/decisions/TST-1/AGENT/D1", message: "D1", push: true)
    #expect(!checkpoint.pushed)
    #expect(checkpoint.pushError?.contains("git push origin") == true)
    #expect(try await fixture.git(["rev-parse", checkpoint.ref]) == checkpoint.commit)
}

@Test("Restoring moves an unpublished branch back and makes the files match the checkpoint")
func decisionRestoreMovesUnpublishedBranch() async throws {
    let fixture = try await DecisionGitFixture()
    try fixture.write("base\nat decision\n", to: "a.txt")
    try fixture.write("untracked at decision\n", to: "kept.txt")
    try fixture.write("ignored\n", to: "build/out.o")
    let checkpointing = DecisionCheckpointing()
    let checkpoint = try await checkpointing.checkpoint(
        workspace: fixture.repository.path, ref: "refs/focus-queue/decisions/TST-1/AGENT/D1", message: "D1", push: true)
    try fixture.write("after\n", to: "a.txt")
    try await fixture.commit("option A")
    try fixture.write("later\n", to: "later.txt")
    try FileManager.default.removeItem(at: fixture.repository.appendingPathComponent("kept.txt"))

    let result = try await checkpointing.restore(
        workspace: fixture.repository.path, to: checkpoint,
        preserving: "refs/focus-queue/decisions/TST-1/AGENT/D1-abandoned", message: "abandoned", push: true)
    #expect(result.movedBranch && result.branchNote == nil)
    #expect(try await fixture.git(["rev-parse", "HEAD"]) == checkpoint.parent)
    #expect(fixture.read("a.txt") == "base\nat decision\n")
    #expect(fixture.read("kept.txt") == "untracked at decision\n")
    #expect(!fixture.exists("later.txt"))
    #expect(fixture.read("build/out.o") == "ignored\n")
    #expect(try await fixture.git(["status", "--porcelain"]) == "M a.txt\n?? kept.txt")
    // The abandoned path is kept, with its commit and its untracked file.
    #expect(try await fixture.git(["show", "\(result.saved.commit):later.txt"]) == "later")
    #expect(try await fixture.git(["log", "--format=%s", "-1", "\(result.saved.commit)^"]) == "option A")
    #expect(try await fixture.remoteRefs().contains("refs/focus-queue/decisions/TST-1/AGENT/D1-abandoned"))
}

@Test("Restoring keeps published history and leaves the restored files as changes")
func decisionRestoreKeepsPublishedHistory() async throws {
    let fixture = try await DecisionGitFixture()
    let checkpointing = DecisionCheckpointing()
    let checkpoint = try await checkpointing.checkpoint(
        workspace: fixture.repository.path, ref: "refs/focus-queue/decisions/TST-1/AGENT/D1", message: "D1", push: false)
    try fixture.write("published\n", to: "a.txt")
    try await fixture.commit("published commit")
    _ = try await fixture.git(["-c", "core.hooksPath=/dev/null", "push", "-q", "-u", "origin", "HEAD"])
    let head = try await fixture.git(["rev-parse", "HEAD"])

    let result = try await checkpointing.restore(
        workspace: fixture.repository.path, to: checkpoint,
        preserving: "refs/focus-queue/decisions/TST-1/AGENT/D1-abandoned", message: "abandoned", push: false)
    #expect(!result.movedBranch)
    #expect(result.branchNote?.contains("already on a remote") == true)
    #expect(try await fixture.git(["rev-parse", "HEAD"]) == head)
    #expect(fixture.read("a.txt") == "base\n")
}

@Test("Rewinds refuse an integration branch checkout")
func decisionRestoreRefusesIntegrationBranch() async throws {
    let fixture = try await DecisionGitFixture(branch: "main")
    let checkpointing = DecisionCheckpointing()
    let checkpoint = try await checkpointing.checkpoint(
        workspace: fixture.repository.path, ref: "refs/focus-queue/decisions/TST-1/AGENT/D1", message: "D1", push: false)
    await #expect(throws: DecisionTreeError.self) {
        _ = try await checkpointing.restore(workspace: fixture.repository.path, to: checkpoint,
                                            preserving: "refs/focus-queue/x", message: "x", push: false)
    }
}

// MARK: - Conversations

@Test("A Claude snapshot stops at the last user turn and forks under a new session ID")
func decisionClaudeSnapshotAndFork() async throws {
    let fixture = try await DecisionGitFixture()
    let claude = fixture.root.appendingPathComponent("claude")
    _ = try await serviceFixture(workspace: fixture.repository, claudeRoot: claude)
    let transcript = try #require(DecisionConversations.claudeTranscript(
        sessionID: sessionID, workspace: fixture.repository.path, root: claude))
    let snapshot = fixture.root.appendingPathComponent("snap/D1.jsonl")
    #expect(try DecisionConversations.snapshotClaude(transcript: transcript, destination: snapshot) == 3)
    let fork = try DecisionConversations.materializeClaude(
        snapshot: snapshot, originalSessionID: sessionID, workspace: fixture.repository.path, root: claude,
        newSessionID: "22222222-3333-4444-5555-666666666666")
    let forked = try String(contentsOf: transcript.deletingLastPathComponent().appendingPathComponent("\(fork).jsonl"),
                            encoding: .utf8)
    #expect(forked.split(separator: "\n").count == 3)
    #expect(!forked.contains(sessionID) && forked.contains("\"sessionId\":\"\(fork)\""))
    #expect(try String(contentsOf: transcript, encoding: .utf8).split(separator: "\n").count == 4)

    // A finished reply is kept when the decision is recorded from outside the agent's turn.
    let finished = fixture.root.appendingPathComponent("finished.jsonl")
    try Data((#"{"type":"user","sessionId":"s","message":{"role":"user","content":"hi"}}"# + "\n"
        + #"{"type":"assistant","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"noted"}]}}"# + "\n"
        + #"{"type":"api-request","sessionId":"s"}"# + "\n").utf8).write(to: finished)
    #expect(try DecisionConversations.snapshotClaude(transcript: finished, destination: snapshot) == 2)
}

// MARK: - Service

@Test("Record, choose, and rewind keep the tree, the record, and the agent in step")
func decisionServiceFlow() async throws {
    let fixture = try await DecisionGitFixture()
    let claude = fixture.root.appendingPathComponent("claude")
    let support = try await serviceFixture(workspace: fixture.repository, claudeRoot: claude)
    let control = RecordingControl()
    let service = DecisionTreeService(root: support, claudeRoot: claude, control: control)
    let agent = try await service.agent(taskID: "tst-1", agentID: agentID.lowercased())
    #expect(agent.agentID == agentID && agent.workspace == fixture.repository.path)

    let recorded = try await service.record(agent: agent, title: "Use JSON", divergence: .taskPlan, detail: "Plan said Markdown",
                                            options: ["JSON", "Markdown"], chosen: nil)
    #expect(recorded.node.status == .pending && recorded.node.checkpoint?.pushed == true)
    #expect(recorded.node.conversation?.forkable == true)
    #expect(recorded.dueAt != nil)
    var context = try #require(try await TaskContextStore(root: support).load(ticketID: "TST-1"))
    #expect(context.subtasks.first?.attention == .question)

    let settled = try await service.choose(taskID: "TST-1", agentID: agentID, nodeID: nil, optionID: "continue",
                                           by: .continue, resume: true)
    #expect(settled.optionID == "A" && settled.delivery == "sent")
    #expect(await control.delivered.last?.text.contains("The user said continue") == true)
    context = try #require(try await TaskContextStore(root: support).load(ticketID: "TST-1"))
    #expect(context.subtasks.first?.attention == nil)

    try fixture.write("json work\n", to: "a.txt")
    let rewound = try await service.rewind(taskID: "TST-1", agentID: agentID, nodeID: "D1", optionID: nil, by: .user,
                                           reason: "JSON did not render", restart: true, deferRestart: false)
    #expect(rewound.option.id == "B" && rewound.conversationForked)
    #expect(fixture.read("a.txt") == "base\n")
    let restart = try #require(await control.restarted.last)
    #expect(restart.session == rewound.sessionID && !restart.deferred)
    #expect(restart.prompt.contains("Take option B: Markdown") && restart.prompt.contains("JSON did not render"))
    context = try #require(try await TaskContextStore(root: support).load(ticketID: "TST-1"))
    #expect(context.subtasks.first?.sessionID == rewound.sessionID)
    let tree = try #require(try service.store.load(taskID: "TST-1", agentID: agentID))
    #expect(tree.head == DecisionHead(nodeID: "D1", optionID: "B") && tree.pendingRestart == nil)
    let log = try String(contentsOf: support.appendingPathComponent("tasks/TST-1/agent-log.md"), encoding: .utf8)
    #expect(log.contains("Rewound to decision D1 by the user"))
}

@Test("An agent's own rewind defers its restart and respects the auto-rewind setting")
func decisionAgentRewindRules() async throws {
    let fixture = try await DecisionGitFixture()
    let claude = fixture.root.appendingPathComponent("claude")
    let support = try await serviceFixture(workspace: fixture.repository, claudeRoot: claude,
                                           settings: ["decisionAutoRewind": false])
    let control = RecordingControl()
    let service = DecisionTreeService(root: support, claudeRoot: claude, control: control)
    let agent = try await service.agent(taskID: "TST-1", agentID: agentID)
    _ = try await service.record(agent: agent, title: "Split", divergence: .userInstruction, detail: nil,
                                 options: ["One file", "Two files"], chosen: "recommended", push: false)
    await #expect(throws: DecisionTreeError.self) {
        _ = try await service.rewind(taskID: "TST-1", agentID: agentID, nodeID: "D1", optionID: nil, by: .agent,
                                     reason: nil, restart: true, deferRestart: true)
    }
    try JSONSerialization.data(withJSONObject: ["tmuxExecutable": "/usr/bin/false", "decisionAutoRewind": true])
        .write(to: support.appendingPathComponent("config.json"))
    let rewound = try await service.rewind(taskID: "TST-1", agentID: agentID, nodeID: "D1", optionID: nil, by: .agent,
                                           reason: "two files read better", restart: true, deferRestart: true)
    #expect(rewound.restart == "scheduled")
    #expect(try service.store.load(taskID: "TST-1", agentID: agentID)?.pendingRestart?.nodeID == "D1")
    #expect(try await service.performPendingRestart(taskID: "TST-1", agentID: agentID, delaySeconds: 0) == "reopened")
    #expect(try service.store.load(taskID: "TST-1", agentID: agentID)?.pendingRestart == nil)
    #expect(try await service.performPendingRestart(taskID: "TST-1", agentID: agentID, delaySeconds: 0) == "nothing pending")
}

@Test("Auto-decide settles an overdue node once and resumes its agent")
func decisionAutoDecide() async throws {
    let fixture = try await DecisionGitFixture()
    let claude = fixture.root.appendingPathComponent("claude")
    let support = try await serviceFixture(workspace: fixture.repository, claudeRoot: claude)
    let control = RecordingControl()
    let service = DecisionTreeService(root: support, claudeRoot: claude, control: control)
    let agent = try await service.agent(taskID: "TST-1", agentID: agentID)
    let recorded = try await service.record(agent: agent, title: "Rename", divergence: .masterPlan, detail: nil,
                                            options: ["Keep name", "Rename"], chosen: nil, push: false)
    let due = try #require(recorded.dueAt)
    #expect(await service.applyDue(now: due.addingTimeInterval(-1)).isEmpty)
    #expect(await service.applyDue(now: due, settings: DecisionAutomationSettings(autoDecide: false)).isEmpty)
    let settled = await service.applyDue(now: due.addingTimeInterval(1))
    #expect(settled.map(\.optionID) == ["A"])
    #expect(await control.delivered.count == 1)
    #expect(await control.delivered.first?.text.contains("No reply came within 1 hour") == true)
    #expect(await service.applyDue(now: due.addingTimeInterval(120)).isEmpty)
    #expect(await control.delivered.count == 1)
    let node = try #require(try service.store.load(taskID: "TST-1", agentID: agentID)?.node("D1"))
    #expect(node.decidedBy == .auto && node.chosenOptionID == "A")
}

// MARK: - Command parsing

@Test("Decision commands take explicit IDs or the agent's environment")
func decisionCommandIdentity() throws {
    let environment = ["FOCUS_QUEUE_TASK_ID": "foc-9", "FOCUS_QUEUE_SUBTASK_ID": agentID]
    let explicit = try DecisionTreeCommand.identity(["FOC-1", "AGENT-1", "Title"], environment: environment, positional: 1)
    #expect(explicit.0 == "FOC-1" && explicit.1 == "AGENT-1" && explicit.2 == ["Title"])
    let implicit = try DecisionTreeCommand.identity(["Title"], environment: environment, positional: 1)
    #expect(implicit.0 == "FOC-9" && implicit.1 == agentID && implicit.2 == ["Title"])
    let choose = try DecisionTreeCommand.identity(["D2", "B"], environment: environment, positional: nil)
    #expect(choose.0 == "FOC-9" && choose.2 == ["D2", "B"])
    let chooseExplicit = try DecisionTreeCommand.identity(["FOC-1", agentID, "B"], environment: environment, positional: nil)
    #expect(chooseExplicit.0 == "FOC-1" && chooseExplicit.2 == ["B"])
    #expect(throws: DecisionTreeError.self) {
        _ = try DecisionTreeCommand.identity(["Title"], environment: [:], positional: 1)
    }
}

// MARK: - Orchestrator rules

@Test("Every orchestrator gets Focus Queue's rules, with or without a signed project contract")
func focusQueueOrchestratorRulesReachOrchestrators() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("orchestrator-rules-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = ProjectDefinition(id: "plain", name: "Plain", taskPrefix: "PLN",
                                    repositoryPath: root.appendingPathComponent("repo").path)
    _ = try ProjectContextStore(root: root).ensurePlan(for: project)
    let context = try await TaskContextStore(root: root).ensureContext(
        ticket: DashboardTicket(id: "PLN-1", title: "Plan", status: "in-progress", summary: "Route the work."),
        project: project)
    var orchestrator = TaskSubtask(title: "Route the work")
    orchestrator.launchConfiguration = AgentLaunchConfiguration(role: "orchestrator")
    let engineer = TaskSubtask(title: "Build it")

    let brief = context.agentPrompt(subtask: orchestrator)
    #expect(brief.contains(FocusQueueOrchestratorRules.block))
    #expect(brief.contains("**Act, do not announce.**") && brief.contains("decision rewind <TASK> <AGENT> <NODE>"))
    #expect(!context.agentPrompt(subtask: engineer).contains(FocusQueueOrchestratorRules.title))

    let block = try #require(TaskContext.sharedDataBlock(root: root, projectID: project.id, role: .orchestrator))
    #expect(block.contains(FocusQueueOrchestratorRules.block) && brief.contains(block))
    #expect(TaskContext.sharedDataBlock(root: root, projectID: project.id, role: .engineering)?
        .contains(FocusQueueOrchestratorRules.title) != true)
    // An orchestrator started from a shell gets them from the prompt hook.
    let payload: [String: Any] = ["session_id": UUID().uuidString, "hook_event_name": "UserPromptSubmit", "prompt": "hi"]
    let delivered = try #require(SharedDataDelivery.context(payload: payload, provider: "claude", projectID: project.id,
                                                            root: root, role: .orchestrator))
    #expect(delivered.contains("**Blockers wait, then proceed.**"))
    // The rules stay concise: four rules, each with the exact command to run.
    let rules = FocusQueueOrchestratorRules.text.split(separator: "\n").filter { $0.hasPrefix("- **") }
    #expect(rules.count == 4 && rules.allSatisfy { $0.contains("`focus-queue-session ") })
    #expect(FocusQueueOrchestratorRules.text.count < 1_600)
    // Generated project contracts must not repeat them.
    let inputs = try AgentContractGenerator.inputs(project: project, root: root, process: nil, home: root)
    #expect(inputs.alreadyInjected.contains(FocusQueueOrchestratorRules.text))
}
