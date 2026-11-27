import Foundation

/// A rough "what is this agent doing right now", read from the latest tool call
/// in its provider transcript: reading files, editing them, running commands,
/// testing, researching the web, delegating, or planning. Only the transcript's
/// tail is read, so checking a working agent costs a few kilobytes.
public struct AgentToolActivity: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case reading, editing, running, testing, researching, delegating, planning, working

        public var verb: String {
            switch self {
            case .reading: "reading"
            case .editing: "editing"
            case .running: "running"
            case .testing: "testing"
            case .researching: "researching"
            case .delegating: "delegating"
            case .planning: "planning"
            case .working: "working"
            }
        }
    }

    public var kind: Kind
    /// A file name, command, query, or tool name; short and display-ready.
    public var detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = String(detail.prefix(80))
    }

    public static let tailBytes = 96 * 1024

    /// The latest tool call in the last `tailBytes` of a transcript, or nil.
    public static func read(url: URL, provider: AgentProvider) -> AgentToolActivity? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return latest(in: data, provider: provider, skipFirstLine: start > 0)
    }

    /// Scans JSONL from the end for the newest tool call. The first line of a
    /// tail is usually cut mid-record, so it is skipped.
    public static func latest(in data: Data, provider: AgentProvider, skipFirstLine: Bool = false) -> AgentToolActivity? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if skipFirstLine, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let activity = toolCall(in: record) { return activity }
        }
        return nil
    }

    /// Claude `tool_use` blocks, Codex `function_call` / `custom_tool_call`
    /// items, and Kimi tool calls, in that order of likelihood.
    static func toolCall(in record: [String: Any]) -> AgentToolActivity? {
        // Claude Code: {"type":"assistant","message":{"content":[{"type":"tool_use","name":…,"input":{…}}]}}
        if let message = record["message"] as? [String: Any], let content = message["content"] as? [[String: Any]],
           let use = content.last(where: { $0["type"] as? String == "tool_use" }), let name = use["name"] as? String {
            return classify(tool: name, input: use["input"] as? [String: Any] ?? [:])
        }
        // Codex: {"type":"response_item","payload":{"type":"function_call","name":…,"arguments":"{…}"}}
        if record["type"] as? String == "response_item", let payload = record["payload"] as? [String: Any] {
            let type = payload["type"] as? String ?? ""
            guard ["function_call", "custom_tool_call", "local_shell_call"].contains(type) else { return nil }
            let name = payload["name"] as? String ?? (type == "local_shell_call" ? "shell" : type)
            var input: [String: Any] = [:]
            if let arguments = payload["arguments"] as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] {
                input = parsed
            } else if let text = (payload["input"] ?? payload["arguments"]) as? String {
                input = ["input": text]
            } else if let action = payload["action"] as? [String: Any] {
                input = action
            }
            return classify(tool: name, input: input)
        }
        // Kimi: tool calls carry a function name and JSON arguments.
        if let call = (record["tool_call"] ?? record["function"]) as? [String: Any], let name = call["name"] as? String {
            let input = (call["arguments"] as? String).flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            } ?? [:]
            return classify(tool: name, input: input)
        }
        // Copilot: {"type":"tool.execution_start","data":{"toolName":…,"arguments":{…}}}
        if record["type"] as? String == "tool.execution_start",
           let data = record["data"] as? [String: Any], let name = data["toolName"] as? String {
            return classify(tool: name, input: data["arguments"] as? [String: Any] ?? [:])
        }
        return nil
    }

    public static func classify(tool: String, input: [String: Any]) -> AgentToolActivity {
        let name = tool.lowercased()
        let path = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String
        let file = path.map(shortPath)
        func command() -> String {
            if let text = input["command"] as? String { return text }
            if let parts = input["command"] as? [String] { return parts.joined(separator: " ") }
            if let text = input["cmd"] as? String { return text }
            return input["input"] as? String ?? ""
        }
        switch name {
        case "read", "notebookread", "read_file", "readfile", "view":
            return .init(kind: .reading, detail: file ?? "files")
        case "grep", "glob", "ls", "list_dir", "search_files", "find":
            let pattern = (input["pattern"] ?? input["query"] ?? input["path"]) as? String
            return .init(kind: .reading, detail: pattern.map { "search \($0)" } ?? "searching files")
        case "edit", "multiedit", "write", "notebookedit", "write_file", "str_replace", "create_file":
            return .init(kind: .editing, detail: file ?? "files")
        case "apply_patch":
            return .init(kind: .editing, detail: patchFile(command()) ?? "a patch")
        case "websearch", "web_search", "search_web":
            return .init(kind: .researching, detail: (input["query"] as? String) ?? "the web")
        case "webfetch", "fetch", "web_fetch":
            let url = (input["url"] as? String).flatMap(URL.init(string:))?.host
            return .init(kind: .researching, detail: url ?? "a web page")
        case "task", "agent", "spawn_agent", "followup_task":
            return .init(kind: .delegating, detail: (input["description"] as? String) ?? "a sub-agent")
        case "todowrite", "update_plan", "exitplanmode", "plan":
            return .init(kind: .planning, detail: "updating its plan")
        case "bash", "shell", "exec_command", "local_shell", "run_shell_command", "exec", "custom_tool_call":
            let text = command().trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("apply_patch") { return .init(kind: .editing, detail: patchFile(text) ?? "a patch") }
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
            let lowered = firstLine.lowercased()
            let testing = ["test", "pytest", "jest", "vitest", "xctest", "unittest", "go test", "cargo test"]
                .contains { lowered.contains($0) }
            return .init(kind: testing ? .testing : .running, detail: firstLine.isEmpty ? "a command" : firstLine)
        default:
            if name.hasPrefix("mcp__") || name.contains("browser") || name.contains("search") {
                return .init(kind: .researching, detail: tool.split(separator: "_").last.map(String.init) ?? tool)
            }
            return .init(kind: .working, detail: tool)
        }
    }

    /// `Sources/App/QueueView.swift` → `App/QueueView.swift`.
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    /// The first file an `apply_patch` body names.
    static func patchFile(_ text: String) -> String? {
        for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
            if let range = text.range(of: marker) {
                let rest = text[range.upperBound...]
                let line = rest.prefix { $0 != "\n" && $0 != "\\" }
                return shortPath(String(line).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

/// Provider marks as SVG path data (24-unit viewBox), shared by the app's
/// native icons and the project map page.
public enum ProviderMark {
    public static func path(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: claude
        case .codex: codex
        case .kimi: kimi
        case .copilot: copilot
        }
    }
    static let claude = """
    M 20.998 10.949 L 24 10.949 L 24 14.051 L 21 14.051 L 21 17.079 L 19.513 17.079 L 19.513 20 L 18
    20 L 18 17.079 L 16.513 17.079 L 16.513 20 L 15 20 L 15 17.079 L 9 17.079 L 9 20 L 7.488 20 L
    7.488 17.079 L 6 17.079 L 6 20 L 4.487 20 L 4.487 17.079 L 3 17.079 L 3 14.05 L 0 14.05 L 0
    10.95 L 3 10.95 L 3 5 L 20.998 5 L 20.998 10.949 Z M 6 10.949 L 7.488 10.949 L 7.488 8.102 L 6
    8.102 L 6 10.949 Z M 16.51 10.949 L 18 10.949 L 18 8.102 L 16.51 8.102 L 16.51 10.949 Z
    """
    static let codex = """
    M 8.086 0.457 C 9.049 0.061 10.098 -0.082 11.132 0.042 C 12.465 0.195 13.653 0.762 14.696 1.742
    C 14.725 1.769 14.765 1.78 14.803 1.771 C 16.211 1.425 17.565 1.547 18.864 2.137 L 18.927 2.167
    L 19.081 2.243 C 20.438 2.946 21.411 4.013 21.999 5.441 C 22.277 6.12 22.417 6.829 22.42 7.567 C
    22.44 8.117 22.379 8.666 22.24 9.198 C 22.226 9.253 22.241 9.312 22.28 9.353 C 23.066 10.15
    23.613 11.152 23.858 12.244 C 24.243 14.145 23.848 15.859 22.675 17.384 L 22.493 17.604 C 21.716
    18.494 20.696 19.137 19.559 19.455 C 19.509 19.47 19.468 19.508 19.451 19.557 C 19.196 20.293
    18.94 20.921 18.464 21.549 C 17.265 23.131 15.502 24.011 13.516 24 C 11.933 23.992 10.53 23.413
    9.306 22.264 C 9.268 22.229 9.215 22.217 9.166 22.232 C 8.648 22.399 8.126 22.423 7.562 22.417 C
    6.661 22.41 5.773 22.197 4.967 21.795 C 4.123 21.376 3.388 20.766 2.821 20.014 C 2.618 19.745
    2.417 19.492 2.27 19.193 C 2.067 18.781 1.902 18.352 1.775 17.91 C 1.509 16.907 1.503 15.852
    1.758 14.846 C 1.766 14.822 1.769 14.797 1.766 14.772 C 1.761 14.747 1.748 14.725 1.729 14.708 C
    1.113 14.084 0.641 13.333 0.349 12.506 C 0.155 11.997 0.043 11.461 0.016 10.917 C -0.032 10.201
    0.031 9.482 0.204 8.785 C 0.654 7.301 1.513 6.137 2.781 5.292 C 3.063 5.104 3.331 4.958 3.583
    4.854 C 3.869 4.734 4.156 4.634 4.444 4.55 C 4.486 4.538 4.519 4.505 4.531 4.463 C 4.749 3.678
    5.125 2.945 5.635 2.31 C 6.315 1.464 7.132 0.846 8.086 0.457 Z M 7.282 8.307 C 7.049 7.9 6.531
    7.759 6.125 7.992 C 5.718 8.224 5.576 8.742 5.809 9.149 L 7.503 12.114 L 5.815 14.962 C 5.6
    15.363 5.739 15.862 6.131 16.094 C 6.522 16.326 7.027 16.207 7.275 15.826 L 9.215 12.554 C 9.371
    12.291 9.373 11.965 9.222 11.7 L 7.282 8.307 Z M 12.728 14.547 C 12.279 14.574 11.929 14.945
    11.929 15.395 C 11.929 15.844 12.279 16.215 12.728 16.242 L 17.576 16.242 C 18.028 16.22 18.384
    15.847 18.384 15.394 C 18.384 14.941 18.028 14.568 17.576 14.546 L 12.728 14.546 Z
    """
    static let kimi = """
    M 21.846 0 C 22.908 0 23.769 0.861 23.769 1.923 C 23.769 2.985 22.908 3.846 21.846 3.846 L 20.15
    3.846 C 20.09 3.846 20.032 3.823 19.99 3.78 C 19.947 3.738 19.923 3.68 19.923 3.62 L 19.923
    1.923 C 19.923 0.861 20.784 0 21.846 0 Z M 11.065 11.199 L 18.322 3.999 C 18.459 3.863 18.382
    3.589 18.206 3.589 L 14.3 3.589 C 14.256 3.59 14.214 3.608 14.183 3.64 L 6.363 11.396 C 6.241
    11.516 6.061 11.409 6.061 11.217 L 6.061 3.82 C 6.061 3.693 5.978 3.59 5.876 3.59 L 3.186 3.59 C
    3.083 3.59 3 3.693 3 3.82 L 3 19.77 C 3 19.898 3.083 20 3.186 20 L 5.876 20 C 5.979 20 6.062
    19.898 6.062 19.77 L 6.062 16.52 C 6.062 16.451 6.087 16.385 6.131 16.342 L 8.555 13.936 C 8.608
    13.879 8.695 13.869 8.76 13.913 L 15.244 18.685 C 16.274 19.387 17.459 19.827 18.697 19.968 C
    18.805 19.98 18.897 19.873 18.897 19.738 L 18.897 16.678 C 18.897 16.561 18.827 16.466 18.733
    16.451 C 18.006 16.334 17.314 16.058 16.706 15.644 L 11.093 11.58 C 10.976 11.502 10.961 11.301
    11.065 11.199 Z
    """
    /// The GitHub Copilot visor mark (simple-icons `githubcopilot`), with its
    /// arc commands pre-flattened to cubic curves like the other marks.
    static let copilot = """
    M 23.922 16.997 C 23.061 18.492 18.063 22.02 12 22.02 C 5.937 22.02 0.939 18.492 0.078
    16.997 C 0.034 16.918 0.008 16.831 0 16.741 L 0 13.872 C 0.008 13.797 0.026 13.723 0.053
    13.652 C 0.425 12.717 1.4 11.36 2.658 10.996 C 2.825 10.567 3.072 9.941 3.302 9.479 C
    3.265 9.118 3.248 8.756 3.25 8.393 C 3.25 7.062 3.532 5.894 4.382 5.025 C 4.779 4.619
    5.272 4.308 5.856 4.073 C 7.255 2.937 9.248 1.98 11.978 1.98 C 14.709 1.98 16.745 2.937
    18.144 4.073 C 18.728 4.308 19.221 4.619 19.618 5.025 C 20.468 5.894 20.75 7.062 20.75
    8.393 C 20.75 8.761 20.736 9.126 20.698 9.479 C 20.928 9.941 21.175 10.567 21.342 10.996
    C 22.6 11.36 23.575 12.717 23.947 13.652 C 23.974 13.723 23.992 13.797 24 13.872 L 24
    16.741 C 23.992 16.831 23.966 16.918 23.922 16.997 Z M 12.172 11.005 L 11.828 11.005 C
    11.722 11.183 11.603 11.352 11.473 11.513 C 10.703 12.46 9.555 13.005 7.965 13.005 C
    6.24 13.005 4.976 12.646 4.183 11.746 C 4.154 11.712 4.125 11.678 4.098 11.642 L 4
    11.746 L 4 18.331 C 5.435 19.11 8.514 20.51 12 20.51 C 15.486 20.51 18.565 19.11 20
    18.331 L 20 11.746 L 19.902 11.642 C 19.902 11.642 19.869 11.687 19.817 11.746 C 19.024
    12.646 17.76 13.005 16.035 13.005 C 14.445 13.005 13.297 12.46 12.527 11.513 C 12.397
    11.352 12.278 11.183 12.172 11.005 Z M 14.5 14.255 C 15.049 14.255 15.5 14.706 15.5
    15.255 L 15.5 17.255 C 15.5 17.804 15.049 18.255 14.5 18.255 C 13.951 18.255 13.5 17.804
    13.5 17.255 L 13.5 15.255 C 13.5 14.706 13.951 14.255 14.5 14.255 Z M 9.5 14.255 C
    10.049 14.255 10.5 14.706 10.5 15.255 L 10.5 17.255 C 10.5 17.804 10.049 18.255 9.5
    18.255 C 8.951 18.255 8.5 17.804 8.5 17.255 L 8.5 15.255 C 8.5 14.706 8.951 14.255 9.5
    14.255 Z M 12.813 8.07 C 12.949 9.127 13.216 9.983 13.691 10.567 C 14.133 11.111 14.825
    11.505 16.035 11.505 C 17.608 11.505 18.327 11.168 18.692 10.754 C 19.076 10.319 19.25
    9.604 19.25 8.393 C 19.25 7.253 19.007 6.546 18.545 6.074 C 18.068 5.586 17.226 5.212
    15.721 5.049 C 14.234 4.888 13.529 5.187 13.188 5.578 C 12.919 5.885 12.751 6.386 12.75
    7.156 L 12.75 7.177 C 12.75 7.442 12.771 7.739 12.813 8.07 Z M 11.187 8.07 C 11.229
    7.739 11.25 7.442 11.25 7.176 L 11.25 7.156 C 11.249 6.386 11.081 5.885 10.812 5.578 C
    10.471 5.187 9.766 4.888 8.279 5.049 C 6.774 5.212 5.932 5.586 5.455 6.074 C 4.993
    6.546 4.75 7.253 4.75 8.393 C 4.75 9.604 4.925 10.319 5.308 10.754 C 5.673 11.168 6.392
    11.505 7.965 11.505 C 9.175 11.505 9.867 11.111 10.309 10.567 C 10.784 9.983 11.051
    9.127 11.187 8.07 Z
    """
}
