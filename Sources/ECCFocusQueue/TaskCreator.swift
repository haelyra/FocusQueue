import FocusQueueCore
import Foundation

/// Everything the + task creator collects. Blank optional fields are filled by
/// the placement model; `agent` is ignored when `startsAgent` is false.
struct TaskDraft: Equatable, Sendable {
  var description: String
  var title = ""
  var displayDescription = ""
  /// nil lets the placement model assign the priority.
  var priority: String?
  var doneWhen = ""
  var dueDate: Date?
  var projectID: String?
  var launchesAgent = true
  var agent: AgentLaunchPreset

  /// An agent starts only when it would start with this prompt. Otherwise the
  /// task is created and the prompt is saved for the first agent launched later.
  var startsAgent: Bool { launchesAgent && (agent.includePrompt ?? true) }
}

/// What the placement model said about a draft's description.
struct TaskPlacementSuggestion: Equatable, Sendable {
  var status: String
  var taskID: String?
  var title: String?
  var summary: String?
  var priority: String?
  var confidence: Double
  var model: String?
  var modelError: String?

  static func unavailable(_ reason: String) -> Self {
    Self(status: "unavailable", confidence: 0, modelError: reason)
  }

  /// A confident match to an open task, which the creator offers before
  /// creating a duplicate.
  var matchedTaskID: String? { status == "task" ? taskID : nil }
}

enum TaskDraftChoice: Equatable, Sendable {
  /// Ask the placement model whether an open task already covers this work.
  case checkForMatch
  /// The user saw the match and still wants a new task.
  case createNew
  /// The user chose the matched task; launch there instead of creating one.
  case join(String)
}

enum TaskDraftResult: Equatable, Sendable {
  case created(ticketID: String, launchedAgent: Bool)
  case joined(ticketID: String, launchedAgent: Bool)
  case matched(DashboardTicket, TaskPlacementSuggestion)
  case failed(String)
}

struct TaskPlacementQuery: Equatable, Sendable {
  var description: String
  var provider: AgentProvider
  var cwd: String
  /// The configured placement budget; the script gets a little longer to exit.
  var timeoutSeconds = AppConfiguration.defaultPlacementTimeoutSeconds
}

protocol TaskPlacementSuggesting: Sendable {
  func suggest(_ query: TaskPlacementQuery) async -> TaskPlacementSuggestion
}

/// Runs the placement classifier shipped in the app bundle, the same script
/// `fq` uses, so the creator and the launcher share one model contract.
struct ScriptTaskPlacementSuggester: TaskPlacementSuggesting {
  let supportDirectory: URL
  var runner: any ProcessRunning = FoundationProcessRunner()
  var script: URL? = ScriptTaskPlacementSuggester.bundledScript()
  var home = FileManager.default.homeDirectoryForCurrentUser

  static func bundledScript() -> URL? {
    Bundle.main.resourceURL?.appendingPathComponent("shell/focus_queue_placement.py")
  }

  func suggest(_ query: TaskPlacementQuery) async -> TaskPlacementSuggestion {
    let installed = supportDirectory.appendingPathComponent("shell/focus_queue_placement.py")
    guard let script = [script, installed].compactMap({ $0 })
      .first(where: { FileManager.default.isReadableFile(atPath: $0.path) })
    else { return .unavailable("The placement classifier is not installed.") }
    do {
      let result = try await runner.run(ProcessSpecification(
        executable: "/usr/bin/python3",
        arguments: [script.path, "classify", "--provider", query.provider.rawValue,
                    "--prompt", query.description, "--cwd", query.cwd, "--json"],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environment: Self.environment(supportDirectory: supportDirectory, home: home),
        timeoutSeconds: query.timeoutSeconds + 10))
      guard result.exitCode == 0, !result.timedOut else {
        return .unavailable(result.timedOut ? "The placement classifier timed out."
          : "The placement classifier failed: \(result.standardError.prefix(200))")
      }
      return Self.parse(result.standardOutput)
    } catch {
      return .unavailable("The placement classifier could not start: \(error.localizedDescription)")
    }
  }

  /// A GUI app inherits launchd's short PATH, so name each provider CLI the
  /// way setup discovery finds it.
  static func environment(supportDirectory: URL, home: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("FOCUS_QUEUE_") }
    environment["FOCUS_QUEUE_SUPPORT_DIR"] = supportDirectory.path
    environment["HOME"] = home.path
    environment["PATH"] = ["\(home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                           "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    for provider in AgentProvider.allCases {
      let executable = provider == .kimi
        ? [home.appendingPathComponent(".kimi-code/bin/kimi").path].first(where: FileManager.default.isExecutableFile)
          ?? SetupEnvironment.executable("kimi", home: home)
        : SetupEnvironment.executable(provider.rawValue, home: home)
      if let executable {
        environment["FOCUS_QUEUE_PLACEMENT_\(provider.rawValue.uppercased())_EXECUTABLE"] = executable
      }
    }
    return environment
  }

  static func parse(_ output: String) -> TaskPlacementSuggestion {
    guard let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
          let status = object["status"] as? String else {
      return .unavailable("The placement classifier returned unreadable output.")
    }
    return TaskPlacementSuggestion(
      status: status, taskID: object["taskID"] as? String, title: object["title"] as? String,
      summary: object["summary"] as? String, priority: object["priority"] as? String,
      confidence: (object["confidence"] as? Double) ?? 0, model: object["model"] as? String,
      modelError: object["modelError"] as? String)
  }
}
