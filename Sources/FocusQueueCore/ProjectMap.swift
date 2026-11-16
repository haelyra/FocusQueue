import Foundation

/// The development plan (`devplan.md`) read as data: sections, and the leaves
/// under them. A leaf is one planned task with an exit gate and dependencies,
/// in the development-plan guideline's format:
///
///     - [ ] **1.2. Title.** Task: ABC-012
///       Scope: … Modules: M4.
///       Deps: 1.1; free text after a semicolon is ignored. Docs: M4.
///       Gate: the measurable exit criterion.
///
/// Parsing is purely textual (no model), so the project map is reproducible.
public struct DevelopmentPlanOutline: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var title: String
        /// Cross-cutting tracks, out-of-scope lists, and other non-gating
        /// sections: their gate-less items never become ghost tasks.
        public var isTrack: Bool
    }

    public struct Leaf: Equatable, Sendable {
        public var id: String
        public var title: String
        public var sectionIndex: Int
        /// `[x]` in the plan: the owner checked the leaf off.
        public var isChecked: Bool
        /// The `Gate:` text, or nil when the leaf states none.
        public var gate: String?
        /// The raw `Deps:` text up to the first semicolon.
        public var dependencyText: String
        /// The raw `Modules:` text.
        public var moduleText: String
        /// Task IDs named in the `Task:` field.
        public var taskField: String
    }

    public var sections: [Section]
    public var leaves: [Leaf]
    /// Table rows and "<TASK> covers <leaves>" sentences, as raw text to resolve
    /// against known task IDs.
    public var coverageText: [(leafText: String, taskText: String)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sections == rhs.sections && lhs.leaves == rhs.leaves
            && lhs.coverageText.map { $0.leafText + "\u{1}" + $0.taskText }
                == rhs.coverageText.map { $0.leafText + "\u{1}" + $0.taskText }
    }

    static let trackHeading = try! NSRegularExpression(
        pattern: #"cross-cutting|\btracks?\b|out of scope|non-gating|dependency (tree|spine)|triage|task set"#,
        options: [.caseInsensitive])
    static let leafHeader = try! NSRegularExpression(
        pattern: #"^\s{0,3}[-*]\s+(?:\[([ xX])\]\s+)?\*\*([A-Za-z0-9]+(?:\.[A-Za-z0-9]+)*)\.\s+(.+?)\*\*(.*)$"#)
    static let fieldLabels = ["Scope", "Modules", "Deps", "Docs", "Gate", "Task"]

    public static func parse(_ markdown: String) -> DevelopmentPlanOutline {
        var sections: [Section] = []
        var leaves: [Leaf] = []
        var coverage: [(String, String)] = []
        var current: (leaf: Leaf, body: [String])?

        func finish() {
            guard let (leaf, body) = current else { return }
            var finished = leaf
            let text = ([leaf.taskField] + body).joined(separator: " ")
            finished.gate = field("Gate", in: text)
            // Only the list before the first semicolon counts, and "none …" means none:
            // "none (can precede A1–A2)" names leaves without depending on them.
            let deps = field("Deps", in: text)
                .map { String($0.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") } ?? ""
            finished.dependencyText = deps.lowercased().hasPrefix("none") ? "" : deps
            finished.moduleText = field("Modules", in: text) ?? ""
            finished.taskField = field("Task", in: text) ?? ""
            leaves.append(finished)
            current = nil
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") || line == "##" {
                finish()
                let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let range = NSRange(title.startIndex..., in: title)
                sections.append(Section(title: title,
                                        isTrack: trackHeading.firstMatch(in: title, range: range) != nil))
                continue
            }
            if line.hasPrefix("#") { finish(); continue }
            let range = NSRange(rawLine.startIndex..., in: rawLine)
            if let match = leafHeader.firstMatch(in: rawLine, range: range),
               let idRange = Range(match.range(at: 2), in: rawLine),
               let titleRange = Range(match.range(at: 3), in: rawLine) {
                finish()
                if sections.isEmpty { sections.append(Section(title: "Plan", isTrack: false)) }
                let checked = Range(match.range(at: 1), in: rawLine).map { rawLine[$0].lowercased() == "x" } ?? false
                let rest = Range(match.range(at: 4), in: rawLine).map { String(rawLine[$0]) } ?? ""
                var title = String(rawLine[titleRange]).trimmingCharacters(in: .whitespaces)
                if title.hasSuffix(".") { title.removeLast() }
                current = (Leaf(id: String(rawLine[idRange]), title: title, sectionIndex: sections.count - 1,
                                isChecked: checked, gate: nil, dependencyText: "", moduleText: "",
                                taskField: rest), [])
                continue
            }
            if line.hasPrefix("|") {
                finish()
                let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if cells.count >= 2 { coverage.append((cells[0], cells.dropFirst().joined(separator: " "))) }
                continue
            }
            if current != nil {
                // Continuation lines are indented; a blank line or a new
                // top-level bullet ends the leaf.
                if line.isEmpty || (!rawLine.hasPrefix(" ") && !rawLine.hasPrefix("\t")) {
                    finish()
                } else {
                    current?.body.append(line)
                    continue
                }
            }
            coverage.append(contentsOf: coversSentences(in: line))
        }
        finish()
        return DevelopmentPlanOutline(sections: sections, leaves: leaves, coverageText: coverage)
    }

    /// The text after `Label:` up to the next known field label.
    static func field(_ label: String, in text: String) -> String? {
        guard let start = text.range(of: "\(label):") else { return nil }
        var value = String(text[start.upperBound...])
        for other in fieldLabels where other != label {
            if let next = value.range(of: " \(other):") { value = String(value[..<next.lowerBound]) }
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let coversPattern = try! NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9]*-\d+)\s+covers\s+"#)
    static let taskIDPattern = try! NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]*-\d+\b"#)

    /// "ABC-3 covers A4 plus …, ABC-4 covers A5" → [("A4 plus …", "ABC-3"), ("A5", "ABC-4")].
    static func coversSentences(in line: String) -> [(String, String)] {
        let range = NSRange(line.startIndex..., in: line)
        return coversPattern.matches(in: line, range: range).compactMap { match in
            guard let task = Range(match.range(at: 1), in: line),
                  let end = Range(match.range, in: line)?.upperBound else { return nil }
            var segment = String(line[end...])
            let segmentRange = NSRange(segment.startIndex..., in: segment)
            if let next = taskIDPattern.firstMatch(in: segment, range: segmentRange),
               let cut = Range(next.range, in: segment) {
                segment = String(segment[..<cut.lowerBound])
            }
            if let stop = segment.range(of: #"[.;](\s|$)"#, options: .regularExpression) {
                segment = String(segment[..<stop.lowerBound])
            }
            return (segment, String(line[task]))
        }
    }

    static let tokenPattern = try! NSRegularExpression(pattern: #"(?<![\w.§])[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)*"#)

    /// Identifier-like tokens (`A1`, `0.1`, `1.9a`, `P.2`), skipping `§` section refs.
    static func tokenMatches(in text: String) -> [(token: String, range: Range<String.Index>)] {
        tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { (String(text[$0]), $0) }
        }
    }

    static func tokens(in text: String) -> [String] { tokenMatches(in: text).map(\.token) }

    /// Leaf IDs named in `text`, expanding `X–Y`, `X-Y`, and `X to Y` ranges in plan order.
    func leafIDs(in text: String) -> [String] {
        let order = leaves.map(\.id)
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [String] = []
        var previous: (id: String, end: String.Index)?
        for (token, range) in Self.tokenMatches(in: text) {
            guard let index = position[token] else {
                if token != "to" { previous = nil }
                continue
            }
            if let last = previous, let from = position[last.id], from < index,
               ["\u{2013}", "\u{2014}", "-", "to"].contains(text[last.end..<range.lowerBound].trimmingCharacters(in: .whitespaces)) {
                result.append(contentsOf: order[(from + 1)...index])
            } else {
                result.append(token)
            }
            previous = (token, range.upperBound)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}

/// A project's task dependency map: every dashboard task, plus ghost nodes for
/// planned work no task covers yet. Built deterministically from files on disk.
public struct ProjectMap: Codable, Equatable, Sendable {
    public struct Agent: Codable, Equatable, Sendable {
        public var title: String
        public var provider: String
        public var status: String
        public var attention: String?
        public var summary: String
    }

    public struct Node: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case task, ghost }
        public var id: String
        public var kind: Kind
        public var title: String
        /// Dashboard status for tasks; `missing` for ghosts.
        public var status: String
        public var lane: Int
        /// Plan leaves this node stands for.
        public var leaves: [String]
        public var gate: String?
        public var phase: String?
        public var agents: [Agent]
        /// Why a ghost exists, in plain words.
        public var reason: String?
    }

    public struct Edge: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        /// `plan` (a Deps line) or `task` (a development.json dependency).
        public var source: String
    }

    public struct Lane: Codable, Equatable, Sendable {
        public var title: String
        public var isTrack: Bool
    }

    public var projectID: String
    public var projectName: String
    public var planFile: String?
    public var currentPhase: String
    public var generatedAt: Date
    public var lanes: [Lane]
    public var nodes: [Node]
    public var edges: [Edge]
}

public enum ProjectMapBuilder {
    /// Statuses that mean the task will never do the work; they do not cover a leaf.
    static let abandoned: Set<String> = ["cancelled", "canceled"]

    public static func build(projectID: String, projectName: String, process: DevelopmentProcess,
                             tickets: [DashboardTicket], outline: DevelopmentPlanOutline?, planFile: String?,
                             agents: [String: [ProjectMap.Agent]], moduleIDs: [String] = [],
                             now: Date = Date()) -> ProjectMap {
        let outline = outline ?? DevelopmentPlanOutline(sections: [], leaves: [], coverageText: [])
        let ticketIDs = Set(tickets.map { $0.id.uppercased() })
        func taskIDs(in text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            return DevelopmentPlanOutline.taskIDPattern.matches(in: text, range: range).compactMap {
                Range($0.range, in: text).map { text[$0].uppercased() }
            }.filter { ticketIDs.contains($0) }
        }

        // Leaf → tasks that claim it.
        var claims: [String: [String]] = [:]
        func claim(_ leaf: String, _ task: String) {
            if !(claims[leaf]?.contains(task) ?? false) { claims[leaf, default: []].append(task) }
        }
        for leaf in outline.leaves { for task in taskIDs(in: leaf.taskField) { claim(leaf.id, task) } }
        for (leafText, taskText) in outline.coverageText {
            let tasks = taskIDs(in: taskText)
            guard !tasks.isEmpty else { continue }
            for leaf in outline.leafIDs(in: leafText) { for task in tasks { claim(leaf, task) } }
        }
        for ticket in tickets {
            for leaf in outline.leafIDs(in: titleLabel(ticket.title)) { claim(leaf, ticket.id.uppercased()) }
        }

        var lanes = outline.sections.map { ProjectMap.Lane(title: $0.title, isTrack: $0.isTrack) }
        var nodes: [ProjectMap.Node] = []
        var nodeIndex: [String: Int] = [:]
        var leafNodes: [String: [String]] = [:]
        let leafOrder = Dictionary(outline.leaves.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(tickets.map { ($0.id.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })

        // Each task sits in the lane of the first leaf it claims, in plan order.
        var taskLeaves: [String: [String]] = [:]
        for (leaf, tasks) in claims { for task in tasks { taskLeaves[task, default: []].append(leaf) } }
        for task in taskLeaves.keys { taskLeaves[task]?.sort { (leafOrder[$0] ?? 0) < (leafOrder[$1] ?? 0) } }

        // A task that claims no leaf (an orchestrator, a design-doc or review
        // task) still belongs to a plan phase: the one its title names, else the
        // section of a leaf its title mentions, else the section matching its
        // development-process phase. Only a task with none of these signals is
        // left in a "Not linked to a phase" lane.
        var unlinkedLane: Int?
        let phaseSection = PlanPhaseSections(outline: outline) { leafID in
            // A leaf still has open work unless it is ticked or a finished task covers it.
            guard let leaf = outline.leaves.first(where: { $0.id == leafID }), !leaf.isChecked else { return false }
            let covering = claims[leafID] ?? []
            return covering.isEmpty || covering.contains { byID[$0].map { $0.isOpen } ?? false }
        }
        for ticket in tickets {
            let id = ticket.id.uppercased()
            let leaves = taskLeaves[id] ?? []
            var lane: Int
            var reason: String?
            if let first = leaves.first, let leaf = outline.leaves.first(where: { $0.id == first }) {
                lane = leaf.sectionIndex
            } else if let section = phaseSection.section(titled: ticket.title)
                        ?? outline.leafIDs(in: ticket.title).compactMap({ leafID in
                            outline.leaves.first { $0.id == leafID }?.sectionIndex }).first
                        ?? process.phase(ofTask: id).flatMap(phaseSection.section(for:)) {
                lane = section
                reason = "Supports this phase; it does not claim a plan leaf."
            } else {
                // A link without a step is the process's own "outside the
                // process" marker (side questions, chores); say so plainly.
                let outside = process.links[id] != nil
                let title = outside ? "Outside the development process" : "Not linked to a phase"
                if unlinkedLane == nil {
                    lanes.append(ProjectMap.Lane(title: title, isTrack: true))
                    unlinkedLane = lanes.count - 1
                } else if lanes[unlinkedLane!].title != title {
                    lanes[unlinkedLane!].title = "Outside the development process or unlinked"
                }
                lane = unlinkedLane!
                reason = outside
                    ? "Marked outside the development process (a side question or chore)."
                    : "No plan leaf, phase in its title, or process phase places it."
            }
            nodeIndex[id] = nodes.count
            nodes.append(ProjectMap.Node(
                id: id, kind: .task, title: ticket.title, status: ticket.status.lowercased(), lane: lane,
                leaves: leaves,
                gate: leaves.compactMap { leaf in outline.leaves.first { $0.id == leaf }?.gate }.first,
                phase: nil, agents: agents[id] ?? [], reason: reason))
            for leaf in leaves { leafNodes[leaf, default: []].append(id) }
        }

        // Ghosts: planned leaves with an unmet gate and no live covering task.
        for leaf in outline.leaves {
            let live = (leafNodes[leaf.id] ?? []).filter { !abandoned.contains(byID[$0]?.status.lowercased() ?? "") }
            guard live.isEmpty, !leaf.isChecked else { continue }
            let section = outline.sections.indices.contains(leaf.sectionIndex) ? outline.sections[leaf.sectionIndex] : nil
            guard leaf.gate != nil || section?.isTrack == false else { continue }
            let id = "ghost:\(leaf.id)"
            nodeIndex[id] = nodes.count
            nodes.append(ProjectMap.Node(
                id: id, kind: .ghost, title: "\(leaf.id). \(leaf.title)", status: "missing", lane: leaf.sectionIndex,
                leaves: [leaf.id], gate: leaf.gate, phase: nil, agents: [],
                reason: leafNodes[leaf.id] == nil
                    ? "Planned in \(planFile ?? "the development plan") with no task yet."
                    : "Its only tasks were cancelled."))
            leafNodes[leaf.id, default: []].append(id)
        }

        // Module ghosts: tracked modules or module files no task or leaf mentions.
        let mentionText = (tickets.map(\.title) + outline.leaves.map { $0.moduleText + " " + $0.title }).joined(separator: " ")
        let mentioned = Set(DevelopmentPlanOutline.tokens(in: mentionText).map { $0.uppercased() })
        var moduleLane: Int?
        func moduleGhost(id: String, title: String, reason: String) {
            if moduleLane == nil {
                lanes.append(ProjectMap.Lane(title: "Modules without planned work", isTrack: false))
                moduleLane = lanes.count - 1
            }
            nodeIndex[id] = nodes.count
            nodes.append(ProjectMap.Node(id: id, kind: .ghost, title: title, status: "missing", lane: moduleLane!,
                                         leaves: [], gate: nil, phase: nil, agents: [], reason: reason))
        }
        for module in process.modules where !module.qaAccepted {
            let linked = process.linkedTaskIDs(module: module.id).contains { byID[$0] != nil }
            let named = mentioned.contains(module.name.uppercased())
                || tickets.contains { $0.title.localizedCaseInsensitiveContains(module.name) }
            guard !linked, !named else { continue }
            moduleGhost(id: "ghost:module:\(module.id)", title: "Module: \(module.name)",
                        reason: "Tracked module with unaccepted criteria and no linked task.")
        }
        for moduleID in moduleIDs where !mentioned.contains(moduleID.uppercased()) {
            guard !process.modules.contains(where: { $0.name.uppercased().hasPrefix(moduleID.uppercased()) }) else { continue }
            moduleGhost(id: "ghost:module:\(moduleID.lowercased())", title: "Module \(moduleID.uppercased())",
                        reason: "Module design file exists, but no task or plan leaf names it.")
        }

        // Edges: plan Deps through leaf → node, then explicit task dependencies.
        var edges: [ProjectMap.Edge] = []
        var seen = Set<String>()
        func connect(_ from: String, _ to: String, _ source: String) {
            guard from != to, nodeIndex[from] != nil, nodeIndex[to] != nil,
                  seen.insert(from + "\u{1}" + to).inserted else { return }
            edges.append(ProjectMap.Edge(from: from, to: to, source: source))
        }
        for leaf in outline.leaves {
            let targets = leafNodes[leaf.id] ?? []
            let prerequisites = outline.leafIDs(in: leaf.dependencyText).flatMap { leafNodes[$0] ?? [] }
                + taskIDs(in: leaf.dependencyText)
            for target in targets { for prerequisite in prerequisites { connect(prerequisite, target, "plan") } }
        }
        for (task, prerequisites) in process.dependencies.sorted(by: { $0.key < $1.key }) {
            for prerequisite in prerequisites { connect(prerequisite.uppercased(), task.uppercased(), "task") }
        }

        // Plan order inside each lane; tasks outside the plan keep dashboard order.
        let ticketOrder = Dictionary(tickets.enumerated().map { ($1.id.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let ranked = nodes.enumerated().map { offset, node in
            (node, (node.lane, node.leaves.first.flatMap { leafOrder[$0] } ?? Int.max,
                    ticketOrder[node.id] ?? Int.max, offset))
        }
        nodes = ranked.sorted { $0.1 < $1.1 }.map(\.0)

        return ProjectMap(projectID: projectID, projectName: projectName, planFile: planFile,
                          currentPhase: process.currentPhase.title, generatedAt: now,
                          lanes: lanes, nodes: nodes, edges: edges)
    }

    /// The part of a title that names its leaf: before the first colon, or the
    /// first word. "Phase 1 1.2: SQLite worker" → "Phase 1 1.2"; a title that
    /// merely mentions a leaf ("Decide starting 1.2 alongside 1.1") claims nothing.
    static func titleLabel(_ title: String) -> String {
        if let colon = title.firstIndex(of: ":"), title.distance(from: title.startIndex, to: colon) <= 40 {
            return String(title[..<colon])
        }
        return title.split(separator: " ").first.map(String.init) ?? ""
    }
}

/// Maps phase names onto the development plan's own sections. The plan
/// (`## Phase 1 — …`) and the development process (Planning, Phase 0,
/// Phase 1+, Phase N−1, Phase N) name phases differently; the map shows only
/// the plan's sections, so process phases are translated here.
struct PlanPhaseSections {
    let outline: DevelopmentPlanOutline
    /// Whether a leaf still has open work.
    let isOpen: (String) -> Bool

    /// `Phase 1` in "Phase 1 D1: …" → the `## Phase 1 — …` section.
    func section(titled title: String) -> Int? {
        guard let match = title.range(of: #"\bPhase\s+([0-9]+|[A-Z])\b"#, options: .regularExpression) else { return nil }
        let token = title[match].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        return section(named: token)
    }

    func section(named token: String) -> Int? {
        outline.sections.indices.first { index in
            let section = outline.sections[index]
            guard !section.isTrack, let match = section.title.range(of: #"^Phase\s+([0-9]+|[A-Z])\b"#,
                                                                   options: .regularExpression) else { return false }
            return section.title[match].split(whereSeparator: \.isWhitespace).last.map(String.init) == token
        }
    }

    /// Numbered build sections (`Phase 1`, `Phase 2`, …) in number order.
    var numbered: [(number: Int, index: Int)] {
        outline.sections.indices.compactMap { index -> (Int, Int)? in
            let title = outline.sections[index].title
            guard !outline.sections[index].isTrack,
                  let match = title.range(of: #"^Phase\s+[0-9]+\b"#, options: .regularExpression),
                  let number = Int(title[match].split(whereSeparator: \.isWhitespace).last ?? "") else { return nil }
            return (number, index)
        }.sorted { $0.0 < $1.0 }
    }

    func section(for phase: DevelopmentPhase) -> Int? {
        let build = numbered.filter { $0.number >= 1 }
        switch phase {
        case .planning:
            return outline.sections.indices.first {
                !outline.sections[$0].isTrack && outline.sections[$0].title.localizedCaseInsensitiveContains("planning")
            } ?? section(named: "0")
        case .phase0:
            return section(named: "0")
        case .implementation:
            // "Phase 1+" is every build phase: use the earliest one with open work.
            let open = build.first { entry in
                outline.leaves.contains { $0.sectionIndex == entry.index && isOpen($0.id) }
            }
            return (open ?? build.first)?.index
        case .prerelease:
            return build.count >= 2 ? build[build.count - 2].index : build.last?.index
        case .release:
            return build.last?.index
        }
    }
}

/// Reads a project's files and writes `project-map.html` beside its plan.
/// Only projects with the development process enabled get a map.
public struct ProjectMapGenerator: Sendable {
    public static let fileName = "project-map.html"
    public let root: URL
    public init(root: URL) { self.root = root }

    public func mapURL(projectID: String) throws -> URL {
        try DevelopmentProcessStore(root: root).url(projectID: projectID)
            .deletingLastPathComponent().appendingPathComponent(Self.fileName)
    }

    /// The map model, or nil when the project has no enabled process.
    public func build(projectID: String, now: Date = Date()) throws -> ProjectMap? {
        let store = DevelopmentProcessStore(root: root)
        guard let process = try store.load(projectID: projectID), process.enabled else { return nil }
        let directory = try store.url(projectID: projectID).deletingLastPathComponent()
        let project = projectRecord(projectID)
        let dashboardURL = project.dashboardPath.map { URL(fileURLWithPath: $0) }
            ?? directory.appendingPathComponent("dashboard.json")
        let tickets = (try? JSONDecoder().decode(DashboardDocument.self, from: Data(contentsOf: dashboardURL)))?.tickets ?? []
        let planURL = try store.artifactURL(projectID: projectID, artifact: "devplan.md", process: process)
        let outline = (try? String(contentsOf: planURL, encoding: .utf8)).map(DevelopmentPlanOutline.parse)
        let moduleIDs = DevelopmentModuleFiles.discover(projectDirectory: directory, repositoryPath: project.repositoryPath)
            .compactMap(\.moduleID)
        var agents: [String: [ProjectMap.Agent]] = [:]
        for ticket in tickets { agents[ticket.id.uppercased()] = taskAgents(ticket.id) }
        return ProjectMapBuilder.build(projectID: projectID, projectName: project.name ?? projectID,
                                       process: process, tickets: tickets, outline: outline,
                                       planFile: outline == nil ? nil : planURL.lastPathComponent,
                                       agents: agents, moduleIDs: moduleIDs, now: now)
    }

    /// Regenerates the map file. Returns its URL, or nil when the project has no
    /// enabled process (any earlier map is left untouched).
    @discardableResult
    public func write(projectID: String, now: Date = Date()) throws -> URL? {
        guard let map = try build(projectID: projectID, now: now) else { return nil }
        return try write(map, projectID: projectID)
    }

    @discardableResult
    public func write(_ map: ProjectMap, projectID: String) throws -> URL {
        let url = try mapURL(projectID: projectID)
        try Data(ProjectMapHTML.render(map).utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Called after every dashboard write. A dashboard inside
    /// `<root>/projects/<id>/` beside an enabled `development.json` gets its map
    /// rebuilt; anything else is ignored. Never throws: the map is a view.
    public static func refreshAfterDashboardWrite(_ dashboardURL: URL) {
        let directory = dashboardURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().lastPathComponent == "projects",
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(DevelopmentProcessStore.fileName).path)
        else { return }
        let root = directory.deletingLastPathComponent().deletingLastPathComponent()
        _ = try? ProjectMapGenerator(root: root).write(projectID: directory.lastPathComponent)
    }

    private func projectRecord(_ projectID: String) -> (name: String?, dashboardPath: String?, repositoryPath: String?) {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["focusQueueProjects"] as? [[String: Any]],
              let project = projects.first(where: { ($0["id"] as? String) == projectID })
        else { return (nil, nil, nil) }
        return (project["name"] as? String, project["dashboardPath"] as? String, project["repositoryPath"] as? String)
    }

    private func taskAgents(_ taskID: String) -> [ProjectMap.Agent] {
        let url = root.appendingPathComponent("tasks").appendingPathComponent(taskID.uppercased())
            .appendingPathComponent("context.json")
        guard let data = try? Data(contentsOf: url),
              let context = try? JSONDecoder().decode(TaskContext.self, from: data) else { return [] }
        return context.subtasks
            .filter { $0.agentRemovedAt == nil && $0.mergedIntoSubtaskID == nil && !$0.isAssignmentOnly }
            .map { subtask in
                ProjectMap.Agent(title: subtask.title, provider: subtask.provider.rawValue,
                                 status: subtask.status.rawValue, attention: subtask.attention?.label,
                                 summary: String(subtask.progressSummary.prefix(240)))
            }
    }
}
