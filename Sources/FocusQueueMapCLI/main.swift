import Foundation
import FocusQueueCore
import FocusQueueMap

@main
struct WorkspaceMapCommand {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--help"] {
                print("Usage: focus-queue-map snapshot <TASK-ID> [--output <file>]\n       focus-queue-map scope <TASK-ID> <SUBTASK-ID> [--input <path>] [--output <path>]\n       focus-queue-map scope <TASK-ID> <SUBTASK-ID> --clear\nScope paths replace the previous declaration for this agent. Set FOCUS_QUEUE_SUPPORT_DIR to use another context store.")
                return
            }
            let isScope = args.first == "scope"
            guard (isScope && args.count >= 4) || ((args.count == 2 || (args.count == 4 && args[2] == "--output")) && args[0] == "snapshot") else {
                throw MapError.unavailable("Usage: focus-queue-map snapshot <TASK-ID> [--output <file>]")
            }
            let environment = ProcessInfo.processInfo.environment
            let root = environment["FOCUS_QUEUE_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("ECC Focus Queue")
            let store = TaskContextStore(root: root)
            guard let context = try await store.load(ticketID: args[1]) else {
                throw MapError.unavailable("No saved context exists for \(args[1]).")
            }
            if isScope {
                guard let subtask = context.subtasks.first(where: { $0.id == args[2] }) else {
                    throw MapError.unavailable("No such subtask exists in this task.")
                }
                var inputs: [String] = [], outputs: [String] = [], i = 3
                if args.count == 4 && args[3] == "--clear" { i = 4 }
                while i < args.count {
                    guard i + 1 < args.count, ["--input", "--output"].contains(args[i]) else {
                        throw MapError.unavailable("Expected --input <path> or --output <path>.")
                    }
                    if args[i] == "--input" { inputs.append(args[i + 1]) } else { outputs.append(args[i + 1]) }
                    i += 2
                }
                try MapScope(context: context, subtask: subtask, inputs: inputs, outputs: outputs).save(context: context)
                print("Saved input/output scope for \(subtask.title).")
                return
            }
            var state = try await JSONLocalStateStore(url: root.appendingPathComponent("state.json")).load()
            let pending = try await AgentRegistrationInbox(directory: root.appendingPathComponent("agent-registrations")).pending()
            for session in pending { state.upsertAgentSession(session) }
            let snapshot = try await WorkspaceCollector().collect(context: context, sessions: state.agentSessions)
            let data = try snapshot.encoded()
            if args.count == 4 { try SystemFileAccessor().write(data, to: URL(fileURLWithPath: args[3])) }
            else { FileHandle.standardOutput.write(data); print("") }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
