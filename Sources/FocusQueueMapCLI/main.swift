import Foundation
import FocusQueueCore
import FocusQueueMap

@main
struct WorkspaceMapCommand {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--help"] {
                print("Usage: focus-queue-map snapshot <TASK-ID> [--output <file>]\nReads registered task context and Git. Set FOCUS_QUEUE_SUPPORT_DIR to use another context store.")
                return
            }
            guard (args.count == 2 || (args.count == 4 && args[2] == "--output")), args[0] == "snapshot" else {
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
