import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Document editing")
struct DocumentEditingTests {
    private static let filler = String(repeating: "Unrelated planning prose about other things entirely.\n", count: 130)
    private static let table = """
        # Plan

        ## Decisions

        | Area | Options | Decision |
        | --- | --- | --- |
        | Desktop | Electron packaging matrix with signed installers | Pending |
        | Editing | CodeMirror language subset and draft recovery | Pending |

        """

    @Test("A reply parses from JSON, fenced JSON, or plain text")
    func parsing() {
        let json = #"{"reply":"Done","edits":[{"line":2,"find":"a","replace":"b"}],"needsFullDocument":false}"#
        #expect(DocumentEditReply.parse(json) == .init(reply: "Done", edits: [.init(line: 2, find: "a", replace: "b")], needsFullDocument: false))
        #expect(DocumentEditReply.parse("```json\n\(json)\n```").edits.count == 1)
        #expect(DocumentEditReply.parse(#"{"needsFullDocument":true}"#).needsFullDocument)
    }

    @Test("Text that is not the expected JSON stays an answer with no edits")
    func plainReplies() {
        #expect(DocumentEditReply.parse("Line 31 already says A.") == .init(reply: "Line 31 already says A.", edits: [], needsFullDocument: false))
        let braces = "Use {curly} braces here."
        #expect(DocumentEditReply.parse(braces) == .init(reply: braces, edits: [], needsFullDocument: false))
        let unrelated = #"The config is {"name":"x"}"#
        #expect(DocumentEditReply.parse(unrelated) == .init(reply: unrelated, edits: [], needsFullDocument: false))
    }

    @Test("A cell selection sends its row, the table header, and the section heading")
    func tableWindow() throws {
        let lines = DocumentEditing.lines(of: Self.table + Self.filler)
        let window = try #require(DocumentEditing.window(lines: lines, excerpt: "Editing CodeMirror language subset and draft recovery"))
        #expect(window.map { lines[$0] } == ["## Decisions", "| Area | Options | Decision |", "| --- | --- | --- |",
            "| Editing | CodeMirror language subset and draft recovery | Pending |"])
    }

    @Test("A paragraph selection sends its neighbors")
    func paragraphWindow() throws {
        let text = Self.filler + "\n## Risks\n\nThe daemon recovery contract needs measured evidence.\n\n" + Self.filler
        let lines = DocumentEditing.lines(of: text)
        let window = try #require(DocumentEditing.window(lines: lines, excerpt: "daemon recovery contract needs measured evidence"))
        #expect(window.map { lines[$0] }.contains("## Risks"))
        #expect(window.map { lines[$0] }.contains("The daemon recovery contract needs measured evidence."))
        #expect(window.count <= 6)
    }

    @Test("Short documents and selections spanning lines send the whole document")
    func wholeDocumentFallbacks() {
        #expect(DocumentEditing.window(lines: DocumentEditing.lines(of: Self.table), excerpt: "Desktop Electron") == nil)
        let lines = DocumentEditing.lines(of: Self.table + Self.filler)
        let wholeTable = "Area Options Decision Desktop Electron packaging matrix signed installers Pending Editing CodeMirror language subset draft recovery"
        #expect(DocumentEditing.window(lines: lines, excerpt: wholeTable) == nil)
        #expect(DocumentEditing.window(lines: lines, excerpt: "") == nil)
    }

    @Test("Numbered output keeps original line numbers and stops at its limit")
    func numbering() {
        let lines = ["a", "b", "c"]
        #expect(DocumentEditing.numbered(lines: lines, indexes: [0, 2]) == "1\ta\n3\tc")
        #expect(DocumentEditing.numbered(lines: lines, limit: 8) == "1\ta\n2\tb")
    }

    @Test("An edit changes only its own line, so repeated text elsewhere is safe")
    func lineScopedEdit() throws {
        let result = try DocumentEditing.apply([.init(line: 8, find: "Pending", replace: "B, B")], to: Self.table)
        #expect(result == Self.table.replacingOccurrences(of: "draft recovery | Pending", with: "draft recovery | B, B"))
    }

    @Test("Added lines never shift a later edit, and line endings survive")
    func addedLines() throws {
        let edits: [DocumentEdit] = [.init(line: 1, find: "one", replace: "one\nnew"), .init(line: 2, find: "two", replace: "2")]
        #expect(try DocumentEditing.apply(edits, to: "one\r\ntwo\r\n") == "one\nnew\r\n2\r\n")
    }

    @Test("A bad edit rejects the whole reply")
    func allOrNothing() {
        #expect(throws: DocumentEditError.lineOutOfRange(9)) {
            try DocumentEditing.apply([.init(line: 9, find: "x", replace: "y")], to: "x")
        }
        #expect(throws: DocumentEditError.textNotFoundOnce(line: 1, find: "a")) {
            try DocumentEditing.apply([.init(line: 1, find: "a", replace: "b")], to: "a a")
        }
        #expect(throws: DocumentEditError.textNotFoundOnce(line: 1, find: "")) {
            try DocumentEditing.apply([.init(line: 1, find: "", replace: "b")], to: "a")
        }
    }
}
