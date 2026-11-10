import Foundation
import Testing
@testable import FocusQueueCore

private func contractFixture() throws -> (root: URL, project: ProjectDefinition, directory: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-contract-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = ProjectDefinition(id: "demo", name: "Demo", taskPrefix: "DEM",
        repositoryPath: root.appendingPathComponent("repo").path)
    let plan = try ProjectContextStore(root: root).ensurePlan(for: project)
    _ = try DevelopmentProcessStore(root: root).ensure(projectID: project.id)
    return (root, project, plan.deletingLastPathComponent())
}

private let engineeringContract = """
# Demo engineering agent contract

Project rules for every Demo engineering agent. Your task plan carries any phase- or task-specific rules.

## Essentials

- **Follow the plan documents.** The [plan](plan.md) records the owner's decisions; your task plan scopes your work.
- **Done means verified.** Show the command, its output, and the commit for each success criterion.

## Recommended

Follow these unless your task says otherwise.

- **Write the check first.** Add the failing test before the fix.
"""

private let orchestratorContract = """
# Demo orchestrator contract

## Essentials

- **Sequence by dependency.** Assign work in dependency order and open a stage only after its gate passes.
- **One owner per area.** Never give two running agents overlapping files.

## Recommended

- **Staff the critical path first.** It sets the finish date.
"""

private let contractTicket = DashboardTicket(id: "DEM-001", title: "Build login", status: "open",
                                             summary: "Implement the login module.")

private func write(_ text: String, _ name: String, in directory: URL) throws {
    try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
}

/// Captures the generator call and answers with a canned reply.
private actor StubContractAgent: QueueAgentChatting {
    let reply: String
    private(set) var message = ""
    private(set) var configuration: VerifierConfiguration?
    private(set) var workspace = ""
    init(reply: String) { self.reply = reply }

    func send(message: String, dashboardPath: String, workspace: String, visibleOrder: [String],
              deferredTicketIDs: [String], configuration: VerifierConfiguration,
              model: String?, effort: String?) async throws -> QueueAgentReply {
        self.message = message; self.configuration = configuration; self.workspace = workspace
        return QueueAgentReply(message: reply, log: "")
    }

    func reset(configuration: VerifierConfiguration) async throws {}
}

@Test("Launch roles map to contracts: only orchestrator differs from engineering")
func contractRoleMapping() {
    #expect(AgentContractRole(launchRole: nil) == .engineering)
    #expect(AgentContractRole(launchRole: "coding") == .engineering)
    #expect(AgentContractRole(launchRole: "research") == .engineering)
    #expect(AgentContractRole(launchRole: " Orchestrator ") == .orchestrator)
    #expect(AgentContractRole(fileName: "orchestration.draft.md") == .orchestrator)
    #expect(AgentContractRole(fileName: "agent-contract.md") == .engineering)
    #expect(AgentContractRole(fileName: "prd.md") == nil)
    #expect(AgentLaunchConfiguration(role: "orchestrator").contractRole == .orchestrator)
    #expect(AgentLaunchConfiguration().contractRole == .engineering)
}

@Test("The compiled generator prompt is the Config file's prompt block")
func generatorPromptMatchesConfig() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: repository.appendingPathComponent("Config/contract-generator-prompt.md"),
                            encoding: .utf8)
    let start = try #require(source.range(of: "```text\n"))
    let end = try #require(source.range(of: "\n```", range: start.upperBound..<source.endIndex))
    #expect(String(source[start.upperBound..<end.lowerBound]) == AgentContractGeneratorPrompt.template)
}

@Test("Essentials is the section alone, or the body when a file has no sections")
func essentialsExtraction() {
    let essentials = AgentContract.essentials(of: engineeringContract)
    #expect(essentials.hasPrefix("- **Follow the plan documents.**"))
    #expect(essentials.contains("Done means verified"))
    #expect(!essentials.contains("Write the check first"))
    #expect(!essentials.contains("Project rules for every"))
    let bare = "# Rules\n\n- **Keep secrets out.** Credentials never enter commits.\n"
    #expect(AgentContract.essentials(of: bare) == "- **Keep secrets out.** Credentials never enter commits.")
    let linked = AgentContract.absolutizingLinks(in: "See [plan](plan.md), [web](https://x.y), [abs](/a/b.md).",
                                                 directory: URL(fileURLWithPath: "/p/demo"))
    #expect(linked == "See [plan](/p/demo/plan.md), [web](https://x.y), [abs](/a/b.md).")
}

@Test("Lint flags structure, caps, long sentences, state terms, emphasis, and broken links")
func contractLint() throws {
    let (root, _, directory) = try contractFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(AgentContract.lint(engineeringContract, role: .engineering, directory: directory).isEmpty)

    let noisy = """
    # Demo engineering agent contract

    ## Essentials

    - **Gate.** Finish Phase 0 work before KAI-012 lands on 2026-11-10 with version 0.3.5 on macOS.
    - **Report.** Run `attention` when blocked; read [`plan.md`](plan.md) first and [gone](missing.md).
    - **Tone.** You MUST stay on task.
    - **Long.** This sentence keeps going with many words so that it runs well past the twenty five word limit the generator sets for every single rule here.
    - **Five.** One.
    - **Six.** Two.
    """
    let issues = AgentContract.lint(noisy, role: .engineering, directory: directory).map(\.text)
    #expect(issues.contains { $0.contains("expected Essentials, then Recommended") })
    #expect(issues.contains { $0.contains("Essentials has 6 rules; the limit is 5") })
    for label in ["names a phase", "names a task ID", "names a date", "names a version", "names a platform",
                  "names a command (“attention”)", "uses emphasis (“MUST”)", "link target does not exist: missing.md",
                  "words; keep each at 25 or fewer"] {
        #expect(issues.contains { $0.contains(label) }, "missing lint: \(label)")
    }
    // A file name in code style is a reference, not a command.
    #expect(!issues.contains { $0.contains("“plan.md”") })
    // The tick closing a link label never opens a span across the rest of the line.
    let label = "## Essentials\n\n- **Plans.** [`plan.md`](plan.md) records decisions; raise `attention` when blocked.\n\n## Recommended\n"
    #expect(AgentContract.lint(label, role: .engineering, directory: directory).map(\.message)
        == ["names a command (“attention”)."])
    let versionAtEnd = "## Essentials\n\n- **Pin.** Use Node 24.1.\n\n## Recommended\n"
    #expect(AgentContract.lint(versionAtEnd, role: .engineering, directory: directory)
        .contains { $0.message.contains("names a version (“24.1”)") })
}

@Test("Only signed text reaches agents; pending edits keep the signed version live")
func contractSignoffLifecycle() throws {
    let (root, project, directory) = try contractFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    #expect(try store.contractStatus(role: .engineering, projectID: project.id, process: store.load(projectID: project.id)).state == .missing)

    try write(engineeringContract, "agent-contract.md", in: directory)
    var process = try #require(try store.load(projectID: project.id))
    #expect(try store.contractStatus(role: .engineering, projectID: project.id, process: process).state == .unsigned)
    #expect(AgentContract.injection(role: .engineering, directory: directory, process: process) == nil)

    // The owner signs exactly the text they saw; a different text is refused.
    #expect(throws: AgentContractError.changedOnDisk("agent-contract.md")) {
        try store.signContract(role: .engineering, text: "stale view", projectID: project.id)
    }
    process = try store.signContract(role: .engineering, text: engineeringContract, projectID: project.id)
    #expect(process.contracts["engineering"]?.sha256 == AgentContract.digest(engineeringContract))
    #expect(process.contracts["engineering"]?.signedBy == "human")
    #expect(process.steps["contract"]?.checkedArtifacts == ["agent-contract.md"])
    #expect(try store.contractStatus(role: .engineering, projectID: project.id, process: process).state == .live)
    let live = try #require(AgentContract.injection(role: .engineering, directory: directory, process: process))
    #expect(live.lines[0] == "Engineering contract (Essentials; Recommended practices in \(directory.appendingPathComponent("agent-contract.md").path)):")
    #expect(live.lines[1].contains("[plan](\(directory.appendingPathComponent("plan.md").path))"))
    #expect(!live.lines.joined().contains("Write the check first"))
    #expect(live.inlinedCharacters == live.lines[1].count)

    // An agent edit is not injected until signed: the signed text stays live.
    try write(engineeringContract.replacingOccurrences(of: "Done means verified", with: "Ship fast"),
              "agent-contract.md", in: directory)
    #expect(try store.contractStatus(role: .engineering, projectID: project.id, process: process).state == .pending)
    let pending = try #require(AgentContract.injection(role: .engineering, directory: directory, process: process))
    #expect(pending.lines[0].contains("has unsigned changes, follow this text"))
    #expect(pending.lines[1].contains("Done means verified"))
    #expect(!pending.lines[1].contains("Ship fast"))

    // Signing both documents completes the Planning contract step.
    try write(orchestratorContract, "orchestration.md", in: directory)
    process = try store.signContract(role: .orchestrator, text: orchestratorContract, projectID: project.id)
    #expect(process.steps["contract"]?.status == .done)
    let engineering = try #require(AgentContract.injection(role: .engineering, directory: directory, process: process))
    #expect(engineering.lines.last == "Orchestrator contract: \(directory.appendingPathComponent("orchestration.md").path)")

    process = try store.revokeContract(role: .orchestrator, projectID: project.id)
    #expect(process.contracts["orchestrator"] == nil)
    // Without its own signed contract, an orchestrator still learns where the engineers' rules live.
    let unsigned = try #require(AgentContract.injection(role: .orchestrator, directory: directory, process: process))
    #expect(unsigned.lines == ["Engineering contract: \(directory.appendingPathComponent("agent-contract.md").path)"])
    #expect(unsigned.inlinedCharacters == 0)
}

@Test("A draft replaces the live contract only on sign-off, and propose never touches the live file")
func contractDraftPromotion() throws {
    let (root, project, directory) = try contractFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    try write(engineeringContract, "agent-contract.md", in: directory)
    _ = try store.signContract(role: .engineering, text: engineeringContract, projectID: project.id)

    let proposed = engineeringContract.replacingOccurrences(of: "Done means verified", with: "Done means proven")
    let draft = try store.proposeContract(role: .engineering, text: proposed, projectID: project.id)
    #expect(draft.lastPathComponent == "agent-contract.draft.md")
    var process = try #require(try store.load(projectID: project.id))
    let status = try store.contractStatus(role: .engineering, projectID: project.id, process: process)
    #expect(status.state == .live && status.hasDraft)
    #expect(try String(contentsOf: directory.appendingPathComponent("agent-contract.md"), encoding: .utf8) == engineeringContract)

    process = try store.promoteContractDraft(role: .engineering, text: proposed, projectID: project.id)
    #expect(try String(contentsOf: directory.appendingPathComponent("agent-contract.md"), encoding: .utf8) == proposed)
    #expect(!FileManager.default.fileExists(atPath: draft.path))
    #expect(process.contracts["engineering"]?.text == proposed)
}

@Test("Each role's brief carries only its own Essentials, capped, and the hook block matches the brief")
func roleScopedBriefs() async throws {
    let (root, project, directory) = try contractFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    try write(engineeringContract, "agent-contract.md", in: directory)
    try write(orchestratorContract, "orchestration.md", in: directory)
    _ = try store.signContract(role: .engineering, text: engineeringContract, projectID: project.id)
    _ = try store.signContract(role: .orchestrator, text: orchestratorContract, projectID: project.id)
    try "- Start every message with a heart.\n".write(to: directory.appendingPathComponent("data.md"),
                                                      atomically: true, encoding: .utf8)
    let context = try await TaskContextStore(root: root).ensureContext(ticket: contractTicket, project: project)

    let engineer = TaskSubtask(title: "Build login")
    let brief = context.agentPrompt(subtask: engineer)
    #expect(brief.contains("Done means verified"))
    #expect(!brief.contains("Sequence by dependency"))
    #expect(brief.contains("Orchestrator contract: \(directory.appendingPathComponent("orchestration.md").path)"))
    #expect(context.agentBootstrap(subtask: engineer).contains("Done means verified"))
    #expect(context.inlinedAgentContextCharacters(subtask: engineer)["engineering_contract"] != nil)

    var orchestrator = TaskSubtask(title: "Plan the phase")
    orchestrator.launchConfiguration = AgentLaunchConfiguration(role: "orchestrator")
    let orchestratorBrief = context.agentPrompt(subtask: orchestrator)
    #expect(orchestratorBrief.contains("Sequence by dependency"))
    #expect(!orchestratorBrief.contains("Done means verified"))
    #expect(context.inlinedAgentContextCharacters(subtask: orchestrator)["orchestration_contract"] != nil)

    // The prompt hook sends nothing new on the first prompt: the brief already holds its block.
    for (subtask, role) in [(engineer, AgentContractRole.engineering), (orchestrator, .orchestrator)] {
        let block = try #require(TaskContext.sharedDataBlock(root: root, projectID: project.id, role: role))
        #expect(context.agentPrompt(subtask: subtask).contains(block))
        #expect(context.agentBootstrap(subtask: subtask).contains(block))
        let payload: [String: Any] = ["session_id": UUID().uuidString, "hook_event_name": "UserPromptSubmit",
                                      "prompt": context.agentPrompt(subtask: subtask)]
        #expect(SharedDataDelivery.context(payload: payload, provider: "claude", projectID: project.id,
                                           root: root, role: role) == nil)
    }
    // A shell launch with no brief gets the role's contract from the hook.
    let fresh: [String: Any] = ["session_id": UUID().uuidString, "hook_event_name": "UserPromptSubmit", "prompt": "hi"]
    let delivered = try #require(SharedDataDelivery.context(payload: fresh, provider: "claude",
                                                            projectID: project.id, root: root, role: .orchestrator))
    #expect(delivered.contains("Sequence by dependency") && !delivered.contains("Done means verified"))
    let factsOnly = try #require(TaskContext.sharedDataBlock(root: root, projectID: project.id))
    #expect(!factsOnly.contains("Done means verified") && !factsOnly.contains("Sequence by dependency"))

    // Each inlined contract stops at its cap between whole rules, with a pointer to the file.
    let rules = (1...40).map { "- **Rule \($0).** Keep this rule short and plain for every agent." }.joined(separator: "\n")
    let long = "# Long\n\n## Essentials\n\n\(rules)\n"
    try write(long, "agent-contract.md", in: directory)
    let process = try store.signContract(role: .engineering, text: long, projectID: project.id)
    let capped = try #require(AgentContract.injection(role: .engineering, directory: directory, process: process))
    let pointer = "… (truncated; read \(directory.appendingPathComponent("agent-contract.md").path) for the rest)"
    #expect(capped.lines[1].hasSuffix("\n" + pointer))
    let kept = capped.lines[1].components(separatedBy: "\n").dropLast()
    #expect(kept.allSatisfy { $0.hasPrefix("- **Rule ") && $0.hasSuffix("every agent.") })
    #expect(kept.joined(separator: "\n").count <= AgentContract.injectionLimit)
    // Orchestrator Essentials within the generator's 1,600 limit are never cut.
    #expect(AgentContract.injectionLimit(for: .orchestrator) == 1_600)
    #expect(AgentContract.injectionLimit(for: .engineering) == 1_500)
}

@Test("The generator fills every input, runs one read-only reader turn, and writes drafts beside live files")
func contractGeneratorWritesDrafts() async throws {
    let (root, project, directory) = try contractFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: project.repositoryPath)
    try FileManager.default.createDirectory(at: repository.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try "# Master\n".write(to: repository.appendingPathComponent("docs/master.md"), atomically: true, encoding: .utf8)
    try "# Plan\n\nThe [master plan](docs/master.md) wins conflicts.\n"
        .write(to: directory.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
    try "# PRD\n".write(to: directory.appendingPathComponent("prd.md"), atomically: true, encoding: .utf8)
    try write(orchestratorContract, "orchestration.md", in: directory)

    let reply = """
    Here are the drafts.

    === agent-contract.md ===
    ```markdown
    \(engineeringContract)
    ```

    === orchestration.md ===
    \(orchestratorContract)
    === review notes ===
    - **Follow the plan documents.** plan.md. Keeps agents on the ratified design.
    """
    let agent = StubContractAgent(reply: reply)
    var configuration = AppConfiguration.eccDefault(homeDirectory: root)
    configuration.projects = [project]
    let result = try await AgentContractGenerator(root: root, agent: agent).generate(
        project: project, configuration: configuration, provider: .claude, model: "opus", effort: nil)

    // Missing contract: written in place, unsigned. Existing one: a draft beside it.
    #expect(result.files.map(\.lastPathComponent) == ["agent-contract.md", "orchestration.draft.md"])
    #expect(try String(contentsOf: directory.appendingPathComponent("agent-contract.md"), encoding: .utf8)
        .hasPrefix("# Demo engineering agent contract"))
    #expect(try String(contentsOf: directory.appendingPathComponent("orchestration.md"), encoding: .utf8) == orchestratorContract)
    let review = try String(contentsOf: result.reviewURL, encoding: .utf8)
    #expect(review.contains("## Lint") && review.contains("Keeps agents on the ratified design"))
    let process = try #require(try DevelopmentProcessStore(root: root).load(projectID: project.id))
    #expect(process.contracts.isEmpty)

    let message = await agent.message
    #expect(!message.contains("{{"))
    #expect(message.contains("You draft two system-prompt contracts for Demo"))
    #expect(message.contains("- \(repository.appendingPathComponent("docs/master.md").path)"))
    #expect(message.contains("- \(directory.appendingPathComponent("prd.md").path)"))
    #expect(message.contains("=== orchestration.md (current, not signed off) ==="))
    let used = try #require(await agent.configuration)
    #expect(used.documentReader == true)
    #expect(used.usageSource == "contract_generator")
    #expect(used.runtimeDirectory == root.appendingPathComponent("tracking/contract-generator").path)
    #expect(await agent.workspace == repository.path)
}

@Test("A reply without both contract blocks is rejected")
func contractGeneratorRejectsPartialReply() {
    #expect(throws: AgentContractError.malformedOutput("no orchestration.md block")) {
        try AgentContractGenerator.parse("=== agent-contract.md ===\n# A\n")
    }
    let parsed = try? AgentContractGenerator.parse("=== agent-contract.md ===\n# A\n\n=== orchestration.md ===\n# B\n")
    #expect(parsed?.engineering == "# A\n" && parsed?.orchestrator == "# B\n" && parsed?.reviewNotes == "")
}
