import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Neutral plan documents and task lists")
struct MarkdownTaskListTests {
    @Test("Document harnesses use distinct runtime locks while the central chat keeps its runtime")
    func independentRuntimes() {
        var configuration = SetupEnvironment.starter(supportDirectory: URL(fileURLWithPath: "/tmp/support")).verifier
        configuration.contextDirectory = "/tmp/context"
        configuration.sessionName = "ecc-focus-queue-task-ecc-901"
        #expect(CodexQueueAgent.documentRuntimeArguments(configuration).isEmpty)
        configuration.sessionName += "-document-0123456789abcdef"
        #expect(CodexQueueAgent.documentRuntimeArguments(configuration) == ["--runtime", "/tmp/context/document-agents/0123456789abcdef"])
        configuration.sessionName = "ecc-focus-queue-task-ecc-901-document-aaaaaaaaaaaaaaaa"
        #expect(CodexQueueAgent.documentRuntimeArguments(configuration).last == "/tmp/context/document-agents/aaaaaaaaaaaaaaaa")
    }
    @Test("Checked and nested task lists render as controls while code examples remain literal")
    func checkboxes() {
        let html = MarkdownHTMLRenderer.page(markdown: """
        # Tasks

        - [x] Complete
        - [ ] Pending
          - [X] Nested
        - `[x]` Inline example

        ```text
        - [x] Fenced example
        ```
        """, sourceURL: URL(fileURLWithPath: "/tmp/plan.md"))
        #expect(html.components(separatedBy: "type=\"checkbox\"").count - 1 == 3)
        #expect(html.components(separatedBy: "disabled checked").count - 1 == 2)
        #expect(html.contains("<code>[x]</code>"))
        #expect(html.contains("- [x] Fenced example"))
        #expect(!html.contains("radial-gradient"))
        #expect(!html.contains("linear-gradient"))
        #expect(html.contains("--page: light-dark(#f3f3f3, #242424)"))
    }
}
