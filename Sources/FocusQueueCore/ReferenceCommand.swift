import Foundation

/// `focus-queue-session ref`: build the card for a shorthand code and print
/// the link an agent pastes into its report.
public enum ReferenceCommand {
    public static let usage = """
        Usage: focus-queue-session ref [<TASK-ID>] <CODE> [<CODE> ...] [--doc <file.md> ...]
        Builds tasks/<TASK-ID>/evidence/refs/<CODE>.md: the diagram that shows the code, outlined, above its definition.
        It searches --doc files first, then the project's planning files, modules/, and the task plan.
        Paste the returned "markdown" link; Focus Queue opens it in split view.
        """

    public struct Output: Encodable, Equatable {
        public let code: String
        public let status: String
        public var card: String?
        public var link: String?
        public var markdown: String?
        public var definedIn: String?
        public var line: Int?
        public var title: String?
        public var diagram: String?
        public var highlighted: [String]?
        public var related: [String]?
        public var error: String?
    }

    public static func run(arguments: [String], root: URL, environment: [String: String]) async throws {
        var args = Array(arguments.dropFirst())
        var documents: [URL] = []
        while let index = args.firstIndex(of: "--doc") {
            guard index + 1 < args.count else { throw ReferenceUsageError() }
            let path = (args[index + 1] as NSString).expandingTildeInPath
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ReferenceError("No document at \(url.path).")
            }
            documents.append(url)
            args.removeSubrange(index...(index + 1))
        }
        let environmentTask = environment["FOCUS_QUEUE_TASK_ID"].flatMap { $0.isEmpty ? nil : $0 }
        let taskID: String
        // A task ID can look like a code (FOC-133), so the first argument is the task when its folder exists.
        let tasks = root.appendingPathComponent("tasks", isDirectory: true)
        if let first = args.first, args.count > 1 || environmentTask == nil,
           FileManager.default.fileExists(atPath: tasks.appendingPathComponent(first.uppercased()).path) {
            taskID = first.uppercased()
            args.removeFirst()
        } else if let environmentTask {
            taskID = environmentTask.uppercased()
        } else { throw ReferenceUsageError() }
        guard !args.isEmpty else { throw ReferenceUsageError() }
        if let bad = args.first(where: { !ReferenceCards.isValidCode($0) }) {
            throw ReferenceError("\(bad) is not a reference code. Use letters then digits, such as B3, FC12, or M4.1.")
        }
        guard try await TaskContextStore(root: root).load(ticketID: taskID) != nil else {
            throw ReferenceError("No task \(taskID) in \(root.path).")
        }
        let sources = ReferenceCards.sourceDocuments(root: root, taskID: taskID, explicit: documents)
        var outputs: [Output] = []
        for code in args {
            if let card = try ReferenceCards.write(root: root, taskID: taskID, code: code, documents: sources) {
                outputs.append(Output(
                    code: code, status: "written",
                    card: ReferenceCards.cardURL(root: root, taskID: taskID, code: code).path,
                    link: ReferenceCards.link(taskID: taskID, code: code).absoluteString,
                    markdown: ReferenceCards.markdownLink(taskID: taskID, code: code),
                    definedIn: card.definition.source.path, line: card.definition.line + 1,
                    title: card.definition.title, diagram: card.diagram?.sourceURL.path,
                    highlighted: card.diagram?.highlighted, related: card.related))
            } else {
                outputs.append(Output(code: code, status: "not-found",
                    error: "No heading, table row, or list item defines \(code) in: "
                        + sources.map(\.lastPathComponent).joined(separator: ", ")
                        + ". Pass the defining file with --doc, or write the code without a link."))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let value: Data = outputs.count == 1 ? try encoder.encode(outputs[0]) : try encoder.encode(outputs)
        FileHandle.standardOutput.write(value)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if outputs.allSatisfy({ $0.status != "written" }) { throw ReferenceError("No definition found.") }
    }
}

public struct ReferenceUsageError: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { ReferenceCommand.usage }
}

public struct ReferenceError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
