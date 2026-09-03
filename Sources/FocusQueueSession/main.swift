import Darwin
import FocusQueueCore
import Foundation

enum SessionRegistrationError: Error, LocalizedError {
    case usage
    case missingSessionIdentity
    case missingPaneIdentity

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: focus-queue-session attach <TASK-ID>"
        case .missingSessionIdentity:
            "No Codex or Claude session ID was found in the environment or current WezTerm pane."
        case .missingPaneIdentity:
            "WEZTERM_PANE is unavailable. Run this command from the agent's WezTerm pane."
        }
    }
}

@main enum FocusQueueSessionCLI {
    static func main() async {
        do {
            try await register()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func register() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "attach", !arguments[1].isEmpty else {
            throw SessionRegistrationError.usage
        }

        let ticketID = arguments[1].uppercased()
        let environment = ProcessInfo.processInfo.environment
        guard let paneID = environment["WEZTERM_PANE"].flatMap(Int.init) else {
            throw SessionRegistrationError.missingPaneIdentity
        }

        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ECC Focus Queue", isDirectory: true)
        let configuration = try loadConfiguration(from: supportDirectory)
        let controller = WezTermController()

        let providerAndSession: (AgentProvider, String)
        if let sessionID = environment["CODEX_SESSION_ID"] ?? environment["CODEX_THREAD_ID"] {
            providerAndSession = (.codex, sessionID)
        } else if let sessionID = environment["CLAUDE_SESSION_ID"] {
            providerAndSession = (.claude, sessionID)
        } else {
            let agents = try await controller.listRunningAgents(configuration: configuration.wezTerm)
            guard let agent = agents.first(where: { $0.pane.paneID == paneID }) else {
                throw SessionRegistrationError.missingSessionIdentity
            }
            providerAndSession = (agent.provider, agent.sessionID)
        }

        try await controller.attach(
            paneID: paneID,
            taskID: ticketID,
            configuration: configuration.wezTerm
        )
        let session = TaskAgentSession(
            ticketID: ticketID,
            provider: providerAndSession.0,
            sessionID: providerAndSession.1,
            tabTitle: ticketID,
            workingDirectory: environment["PWD"] ?? FileManager.default.currentDirectoryPath,
            paneID: paneID
        )
        let inbox = AgentRegistrationInbox(
            directory: supportDirectory.appendingPathComponent("agent-registrations", isDirectory: true)
        )
        try await inbox.submit(session)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(AgentRegistrationInbox.notificationName),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        let result = [
            "provider": providerAndSession.0.rawValue,
            "sessionID": providerAndSession.1,
            "taskID": ticketID,
            "paneID": String(paneID),
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func loadConfiguration(from supportDirectory: URL) throws -> AppConfiguration {
        let url = supportDirectory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .eccDefault() }
        return try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url)).validated()
    }
}
