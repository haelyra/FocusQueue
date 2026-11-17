import Foundation
import Testing
@testable import FocusQueueCore

private let plan = """
# Demo development plan

KAI-like intro: DEM-3 covers A2 plus setup, and DEM-9 covers nothing listed.

## A. Planning completion

- **A1. Write the module files.**
  Scope: one per module. Modules: M1, M2.
  Deps: none (can precede A2–A3). Docs: none.
- **A2. Prepare the reference machine.**
  Deps: none. Gate: pre-run check passes.
- [x] **A3. Already finished.**
  Deps: A1. Gate: done by hand.

## Phase 1 — Build

Exit gate: the slice works.

- [ ] **1.1. Core protocol.** Task: DEM-1
  Scope: frames. Modules: M4.
  Deps: A1, DEM-2 (its daemon); starts before 1.4 by owner decision. Gate: round trip validates.
- [ ] **1.2. Storage.** Task: —
  Deps: 1.1. Gate: assertions pass.
- [ ] **1.3. Launch pipeline.** Task: —
  Deps: 1.2. Gate: no duplicate agents.
- [ ] **1.4. Gate run.** Task: —
  Deps: 1.1–1.3. Gate: green.

## Task set

| Leaf | Task title | Summary | Task ID |
|---|---|---|---|
| 1.2 | Storage | Build storage | DEM-4 |

## Cross-cutting tracks

- **C1. Provider wave.** Runs beside phases, post-MVP.
- **C2. Benchmarks.** Gate: suites stay green.

## Out of scope

- LSP IDE, Monaco.
"""

private func ticket(_ id: String, _ title: String, status: String = "backlog") -> DashboardTicket {
    DashboardTicket(id: id, title: title, status: status, summary: "")
}

private func demoMap(tickets: [DashboardTicket], process: DevelopmentProcess = DevelopmentProcess()) -> ProjectMap {
    ProjectMapBuilder.build(projectID: "demo", projectName: "Demo", process: process, tickets: tickets,
                            outline: DevelopmentPlanOutline.parse(plan), planFile: "devplan.md",
                            agents: ["DEM-1": [ProjectMap.Agent(title: "Agent 1", provider: "claude",
                                                                status: "working", attention: nil, summary: "")]],
                            now: Date(timeIntervalSince1970: 0))
}

private let demoTickets = [
    ticket("DEM-1", "Core protocol", status: "in-progress"),
    ticket("DEM-2", "Phase 0 daemon spike", status: "resolved"),
    ticket("DEM-3", "Phase 0 entry: reference hardware"),
    ticket("DEM-4", "Storage worker"),
    ticket("DEM-5", "Decide starting 1.3 alongside 1.2"),
    ticket("DEM-6", "Phase 1 1.3: launch pipeline", status: "cancelled"),
]

@Test("The plan parser reads leaves, checkboxes, gates, and dependency text")
func planParserReadsLeaves() {
    let outline = DevelopmentPlanOutline.parse(plan)
    #expect(outline.leaves.map(\.id) == ["A1", "A2", "A3", "1.1", "1.2", "1.3", "1.4", "C1", "C2"])
    let a3 = outline.leaves[2]
    #expect(a3.isChecked && a3.gate == "done by hand.")
    // "none (can precede …)" is no dependency; text after a semicolon is ignored.
    #expect(outline.leaves[0].dependencyText.isEmpty)
    #expect(outline.leafIDs(in: outline.leaves[3].dependencyText) == ["A1"])
    #expect(outline.leafIDs(in: "1.1–1.3") == ["1.1", "1.2", "1.3"])
    #expect(outline.leafIDs(in: "1.1 to 1.3, §1.4") == ["1.1", "1.2", "1.3"])
    #expect(outline.sections.map(\.isTrack) == [false, false, true, true, true])
}

@Test("Tasks cover leaves by Task field, table row, covers sentence, and title label")
func mapCoversLeaves() {
    let map = demoMap(tickets: demoTickets)
    let node = { (id: String) in map.nodes.first { $0.id == id } }
    #expect(node("DEM-1")?.leaves == ["1.1"])     // Task: field
    #expect(node("DEM-3")?.leaves == ["A2"])      // "DEM-3 covers A2"
    #expect(node("DEM-4")?.leaves == ["1.2"])     // task-set table row
    #expect(node("DEM-6")?.leaves == ["1.3"])     // title label "Phase 1 1.3:"
    #expect(node("DEM-5")?.leaves == [])          // a mere mention claims nothing
    #expect(node("DEM-1")?.agents.count == 1)
    // "Decide starting 1.3 alongside 1.2" claims no leaf but mentions Phase 1 leaves.
    #expect(node("DEM-5").map { map.lanes[$0.lane].title } == "Phase 1 — Build")
    #expect(node("DEM-5")?.reason == "Supports this phase; it does not claim a plan leaf.")
}

@Test("Ghosts mark unmet, uncovered leaves only")
func mapGhosts() {
    let map = demoMap(tickets: demoTickets)
    let ghosts = Set(map.nodes.filter { $0.kind == .ghost }.map(\.id))
    // A1 has no task; 1.3's only task was cancelled; 1.4 has none; C2 is a gated track.
    // A3 is ticked, C1 is a gate-less track, and covered leaves need no ghost.
    #expect(ghosts == ["ghost:A1", "ghost:1.3", "ghost:1.4", "ghost:C2"])
    #expect(map.nodes.first { $0.id == "ghost:1.3" }?.reason == "Its only tasks were cancelled.")
}

@Test("Edges follow plan dependencies through tasks and ghosts, plus task dependencies")
func mapEdges() throws {
    var process = DevelopmentProcess()
    try process.setDependencies(taskID: "DEM-5", prerequisites: ["DEM-4"])
    let map = demoMap(tickets: demoTickets, process: process)
    let edges = Set(map.edges.map { "\($0.from)>\($0.to)" })
    #expect(edges.contains("ghost:A1>DEM-1"))       // leaf dependency onto a ghost
    #expect(edges.contains("DEM-2>DEM-1"))           // a task ID in a Deps line
    #expect(edges.contains("DEM-1>DEM-4"))           // 1.2 depends on 1.1
    #expect(edges.contains("DEM-4>DEM-6") && edges.contains("DEM-4>ghost:1.3"))
    #expect(edges.contains("DEM-1>ghost:1.4") && edges.contains("ghost:1.3>ghost:1.4"))
    #expect(edges.contains("DEM-4>DEM-5"))           // development.json dependency
    #expect(!edges.contains { $0.hasPrefix("ghost:A2") || $0.contains(">ghost:A1") })
}

@Test("Module ghosts appear only for modules nothing mentions")
func mapModuleGhosts() {
    let process = DevelopmentProcess(modules: [DevelopmentModule(id: "m9", name: "M9 Workspaces"),
                                               DevelopmentModule(id: "m4", name: "M4", qaAccepted: true)])
    let map = ProjectMapBuilder.build(projectID: "demo", projectName: "Demo", process: process, tickets: demoTickets,
                                      outline: DevelopmentPlanOutline.parse(plan), planFile: nil, agents: [:],
                                      moduleIDs: ["m1", "m7"])
    let ghosts = map.nodes.filter { $0.id.hasPrefix("ghost:module:") }.map(\.id)
    #expect(ghosts == ["ghost:module:m9", "ghost:module:m7"])
}

@Test("The HTML embeds the map without letting task text close the script")
func mapHTMLEscapesScript() {
    let map = demoMap(tickets: [ticket("DEM-1", "Break </script><b>out")])
    let html = ProjectMapHTML.render(map)
    #expect(!html.contains("</script><b>"))
    #expect(html.contains("Break &lt;/script&gt;&lt;b&gt;out"))
    #expect(html.contains("<title>Demo project map</title>"))
}

@Test("The map renders as a ranked tree without scripts, with every node and edge in the markup")
func mapHTMLIsStatic() {
    let map = demoMap(tickets: demoTickets)
    let html = ProjectMapHTML.render(map)
    // The document viewer disables page scripts: the static markup already
    // holds the whole tree, and the interaction script is inline once.
    #expect(html.components(separatedBy: "<script>").count - 1 == 1)
    #expect(html.contains(ProjectMapScript.source))
    for node in map.nodes { #expect(html.contains(#"data-id="\#(node.id)""#)) }
    // Every dependency is drawn once: as a tree edge or as a hidden extra edge.
    #expect(html.components(separatedBy: #"<line class="dep "#).count - 1 == map.edges.count)
    #expect(html.contains(#"class="root" id="root""#))
    #expect(html.contains(#"data-rank="0""#) && html.contains(">R2</div>"))
    #expect(html.contains(#"<details><summary>1 agent<span class="act"></span></summary>"#))
}

@Test("Dashboard writes rebuild the map only for development-process projects")
func dashboardWriteRebuildsMap() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fq-map-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("projects/demo")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let dashboard = project.appendingPathComponent("dashboard.json")
    try Data(#"{"tickets":[]}"#.utf8).write(to: dashboard)
    try plan.write(to: project.appendingPathComponent("devplan.md"), atomically: true, encoding: .utf8)
    let mapURL = project.appendingPathComponent(ProjectMapGenerator.fileName)
    let repository = JSONDashboardRepository()

    // No development.json: no map.
    var snapshot = try await repository.loadSnapshot(from: dashboard)
    snapshot = try await repository.createTicket(ticket("DEM-1", "Core protocol"), in: dashboard,
                                                  expectedRevision: snapshot.revision)
    #expect(!FileManager.default.fileExists(atPath: mapURL.path))

    // Disabled process: still no map.
    let store = DevelopmentProcessStore(root: root)
    try store.setEnabled(false, projectID: "demo")
    snapshot = try await repository.createTicket(ticket("DEM-2", "Second"), in: dashboard,
                                                  expectedRevision: snapshot.revision)
    #expect(!FileManager.default.fileExists(atPath: mapURL.path))

    // Enabled: adding a task writes a map that includes it.
    try store.setEnabled(true, projectID: "demo")
    _ = try await repository.createTicket(ticket("DEM-7", "Phase 1 1.4: gate run"), in: dashboard,
                                          expectedRevision: snapshot.revision)
    let html = try String(contentsOf: mapURL, encoding: .utf8)
    #expect(html.contains(#"data-id="DEM-7""#))
    #expect(html.contains(#"data-id="ghost:1.2""#))
    let built = try #require(try ProjectMapGenerator(root: root).build(projectID: "demo"))
    #expect(built.nodes.first { $0.id == "DEM-7" }?.leaves == ["1.4"])
}

@Test("Tree ranks: root, phases, then tasks one rank below their tree parent")
func mapTreeRanks() {
    let map = demoMap(tickets: demoTickets)
    let html = ProjectMapHTML.render(map)
    // In Phase 1: DEM-1 (1.1) heads the chain DEM-4 (1.2) → DEM-6/ghost 1.3 → ghost 1.4.
    func top(_ id: String) -> Double? {
        guard let range = html.range(of: #"data-id="\#(id)""#) else { return nil }
        let rest = html[range.upperBound...]
        guard let topRange = rest.range(of: "top:") else { return nil }
        return Double(rest[topRange.upperBound...].prefix { $0 == "." || $0.isNumber })
    }
    let rank = ProjectMapHTML.rankHeight
    let one = try! #require(top("DEM-1"))
    #expect(top("DEM-4") == one + rank)
    #expect(top("DEM-6") == one + 2 * rank)
    #expect(top("ghost:1.4") == one + 3 * rank)
    #expect(one == ProjectMapHTML.top + 2 * rank)
}

@Test("Percent complete weighs status and estimates unplanned phases")
func mapProgress() {
    func node(_ id: String, _ status: String, lane: Int, ghost: Bool = false) -> ProjectMap.Node {
        ProjectMap.Node(id: id, kind: ghost ? .ghost : .task, title: id, status: status, lane: lane,
                        leaves: [], gate: nil, phase: nil, agents: [], reason: nil)
    }
    let map = ProjectMap(
        projectID: "p", projectName: "P", planFile: nil, currentPhase: "Planning", generatedAt: Date(),
        lanes: [.init(title: "Phase 1", isTrack: false), .init(title: "Phase 2", isTrack: false),
                .init(title: "Not in the plan", isTrack: true)],
        nodes: [node("A-1", "resolved", lane: 0), node("A-2", "in-progress", lane: 0),
                node("ghost:1.3", "missing", lane: 0, ghost: true), node("A-9", "cancelled", lane: 0),
                node("A-4", "qa", lane: 2)],
        edges: [])
    let progress = ProjectMapHTML.Progress(map)
    // Phase 1: (1 + 0.4 + 0) / 3; the cancelled task is left out.
    #expect(abs((progress.lanes[0] ?? 0) - 1.4 / 3) < 0.0001)
    // Phase 2 has no items: it counts at Phase 1's size (3) with nothing done.
    #expect(progress.estimatedSize == 3)
    #expect(abs((progress.lanes[2] ?? 0) - 0.75) < 0.0001)
    #expect(abs(progress.project - (1.4 + 0.75) / 7) < 0.0001)
    let html = ProjectMapHTML.render(map)
    #expect(html.contains("31% complete"))
    #expect(html.contains("not planned yet · ≈3 tasks"))
}

@Test("Tasks that claim no leaf join the plan phase their title or process phase names")
func unclaimedTasksJoinPlanPhases() {
    var process = DevelopmentProcess()
    process.links["DEM-21"] = DevelopmentTaskLink(phase: .implementation, step: "build", source: .steward)
    process.links["DEM-22"] = DevelopmentTaskLink(phase: .planning, step: "prd", source: .steward)
    process.links["DEM-23"] = DevelopmentTaskLink(phase: .phase0, step: nil, source: .steward)
    let tickets = demoTickets + [
        ticket("DEM-20", "Phase 1 Orchestrator: design docs"),
        ticket("DEM-21", "Storage review"),
        ticket("DEM-22", "Write the PRD"),
        ticket("DEM-23", "Side question"),
        ticket("DEM-24", "Loose chore"),
    ]
    let map = demoMap(tickets: tickets, process: process)
    func lane(_ id: String) -> String? { map.nodes.first { $0.id == id }.map { map.lanes[$0.lane].title } }
    #expect(lane("DEM-20") == "Phase 1 — Build")             // title names Phase 1
    #expect(lane("DEM-21") == "Phase 1 — Build")             // "Phase 1+" → earliest build phase with open work
    #expect(lane("DEM-22") == "A. Planning completion")      // process Planning → the planning section
    #expect(lane("DEM-23") == "Outside the development process or unlinked")
    #expect(lane("DEM-24") == "Outside the development process or unlinked")
    #expect(!map.lanes.contains { $0.title.hasPrefix("Not in the plan") })
    #expect(map.nodes.allSatisfy { $0.phase == nil })        // process phase names never show
}

@Test("Task cards carry a menu button, live slots, and a pulse for agents working at generation time")
func mapLiveMarkup() {
    let map = demoMap(tickets: demoTickets)   // DEM-1 has one working Claude agent
    let html = ProjectMapHTML.render(map)
    #expect(html.contains(#"<symbol id="pv-claude""#) && html.contains(#"<symbol id="act-editing""#))
    #expect(html.contains(#"aria-label="Task actions for DEM-1""#))
    #expect(html.contains(#"<div class="agents"><i class="pv working" title="Agent 1 (claude) · Working">"#))
    #expect(html.contains(#"<span class="agentlegend""#) && html.contains("Needs you</span>"))
    #expect(html.contains(#"<span class="act"></span>"#))
}

@Test("Agent states: attention wins over status, finished agents are hidden")
func agentStates() {
    typealias S = ProjectMap.State
    #expect(S(status: "working", attention: nil) == .working)
    #expect(S(status: "idle", attention: "approval") == .attention)
    #expect(S(status: "idle", attention: "question") == .attention)
    #expect(S(status: "blocked", attention: "interrupted") == .interrupted)
    #expect(S(status: "working", attention: "quotaExhausted") == .blocked)
    #expect(S(status: "blocked", attention: nil) == .blocked)
    #expect(S(status: "queued", attention: nil) == .idle)
    #expect(S(status: "completed", attention: nil) == nil)
}
