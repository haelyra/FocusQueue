import Foundation
import FocusQueueCore
import FocusQueueMap

@main
struct WorkspaceMapCommand {
    static let help = """
    Usage: focus-queue-map snapshot <TASK-ID> [--output <file>]
           focus-queue-map diagram <TASK-ID> [--view typical|context|agent] [--agent <subtask-id>] [--expanded] [--output <file>]
           focus-queue-map scope <TASK-ID> <SUBTASK-ID> [--input <path>] [--output <path>]
           focus-queue-map scope <TASK-ID> <SUBTASK-ID> --clear
           focus-queue-map resources <TASK-ID> --import <manifest.json>
    Scope replaces the agent's previous declaration. Resource imports replace the task manifest.
    Set FOCUS_QUEUE_SUPPORT_DIR to use another context store. Collection never acknowledges registrations.
    """
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--help"] { print(help); return }
            guard args.count >= 2, ["snapshot", "diagram", "scope", "resources"].contains(args[0]) else { throw MapError.unavailable(help) }
            let environment = ProcessInfo.processInfo.environment
            let root = environment["FOCUS_QUEUE_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ECC Focus Queue")
            let store = TaskContextStore(root: root)
            guard let context = try await store.load(ticketID: args[1]) else { throw MapError.unavailable("No saved context exists for \(args[1]).") }
            if args[0] == "scope" {
                guard args.count >= 4, let subtask = context.subtasks.first(where: { $0.id == args[2] }) else { throw MapError.unavailable("Expected a registered subtask and scope paths or --clear.") }
                var inputs: [String] = [], outputs: [String] = [], i = 3
                if args.count == 4 && args[3] == "--clear" { i = 4 }
                while i < args.count {
                    guard i + 1 < args.count, ["--input", "--output"].contains(args[i]) else { throw MapError.unavailable("Expected --input <path> or --output <path>.") }
                    if args[i] == "--input" { inputs.append(args[i + 1]) } else { outputs.append(args[i + 1]) }
                    i += 2
                }
                try MapScope(context: context, subtask: subtask, inputs: inputs, outputs: outputs).save(context: context)
                print("Saved input/output scope for \(subtask.title)."); return
            }
            var state = try await JSONLocalStateStore(url: root.appendingPathComponent("state.json")).load()
            for session in try await AgentRegistrationInbox(directory: root.appendingPathComponent("agent-registrations")).pending() { state.upsertAgentSession(session) }
            if args[0] == "resources" {
                guard args.count == 4, args[2] == "--import" else { throw MapError.unavailable(help) }
                let source = URL(fileURLWithPath: args[3])
                guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256_000 else { throw MapError.invalidSnapshot("Resource manifest exceeds 256 KB.") }
                let data = try Data(contentsOf: source)
                let manifest = try MapResources.decode(data, taskID: context.ticketID)
                let snapshot = try await WorkspaceCollector().collect(context: context, sessions: state.agentSessions)
                // Validate against canonical collected endpoints before replacement.
                var baseline = snapshot
                let old = Set(baseline.nodes.filter { $0.kind == .resource }.map(\.id))
                baseline.nodes.removeAll { old.contains($0.id) }
                baseline.relations.removeAll { old.contains($0.from) || old.contains($0.to) || $0.evidence == "Explicit resource manifest" }
                _ = try manifest.applying(to: baseline)
                try SystemFileAccessor().write(data, to: MapResources.location(context))
                print("Saved \(manifest.resources.count) durable instance declarations."); return
            }
            var options = WorkspaceMapOptions(), output: String?, subtaskID: String?, i = 2
            while i < args.count {
                if args[0] == "diagram", args[i] == "--expanded" { options.expandedView = true; i += 1; continue }
                guard i + 1 < args.count else { throw MapError.unavailable(help) }
                switch args[i] {
                case "--output": output = args[i + 1]
                case "--view" where args[0] == "diagram":
                    guard let mode = WorkspaceMapMode(rawValue: args[i + 1]) else { throw MapError.unavailable("Unknown map view.") }
                    options.mode = mode
                case "--agent" where args[0] == "diagram": subtaskID = args[i + 1]
                default: throw MapError.unavailable(help)
                }
                i += 2
            }
            let snapshot = try await WorkspaceCollector().collect(context: context, sessions: state.agentSessions)
            let data: Data
            if args[0] == "diagram" {
                if options.mode == .agent {
                    guard let id = snapshot.nodes.first(where: { $0.kind == .agent && ($0.subtaskID == subtaskID || $0.id == subtaskID) })?.id else { throw MapError.unavailable("Agent view requires --agent <registered subtask ID or map node ID>.") }
                    options.agentID = id
                }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try encoder.encode(WorkspaceMapProjection.diagram(snapshot: snapshot, options: options))
            } else { data = try snapshot.encoded() }
            if let output { try SystemFileAccessor().write(data, to: URL(fileURLWithPath: output)) }
            else { FileHandle.standardOutput.write(data); print("") }
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
