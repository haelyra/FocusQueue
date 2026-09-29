import Foundation
import Testing
@testable import FocusQueueCore

private actor ProviderDiscoveryRunner: ProcessRunning {
    var outputs: [ProcessResult]
    init(_ outputs: [String]) {
        self.outputs = outputs.map { .init(exitCode: 0, standardOutput: $0, standardError: "", timedOut: false) }
    }
    func run(_ specification: ProcessSpecification) throws -> ProcessResult {
        guard !outputs.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return outputs.removeFirst()
    }
}

@Suite("Provider process discovery")
struct ProviderProcessDiscoveryTests {
    let parent = "11111111-1111-4111-8111-111111111111"
    let child = "22222222-2222-4222-8222-222222222222"
    let history = "33333333-3333-4333-8333-333333333333"

    @Test("Writer locks identify both live Codex threads without claiming an opened old transcript")
    func exactWriterLocks() async throws {
        let runner = ProviderDiscoveryRunner([
            "40 ttys040 /opt/codex\n41 ?? /opt/claude\n42 ttys042 /opt/unrelated\n",
            "p40\nfcwd\nn/tmp/repository with spaces\nf8\nn/Users/example/.codex/thread-writer-locks/\(parent).lock\nf9\nn/Users/example/.codex/thread-writer-locks/\(child).lock\nf10\nn/Users/example/.codex/sessions/rollout-\(history).jsonl\np41\nfcwd\nn/tmp/claude\nf9\nn/Users/example/.claude/projects/tmp/\(history).jsonl\n",
        ])
        let records = try await WezTermController(runner: runner).knownProviderProcesses(requireComplete: true)
        #expect(records.count == 3)
        #expect(Set(records.filter { $0.provider == .codex }.map(\.sessionID)) == Set([parent, child]))
        #expect(records.first { $0.sessionID == parent }?.cwd == "/tmp/repository with spaces")
        #expect(records.first { $0.sessionID == parent }?.tty == "/dev/ttys040")
        #expect(records.first { $0.provider == .claude }?.tty == nil)
    }

    @Test("Codex discovery retains distinct sibling identities and their parent")
    func codexSiblingMetadata() async throws {
        let sibling = "44444444-4444-4444-8444-444444444444"
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "focus-queue-provider-metadata-\(UUID())", isDirectory: true)
        let fixture = fixtureRoot.appendingPathComponent(".codex/sessions", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let childURL = fixture.appendingPathComponent("rollout-\(child).jsonl")
        let siblingURL = fixture.appendingPathComponent("rollout-\(sibling).jsonl")
        for (url, id, source) in [
            (childURL, child, "{\"subagent\":{\"thread_spawn\":{\"nickname\":\"vibrant-otter\",\"agent_path\":\"/root/registration_hardening\"}}}"),
            (siblingURL, sibling, "{\"subagent\":{\"thread_spawn\":{\"agent_path\":\"/root/title_audit\"}}}"),
        ] {
            try Data("""
            {"type":"session_meta","payload":{"id":"\(id)","session_id":"\(parent)","parent_thread_id":"\(parent)","source":\(source)}}
            """.utf8).write(to: url)
        }
        let runner = ProviderDiscoveryRunner([
            "40 ttys040 /opt/codex\n",
            "p40\nfcwd\nn/tmp/repository\n"
                + "n/Users/example/.codex/thread-writer-locks/\(child).lock\n"
                + "n/Users/example/.codex/thread-writer-locks/\(sibling).lock\n"
                + "n\(childURL.path)\nn\(siblingURL.path)\n",
        ])

        let records = try await WezTermController(runner: runner)
            .knownProviderProcesses(requireComplete: true)

        #expect(records.map(\.sessionID).sorted() == [child, sibling].sorted())
        #expect(records.allSatisfy { $0.parentSessionID == parent })
        #expect(records.allSatisfy { $0.isSubagent })
        #expect(Dictionary(uniqueKeysWithValues: records.map { ($0.sessionID, $0.promptHint) })
            == [child: "registration hardening", sibling: "title audit"])
    }

    @Test("A starting process with no writer lock makes a complete stopped check unknown")
    func noIdentityFailsClosed() async throws {
        let outputs = ["40 ttys040 /opt/codex\n",
            "p40\nfcwd\nn/tmp/repository\nf8\nn/Users/example/.codex/sessions/rollout-\(history).jsonl\n"]
        #expect(try await WezTermController(runner: ProviderDiscoveryRunner(outputs)).knownProviderProcesses().isEmpty)
        await #expect(throws: (any Error).self) {
            try await WezTermController(runner: ProviderDiscoveryRunner(outputs)).knownProviderProcesses(requireComplete: true)
        }
    }

    @Test("Multiple Claude transcripts do not choose an arbitrary identity")
    func ambiguousClaudeFailsClosed() async throws {
        let runner = ProviderDiscoveryRunner(["40 ttys040 /opt/claude\n",
            "p40\nfcwd\nn/tmp/repository\nf8\nn/Users/example/.claude/projects/tmp/\(parent).jsonl\nf9\nn/Users/example/.claude/projects/tmp/\(child).jsonl\n"])
        #expect(try await WezTermController(runner: runner).knownProviderProcesses().isEmpty)
    }

    @Test("A closing process gets a bounded ownership recheck before stopped-session resume")
    func closingProcessRecheck() async throws {
        let runner = ProviderDiscoveryRunner([
            "40 ttys040 /opt/codex\n", "p40\nfcwd\nn/tmp/repository\n",
            "41 ttys041 /opt/codex\n", "p41\nfcwd\nn/tmp/other\nf8\nn/Users/example/.codex/thread-writer-locks/\(child).lock\n",
        ])
        #expect(try await WezTermController(runner: runner).locateProviderProcess(
            provider: .codex, sessionID: parent, retryDelay: .zero) == nil)
        #expect(await runner.outputs.isEmpty)
    }

    @Test("Unresolved ownership still fails closed after bounded retries")
    func persistentUnknownRecheck() async throws {
        let sample = ["40 ttys040 /opt/codex\n", "p40\nfcwd\nn/tmp/repository\n"]
        let runner = ProviderDiscoveryRunner(sample + sample + sample + sample)
        await #expect(throws: WezTermError.self) {
            try await WezTermController(runner: runner).locateProviderProcess(
                provider: .codex, sessionID: parent, retryDelay: .zero)
        }
        #expect(await runner.outputs.isEmpty)
    }

    @Test("A starting process that acquires the requested identity is returned rather than duplicated")
    func startingProcessRecheck() async throws {
        let runner = ProviderDiscoveryRunner([
            "40 ttys040 /opt/codex\n", "p40\nfcwd\nn/tmp/repository\n",
            "40 ttys040 /opt/codex\n", "p40\nfcwd\nn/tmp/repository\nf8\nn/Users/example/.codex/thread-writer-locks/\(parent).lock\n",
        ])
        #expect(try await WezTermController(runner: runner).locateProviderProcess(
            provider: .codex, sessionID: parent, retryDelay: .zero)?.sessionID == parent)
    }
}
