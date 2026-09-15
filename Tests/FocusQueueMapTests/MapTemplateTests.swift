import Foundation
import Testing
@testable import FocusQueueMap

@Suite("Reusable map template and projections")
struct MapTemplateTests {
    func snapshot(fileCount: Int = 3) -> MapSnapshot {
        var nodes = [
            MapNode(id: "queue", parentID: nil, kind: .queue, label: "Focus Queue", evidence: "Task"),
            MapNode(id: "context", parentID: "queue", kind: .context, label: "Context", evidence: "Task"),
            MapNode(id: "plan", parentID: "context", kind: .document, label: "Central plan", path: "/task/plan.md", evidence: "Task"),
            MapNode(id: "evidence", parentID: "context", kind: .document, label: "Task context and evidence links", evidence: "Task"),
            MapNode(id: "map", parentID: "context", kind: .document, label: "Task map", evidence: "Task"),
            MapNode(id: "work", parentID: "queue", kind: .workspace, label: "Repo", path: "/repo", evidence: "Git"),
            MapNode(id: "readme", parentID: "work", kind: .file, label: "README.md", path: "/repo/README.md", evidence: "Provided"),
            MapNode(id: "source", parentID: "work", kind: .folder, label: "Sources", path: "/repo/Sources", evidence: "Git"),
            MapNode(id: "brief", parentID: "context", kind: .document, label: "Brief", path: "/task/brief.md", evidence: "Input"),
            MapNode(id: "a", parentID: "work", kind: .agent, label: "Writer", evidence: "Registration", subtaskID: "writer"),
            MapNode(id: "b", parentID: "work", kind: .agent, label: "Reviewer", evidence: "Registration", subtaskID: "reviewer"),
            MapNode(id: "research", parentID: "plan", kind: .section, label: "Research", evidence: "Heading"),
            MapNode(id: "link", parentID: "research", kind: .link, label: "Paper", evidence: "Heading link", destination: "https://example.com/paper"),
            MapNode(id: "db", parentID: "work", kind: .resource, label: "Test DB", evidence: "Declared", durable: true)
        ]
        var edges = [MapRelation(from: "plan", to: "a", kind: .input, evidence: "Provided", observedAt: nil),
                     MapRelation(from: "readme", to: "a", kind: .input, evidence: "Provided", observedAt: nil),
                     MapRelation(from: "brief", to: "a", kind: .input, evidence: "Declared input", observedAt: nil),
                     MapRelation(from: "db", to: "a", kind: .dependency, evidence: "Declared", observedAt: nil)]
        for i in 0..<fileCount {
            let id = "file\(i)"
            nodes.append(MapNode(id: id, parentID: "source", kind: .file, label: "\(i).swift", path: "/repo/Sources/\(i).swift", evidence: "Scope"))
            edges.append(MapRelation(from: "a", to: id, kind: .output, evidence: "Declared output", observedAt: nil))
        }
        edges.append(.init(from: "file0", to: "db", kind: .feedback, evidence: "Declared", observedAt: nil))
        return .init(taskID: "TEST", generatedAt: Date(), nodes: nodes, relations: edges)
    }

    func assertPacked(_ diagram: MapDiagram) {
        #expect(Set(diagram.items.map(\.id)).count == diagram.items.count)
        let ids = Set(diagram.items.map(\.id))
        #expect(diagram.edges.allSatisfy { ids.contains($0.from) && ids.contains($0.to) })
        for (i, a) in diagram.items.enumerated() {
            for b in diagram.items.dropFirst(i + 1) {
                #expect(abs(a.x - b.x) >= MapDiagram.nodeWidth || abs(a.y - b.y) >= MapDiagram.nodeHeight,
                        "Overlapping \(a.id), \(b.id)")
            }
        }
    }

    @Test("Default projection respects five columns, ten rows, grouped context and four connections")
    func typical() {
        let diagram = WorkspaceMapProjection.diagram(snapshot: snapshot(), options: .init())
        assertPacked(diagram)
        #expect(diagram.items.map(\.x).max()! <= 16 + 4 * MapDiagram.column)
        #expect(diagram.items.map(\.y).max()! <= 12 + 9 * MapDiagram.row)
        #expect(diagram.edges.allSatisfy { edge in diagram.edges.filter { $0.from == edge.from }.count <= 4 })
        #expect(!diagram.items.contains { $0.node.id == "brief" })
        #expect(diagram.items.first { $0.node.id == "work" }?.previews?.map(\.label) == ["README.md"])
        let contexts = Set(diagram.items.filter { ["plan", "readme", "brief"].contains($0.node.id) }.map(\.id))
        #expect(!diagram.edges.contains { contexts.contains($0.from) })
    }

    @Test("Every parent can collapse; crowded branches drill into the bounded viewport")
    func expansion() throws {
        var options = WorkspaceMapOptions(); options.expandedView = true; options.includeOlderScope = true
        let snapshot = snapshot(fileCount: 80)
        let first = WorkspaceMapProjection.diagram(snapshot: snapshot, options: options)
        assertPacked(first)
        let parent = try #require(first.items.first { $0.isExpanded == true && $0.node.kind == .agent })
        options.collapsed.insert(parent.expansionID!)
        let collapsed = WorkspaceMapProjection.diagram(snapshot: snapshot, options: options)
        #expect(!collapsed.edges.contains { $0.from == parent.id })
        options.collapsed = []
        let folded = try #require(first.items.first { $0.focusOnExpand == true })
        options.focusedBranchID = folded.expansionID
        let expanded = WorkspaceMapProjection.diagram(snapshot: snapshot, options: options)
        #expect(expanded.items.contains { $0.node.id == folded.node.id && $0.isExpanded == true })
        #expect(expanded.items.map(\.x).max()! <= 16 + 4 * MapDiagram.column)
        assertPacked(expanded)
    }

    @Test("Agent isolates the selected actor and uses grouped outputs")
    func agent() throws {
        var options = WorkspaceMapOptions(); options.mode = .agent; options.agentID = "a"
        let diagram = WorkspaceMapProjection.diagram(snapshot: try snapshot().validated(), options: options)
        #expect(!diagram.items.contains { $0.node.id == "b" })
        #expect(diagram.items.contains { $0.node.id == "a" })
        #expect(diagram.items.contains { $0.node.id == "db" })
        assertPacked(diagram)
    }

    @Test("Context has expandable sources and no worktree execution boxes")
    func context() throws {
        var options = WorkspaceMapOptions(); options.mode = .context
        let folded = WorkspaceMapProjection.diagram(snapshot: snapshot(), options: options)
        #expect(!folded.items.contains { $0.node.kind == .agent || $0.node.kind == .workspace })
        #expect(folded.items.contains { $0.node.id == "research" })
        assertPacked(folded)
    }

    @Test("Idle agents backfill four important outputs instead of dropping their work")
    func expiry() {
        let now = Date(); var snapshot = snapshot(fileCount: 10)
        for i in snapshot.relations.indices { snapshot.relations[i].observedAt = now.addingTimeInterval(-3600) }
        var options = WorkspaceMapOptions(); options.mode = .agent; options.agentID = "a"
        let selected = MapAgentFocus.relations(agent: snapshot.nodes.first { $0.id == "a" }!, snapshot: snapshot, options: options, now: now)
        #expect(selected.filter { $0.kind == .output }.count == 4)
        #expect(selected.contains { $0.from == "readme" })
    }

    @Test("Large expansion stays bounded, deterministic, and routes clear of every card")
    func bounds() throws {
        var options = WorkspaceMapOptions(); options.expandedView = true; options.includeOlderScope = true
        let snapshot = snapshot(fileCount: 300)
        let first = WorkspaceMapProjection.diagram(snapshot: snapshot, options: options, limit: 40)
        #expect(first.items.count <= 40)
        assertPacked(first)
        for edge in first.edges {
            let points = try #require(edge.points)
            for (a, b) in zip(points, points.dropFirst()) {
                #expect(!first.items.contains { MapEdgeRouter.intersects(a, b, item: $0) })
            }
        }
        let second = WorkspaceMapProjection.diagram(snapshot: snapshot, options: options, limit: 40)
        #expect(first.items.map(\.id) == second.items.map(\.id))
        #expect(first.items.map(\.y) == second.items.map(\.y))
        #expect(try JSONDecoder().decode(MapDiagram.self, from: JSONEncoder().encode(first)).items.count == first.items.count)
    }

    @Test("Markdown source indexing groups real links and ignores fenced examples and image syntax")
    func sections() {
        let sections = MapDocumentSources.sections(markdown: """
        # Research
        [Paper](https://example.com/paper)
        [Paper again](https://example.com/paper)
        ![Image](https://example.com/image.png)
        ```md
        [Fake](https://example.com/fake)
        ```
        ## GitHub
        [Issue](https://example.com/issue)
        """)
        #expect(sections.map(\.title) == ["Research", "GitHub"])
        #expect(sections[0].links.count == 1)
        #expect(sections[1].links[0].1 == "https://example.com/issue")
    }
}

@Suite("Map resource contracts")
struct MapResourceTests {
    @Test("Durable declarations validate identity and endpoints and preserve feedback cycles")
    func resources() throws {
        let source = #"{"version":1,"taskID":"TEST","resources":[{"id":"postgres","label":"Test database","workspace":"/repo","document":"file:///repo/README.md","summary":"Configured test DB"}],"connections":[{"from":"resource:postgres","to":"agent:writer","kind":"dependency"},{"from":"file:/repo/Sources/0.swift","to":"resource:postgres","kind":"feedback"}]}"#
        let manifest = try MapResources.decode(Data(source.utf8), taskID: "TEST")
        let snapshot = try manifest.applying(to: MapTemplateTests().snapshot())
        #expect(snapshot.nodes.contains { $0.label == "Test database" && $0.durable == true })
        #expect(snapshot.relations.contains { $0.kind == .feedback })
        #expect(throws: (any Error).self) { try MapResources.decode(Data(source.utf8), taskID: "OTHER") }
        let invalid = source.replacingOccurrences(of: "agent:writer", with: "agent:missing")
        #expect(throws: (any Error).self) { try MapResources.decode(Data(invalid.utf8), taskID: "TEST").applying(to: MapTemplateTests().snapshot()) }
        let data = try snapshot.encoded()
        #expect(try MapSnapshot.decode(data).schemaVersion == 2)
    }

    @Test("Older v1 snapshots remain readable")
    func legacy() throws {
        var snapshot = MapTemplateTests().snapshot(); snapshot.schemaVersion = 1
        snapshot.nodes.removeAll { [.context, .section, .link, .resource].contains($0.kind) }
        for i in snapshot.nodes.indices where snapshot.nodes[i].parentID == "context" { snapshot.nodes[i].parentID = "queue" }
        let ids = Set(snapshot.nodes.map(\.id)); snapshot.relations.removeAll { !ids.contains($0.from) || !ids.contains($0.to) }
        #expect(try MapSnapshot.decode(snapshot.encoded()).schemaVersion == 1)
    }
}

@Suite("Map source snapshots")
struct MapSourceSnapshotTests {
    @Test("Research outputs expose headings, preserve heading identity after insertions, and keep links collapsed")
    func outputSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("research.md")
        let original = "## Findings\n[Source](https://example.com/source)\n"
        try Data(original.utf8).write(to: document)
        var snapshot = MapTemplateTests().snapshot()
        snapshot.nodes.append(.init(id: "report", parentID: "source", kind: .file, label: "research.md", path: document.path, evidence: "Scope"))
        snapshot.relations.append(.init(from: "a", to: "report", kind: .output, evidence: "Declared output", observedAt: nil))
        let indexer = MapDocumentSources()
        let first = indexer.enrich(snapshot)
        let heading = try #require(first.nodes.first { $0.label == "Findings" })
        try Data(("## Background\n[Background](https://example.com/background)\n" + original).utf8).write(to: document)
        let second = indexer.enrich(snapshot)
        #expect(second.nodes.first { $0.label == "Findings" }?.id == heading.id)
        var options = WorkspaceMapOptions(); options.mode = .agent; options.agentID = "a"
        let diagram = WorkspaceMapProjection.diagram(snapshot: second, options: options)
        #expect(second.nodes.contains { $0.id == heading.id })
        #expect(!diagram.items.contains { $0.node.destination == "https://example.com/source" })
    }

    @Test("Shared durable instances retain their canonical location")
    func sharedResource() throws {
        var snapshot = MapTemplateTests().snapshot()
        let offset = try #require(snapshot.nodes.firstIndex { $0.id == "db" })
        snapshot.nodes[offset].parentID = "queue"
        let diagram = WorkspaceMapProjection.diagram(snapshot: snapshot, options: .init())
        #expect(diagram.items.contains { $0.node.id == "db" && $0.node.parentID == "queue" })
        MapTemplateTests().assertPacked(diagram)
    }
}
