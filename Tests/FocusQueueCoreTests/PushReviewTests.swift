import Foundation
import Testing
@testable import FocusQueueCore

private actor PushReviewRunner: ProcessRunning {
    let path: String
    let verdict: String
    let changed: Bool
    var headReads = 0
    private(set) var calls: [ProcessSpecification] = []
    init(path: String, verdict: String, changed: Bool) {
        self.path = path; self.verdict = verdict; self.changed = changed
    }
    func run(_ specification: ProcessSpecification) throws -> ProcessResult {
        calls.append(specification)
        let output: String
        if specification.executable == "/mock/reviewer" { output = verdict }
        else if specification.arguments == ["rev-parse", "--show-toplevel"] { output = path }
        else if specification.arguments == ["symbolic-ref", "--short", "HEAD"] { output = "feature" }
        else if specification.arguments == ["rev-parse", "HEAD"] {
            headReads += 1
            output = changed && headReads >= 3 ? "bbbb" : "aaaa"
        } else if specification.arguments.first == "status" { output = "" }
        else { throw TaskContextError.commandFailed("Unexpected test command") }
        return ProcessResult(exitCode: 0, standardOutput: output, standardError: "", timedOut: false)
    }
}

@Test("Push scan retains a commit-specific receipt and rejects changed or unaccepted work", arguments: ["ACCEPT\nOnly assigned source changes.", "REJECT\nRemove the generated log.", "Looks fine"])
func pushReviewVerdicts(verdict: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = TaskContext(ticketID: "ECC-777", title: "Review", summary: "", successCriteria: "",
        planPath: root.appendingPathComponent("plan.md").path, updatedAt: Date())
    var subtask = TaskSubtask(title: "Fix assigned issue")
    subtask.workspace = AgentWorkspace(path: root.path, repositoryPath: root.path, branch: "feature", baseCommit: "base")
    let configuration = VerifierConfiguration(enabled: true, executable: "/mock/reviewer", sessionName: "test")
    for changed in [false, true] {
        let runner = PushReviewRunner(path: root.path, verdict: verdict, changed: changed)
        let receipt = try await PushReviewer(runner: runner).review(context: context, subtask: subtask,
            configuration: configuration, supportDirectory: root)
        #expect(receipt.accepted == (!changed && verdict.hasPrefix("ACCEPT\n")))
        #expect(receipt.commit == "aaaa")
        let calls = await runner.calls
        #expect(calls.contains { $0.arguments.contains("read-only") })
        #expect(!calls.contains { $0.arguments.first == "push" })
    }
    let receipts = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("push-reviews"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
    #expect(receipts.count == 2)
}
