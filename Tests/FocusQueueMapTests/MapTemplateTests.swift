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

    @Test("Typical shares fixed task context outside real worktree containers and hides global inputs")
    func typical() {
        let diagram = WorkspaceMapProjection.diagram(snapshot: snapshot(), options: .init())
        #expect(diagram.items.contains { $0.node.id == "source" && $0.hiddenChildren == 3 })
        #expect(!diagram.items.contains { $0.node.id == "file0" || $0.node.id == "brief" })
        #expect(diagram.items.filter { $0.node.kind == .agent }.count == 2)
        #expect(diagram.items.contains { $0.node.id == "db" && $0.node.durable == true })
        let context = diagram.containers.first { $0.id == "context" }!
        let work = diagram.containers.first { $0.id == "work" }!
        #expect(context.x + context.width < work.x)
        #expect(diagram.items.filter { $0.node.kind == .agent }.allSatisfy { $0.x >= work.x && $0.y >= work.y && $0.y + MapDiagram.nodeHeight <= work.y + work.height })
        assertPacked(diagram)
    }

    @Test("Expanded reveals up to five files; larger folders expand explicitly and shrink back")
    func expansion() {
        var options = WorkspaceMapOptions(); options.expandedView = true
        let five = WorkspaceMapProjection.diagram(snapshot: snapshot(fileCount: 5), options: options)
        #expect(five.items.filter { $0.node.path?.hasSuffix(".swift") == true }.count == 5)
        let folded = WorkspaceMapProjection.diagram(snapshot: snapshot(fileCount: 8), options: options)
        #expect(!folded.items.contains { $0.node.id == "file0" })
        #expect(folded.items.contains { $0.node.id == "source" && $0.hiddenChildren == 8 })
        options.expanded.insert("source")
        let unfolded = WorkspaceMapProjection.diagram(snapshot: snapshot(fileCount: 8), options: options)
        #expect(unfolded.items.filter { $0.node.path?.hasSuffix(".swift") == true }.count == 8)
        #expect(unfolded.height > folded.height)
        assertPacked(five); assertPacked(folded); assertPacked(unfolded)
    }

    @Test("Agent isolates its context, outputs and durable feedback cycle")
    func agent() throws {
        var options = WorkspaceMapOptions(); options.mode = .agent; options.agentID = "a"
        let snapshot = try snapshot().validated()
        let diagram = WorkspaceMapProjection.diagram(snapshot: snapshot, options: options)
        #expect(!diagram.items.contains { $0.node.id == "b" })
        #expect(diagram.items.contains { $0.node.id == "brief" })
        #expect(diagram.edges.contains { $0.kind == "feedback" })
        #expect(diagram.edges.contains { $0.kind == "dependency" })
        assertPacked(diagram)
    }

    @Test("Context is a source funnel without worktrees and headings expand clickable links")
    func context() {
        var options = WorkspaceMapOptions(); options.mode = .context
        let folded = WorkspaceMapProjection.diagram(snapshot: snapshot(), options: options)
        #expect(!folded.items.contains { $0.node.kind == .agent })
        #expect(!folded.containers.contains { $0.id == "work" })
        #expect(folded.items.contains { $0.node.id == "research" && $0.hiddenChildren == 1 })
        #expect(!folded.items.contains { $0.node.id == "link" })
        #expect(folded.edges.contains { $0.to == "evidence" })
        options.expanded.insert("research")
        let expanded = WorkspaceMapProjection.diagram(snapshot: snapshot(), options: options)
        #expect(expanded.items.contains { $0.node.id == "link" && $0.node.destination == "https://example.com/paper" })
        #expect(expanded.edges.contains { $0.from == "context:link" && $0.to == "context:research" })
        assertPacked(folded); assertPacked(expanded)
    }

    @Test("Expired activity scope disappears while durable context persists and old scope is recoverable")
    func expiry() {
        let now = Date(); var snapshot = snapshot()
        for i in snapshot.relations.indices where snapshot.relations[i].evidence.hasPrefix("Declared") {
            snapshot.relations[i].observedAt = now.addingTimeInterval(-3600)
        }
        var options = WorkspaceMapOptions(); options.mode = .agent; options.agentID = "a"
        let current = WorkspaceMapProjection.diagram(snapshot: snapshot, options: options, now: now)
        #expect(!current.items.contains { $0.node.id == "file0" })
        #expect(current.items.contains { $0.node.id == "readme" })
        #expect(current.items.contains { $0.node.id == "db" })
        options.includeOlderScope = true
        #expect(WorkspaceMapProjection.diagram(snapshot: snapshot, options: options, now: now).items.contains { $0.node.id == "file0" })
    }

    @Test("Large expansion is bounded and repeated projections remain deterministic")
    func bounds() throws {
        var options = WorkspaceMapOptions(); options.expanded.insert("source"); options.expandedView = true
        let snapshot = snapshot(fileCount: 300)
        let first = WorkspaceMapProjection.diagram(snapshot: snapshot, options: options, limit: 40)
        #expect(first.items.count <= 40)
        assertPacked(first)
        let second = WorkspaceMapProjection.diagram(snapshot: snapshot, options: options, limit: 40)
        #expect(first.items.map(\.id) == second.items.map(\.id))
        #expect(first.items.map(\.y) == second.items.map(\.y))
        let data = try JSONEncoder().encode(first)
        #expect(try JSONDecoder().decode(MapDiagram.self, from: data).items.count == first.items.count)
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
        #expect(diagram.items.contains { $0.node.id == heading.id })
        #expect(!diagram.items.contains { $0.node.destination == "https://example.com/source" })
    }

    @Test("A shared durable instance stays outside workspace containers")
    func sharedResource() {
        var snapshot = MapTemplateTests().snapshot()
        let offset = snapshot.nodes.firstIndex { $0.id == "db" }!
        snapshot.nodes[offset].parentID = "queue"
        let diagram = WorkspaceMapProjection.diagram(snapshot: snapshot, options: .init())
        let resource = diagram.items.first { $0.node.id == "db" }!
        #expect(resource.x < diagram.containers.first { $0.id == "work" }!.x)
        #expect(diagram.edges.contains { $0.from == resource.id && $0.to == "a" })
        MapTemplateTests().assertPacked(diagram)
    }
}
