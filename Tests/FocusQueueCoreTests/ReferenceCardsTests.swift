import Foundation
import Testing
@testable import FocusQueueCore

private let masterPlan = """
# Example master plan

## 1. Scope

### 1.1 MVP contract

| # | MVP item | Modules / pipelines | Success criteria (gate) |
|---|---|---|---|
| B1 | Live data storage | M6, P4 | Placement accuracy ≥ 97%. |
| B3 | Agent resource library: Context, Evidence, Links | M7, P4 | Export bundle validates clean; credentials never exported. |

## 2. Modules

#### M6 — Context storage

Stores scoped facts.

#### M7 — Agent resource library

Content-addressed artifacts.

- **MVP item:** B3.

## 3. Pipelines

### P2 — Terminal stream

```mermaid
flowchart LR
  PTY[kairos-pty] --> Transcript[Optional transcript artifact M7]
```

### P4 — Live proactive data pipeline (B1)

```mermaid
flowchart TB
  Src[Capture sources] --> Write[Atomic locked write M6]
  Write --> Launch[Injected into next launch]
```

### M4.1 — Sub-module

- M41: not M4.
- **D2:** Keep one writer. Rejected: two writers.
"""

private func referenceFixture(_ files: [String: String] = ["technical-design-master-plan.md": masterPlan]) throws -> (root: URL, project: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("refs-\(UUID().uuidString)")
    let project = root.appendingPathComponent("projects/example")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    for (name, text) in files { try text.write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    let task = root.appendingPathComponent("tasks/EX-001")
    try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)
    let context: [String: Any] = ["ticketID": "EX-001", "planPath": task.appendingPathComponent("plan.md").path,
                                  "projectPlanPath": project.appendingPathComponent("plan.md").path]
    try JSONSerialization.data(withJSONObject: context).write(to: task.appendingPathComponent("context.json"))
    return (root, project)
}

private func card(_ code: String, files: [String: String] = ["technical-design-master-plan.md": masterPlan]) throws -> ReferenceCard? {
    let (root, _) = try referenceFixture(files)
    defer { try? FileManager.default.removeItem(at: root) }
    let documents = ReferenceCards.sourceDocuments(root: root, taskID: "EX-001")
    return ReferenceCards.build(code: code, taskID: "EX-001", sources: documents.compactMap(ReferenceSource.load), now: Date())
}

@Test("Reference links round-trip and reject anything that is not a task and code")
func referenceLinks() {
    let link = ReferenceCards.link(taskID: "foc-133", code: "B3")
    #expect(link.absoluteString == "focusqueue://ref/FOC-133/B3")
    #expect(ReferenceCards.parse(link)! == ("FOC-133", "B3"))
    #expect(ReferenceCards.markdownLink(taskID: "FOC-133", code: "M4.1") == "[M4.1](focusqueue://ref/FOC-133/M4.1)")
    #expect(ReferenceCards.parse(URL(string: "focusqueue://ref/FOC-133")!) == nil)
    #expect(ReferenceCards.parse(URL(string: "focusqueue://ref/FOC-133/../x")!) == nil)
    #expect(ReferenceCards.parse(URL(string: "https://ref/FOC-133/B3")!) == nil)
    #expect(!ReferenceCards.isValidCode("Overview"), "A word without digits is not a code")
}

@Test("A table row defines a code; its card shows a related pipeline's own diagram")
func referenceTableRow() throws {
    let card = try #require(try card("B3"))
    #expect(card.definition.title == "Agent resource library: Context, Evidence, Links")
    #expect(card.definition.section == "1.1 MVP contract")
    #expect(card.related == ["M7", "P4"])
    #expect(card.markdown.contains("- **Success criteria (gate):** Export bundle validates clean"))
    // P4's own section diagram beats P2's passing mention of M7.
    let diagram = try #require(card.diagram)
    #expect(diagram.mermaid.contains("Atomic locked write M6"))
    #expect(card.markdown.contains("No diagram names B3. This one is from related P4"))
    #expect(card.markdown.contains("[M7](focusqueue://ref/EX-001/M7)"))
}

@Test("A heading defines a code; a diagram naming it outlines the labelled node, never an invented one")
func referenceHeadingAndHighlight() throws {
    let card = try #require(try card("M7"))
    #expect(card.definition.title == "Agent resource library")
    #expect(card.definition.excerpt.contains("Content-addressed artifacts."))
    let diagram = try #require(card.diagram)
    #expect(diagram.highlighted == ["Transcript"])
    #expect(diagram.mermaid.hasSuffix("  style Transcript stroke:#f76707,stroke-width:4px"))
    #expect(!diagram.mermaid.contains("style M7"), "M7 only appears inside a label")
}

@Test("A list item defines a code, and code boundaries keep M4 apart from M4.1 and M41")
func referenceListItemAndBoundaries() throws {
    let decision = try #require(try card("D2"))
    #expect(decision.definition.excerpt == "- **D2:** Keep one writer. Rejected: two writers.")
    #expect(decision.definition.title == "Keep one writer")
    let sub = try #require(try card("M4.1"))
    #expect(sub.definition.title == "Sub-module")
    #expect(try card("M4") == nil, "M4.1 and M41 do not define M4")
    #expect(ReferenceCards.containsCode("M4", "uses M4, then") && !ReferenceCards.containsCode("M4", "M4.1 and M41"))
}

@Test("Fenced code never defines a code, and a heading that only mentions it is the last resort")
func referenceDefinitionPriority() throws {
    let text = """
    ## P9 — Cleanup (B7)

    ```text
    B7: not a definition
    ```

    | ID | Item |
    |---|---|
    | B7 | Isolated sessions |
    """
    let card = try #require(try card("B7", files: ["prd.md": text]))
    #expect(card.definition.title == "Isolated sessions")
}

@Test("Cards are written to evidence/refs, built on first use, and not rewritten when unchanged")
func referenceWriteAndEnsure() throws {
    let (root, project) = try referenceFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try #require(ReferenceCards.ensureCard(root: root, taskID: "EX-001", code: "B3"))
    #expect(url.path.hasSuffix("tasks/EX-001/evidence/refs/B3.md"))
    #expect(ReferenceCards.definitionSource(ofCard: url)?.lastPathComponent == "technical-design-master-plan.md")
    let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    let documents = ReferenceCards.sourceDocuments(root: root, taskID: "EX-001")
    #expect(documents.first == project.appendingPathComponent("technical-design-master-plan.md").standardizedFileURL)
    _ = try ReferenceCards.write(root: root, taskID: "EX-001", code: "B3", documents: documents,
                                 now: Date().addingTimeInterval(86_400 * 3))
    let second = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    #expect(first == second, "Only the date stamp differs, so the card is not announced again")
    #expect(ReferenceCards.ensureCard(root: root, taskID: "EX-001", code: "ZZ9") == nil)
}

@Test("A card renders as a page: the header comment stays hidden and the diagram is a Mermaid figure")
func referenceCardRenders() throws {
    let card = try #require(try card("B3"))
    let html = MarkdownHTMLRenderer.page(markdown: card.markdown, sourceURL: URL(fileURLWithPath: "/tmp/B3.md"))
    #expect(!html.contains("&lt;!-- focus-queue-ref"))
    #expect(html.contains("mermaid"))
    #expect(html.contains("href=\"focusqueue://ref/EX-001/M7\""))
}
