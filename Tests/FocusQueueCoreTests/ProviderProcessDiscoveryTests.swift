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
        let records = try await WezTermController(runner: runner).knownProviderProcesses(requireComplete: true).resolved
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
            .knownProviderProcesses(requireComplete: true).resolved

        #expect(records.map(\.sessionID).sorted() == [child, sibling].sorted())
        #expect(records.allSatisfy { $0.parentSessionID == parent })
        #expect(records.allSatisfy { $0.isSubagent })
        #expect(Dictionary(uniqueKeysWithValues: records.map { ($0.sessionID, $0.promptHint) })
            == [child: "registration hardening", sibling: "title audit"])
    }

    @Test("A starting process with no writer lock is reported unresolved in both scan modes")
    func noIdentityReportedUnresolved() async throws {
        let outputs = ["40 ttys040 /opt/codex\n",
            "p40\nfcwd\nn/tmp/repository\nf8\nn/Users/example/.codex/sessions/rollout-\(history).jsonl\n"]
        let discovery = try await WezTermController(runner: ProviderDiscoveryRunner(outputs)).knownProviderProcesses()
        #expect(discovery.resolved.isEmpty)
        #expect(discovery.unresolved.map(\.processID) == [40])
        let complete = try await WezTermController(runner: ProviderDiscoveryRunner(outputs))
            .knownProviderProcesses(requireComplete: true)
        #expect(complete.resolved.isEmpty)
        #expect(complete.unresolved.map(\.processID) == [40])
        #expect(complete.unresolved.first?.cwd == "/tmp/repository")
    }

    @Test("Multiple Claude transcripts do not choose an arbitrary identity")
    func ambiguousClaudeFailsClosed() async throws {
        let runner = ProviderDiscoveryRunner(["40 ttys040 /opt/claude\n",
            "p40\nfcwd\nn/tmp/repository\nf8\nn/Users/example/.claude/projects/tmp/\(parent).jsonl\nf9\nn/Users/example/.claude/projects/tmp/\(child).jsonl\n"])
        let scan = try await WezTermController(runner: runner).knownProviderProcesses()
        #expect(scan.resolved.isEmpty)
        #expect(scan.unresolved.map(\.processID) == [40])
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

    @Test("A codex app-server daemon is infrastructure and never poisons the identity scan")
    func codexInfrastructureIgnored() async throws {
        let runner = ProviderDiscoveryRunner([
            "40 ?? /Users/example/.codex/packages/codex/codex app-server daemon pid-update-loop\n"
                + "41 ttys041 /opt/codex app-server --listen unix:// --managed-daemon\n"
                + "42 ttys042 /opt/codex\n",
            "p42\nfcwd\nn/tmp/repository\nf8\nn/Users/example/.codex/thread-writer-locks/\(parent).lock\n",
        ])
        let scan = try await WezTermController(runner: runner).knownProviderProcesses(requireComplete: true)
        #expect(scan.resolved.map(\.sessionID) == [parent])
        #expect(scan.resolved.first?.processID == 42)
        #expect(scan.unresolved.isEmpty)
    }

    @Test("Infrastructure-only provider processes leave no live owner and never throw")
    func infrastructureOnlyLocateReturnsNil() async throws {
        let runner = ProviderDiscoveryRunner([
            "40 ?? /opt/codex app-server daemon pid-update-loop\n",
        ])
        #expect(try await WezTermController(runner: runner).locateProviderProcess(
            provider: .codex, sessionID: parent, retryDelay: .zero) == nil)
        let scan = try await WezTermController(runner: ProviderDiscoveryRunner([
            "40 ?? /opt/codex app-server daemon pid-update-loop\n",
        ])).knownProviderProcesses(requireComplete: true)
        #expect(scan.resolved.isEmpty)
        #expect(scan.unresolved.isEmpty)
    }

    @Test("A Claude process without an open transcript resolves from the newest project transcript on disk")
    func claudeDiskFallbackIdentity() async throws {
        let claudeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "focus-queue-claude-fallback-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: claudeRoot) }
        let project = claudeRoot.appendingPathComponent("projects/-tmp-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: project.appendingPathComponent("\(history).jsonl"))
        try Data("{}\n".utf8).write(to: project.appendingPathComponent("\(parent).jsonl"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: project.appendingPathComponent("\(history).jsonl").path)

        let runner = ProviderDiscoveryRunner([
            "40 ttys040 /opt/claude\n",
            "p40\nfcwd\nn/tmp/repository\nf8\nn/tmp/cc-socks/40.sock\n",
        ])
        let scan = try await WezTermController(runner: runner, claudeRoot: claudeRoot)
            .knownProviderProcesses(requireComplete: true)
        #expect(scan.resolved.map(\.sessionID) == [parent])
        #expect(scan.resolved.first?.processID == 40)
        #expect(scan.unresolved.isEmpty)
    }

    @Test("Two unresolved Claude processes in one project keep duplicate-resume protection")
    func ambiguousClaudeProjectStillFailsClosed() async throws {
        let claudeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "focus-queue-claude-ambiguous-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: claudeRoot) }
        let project = claudeRoot.appendingPathComponent("projects/-tmp-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: project.appendingPathComponent("\(parent).jsonl"))

        let sample = ["40 ttys040 /opt/claude\n41 ttys041 /opt/claude\n",
            "p40\nfcwd\nn/tmp/repository\np41\nfcwd\nn/tmp/repository\n"]
        // The scan reports both as unresolved rather than misattributing the
        // newest transcript to either process.
        let scan = try await WezTermController(
            runner: ProviderDiscoveryRunner(sample), claudeRoot: claudeRoot)
            .knownProviderProcesses(requireComplete: true)
        #expect(scan.resolved.isEmpty)
        #expect(scan.unresolved.map(\.processID).sorted() == [40, 41])

        let runner = ProviderDiscoveryRunner(sample + sample + sample + sample)
        await #expect(throws: WezTermError.self) {
            try await WezTermController(runner: runner, claudeRoot: claudeRoot).locateProviderProcess(
                provider: .claude, sessionID: parent, retryDelay: .zero)
        }
        #expect(await runner.outputs.isEmpty)
    }

    @Test("An unresolved Claude process in another project does not block the requested session")
    func unrelatedClaudeProjectDoesNotBlock() async throws {
        let claudeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "focus-queue-claude-unrelated-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: claudeRoot) }
        let project = claudeRoot.appendingPathComponent("projects/-tmp-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: project.appendingPathComponent("\(parent).jsonl"))

        let runner = ProviderDiscoveryRunner([
            "40 ttys040 /opt/claude\n",
            "p40\nfcwd\nn/tmp/other\n",
        ])
        #expect(try await WezTermController(runner: runner, claudeRoot: claudeRoot).locateProviderProcess(
            provider: .claude, sessionID: parent, retryDelay: .zero) == nil)
        #expect(await runner.outputs.isEmpty)
    }

    @Test("A Kimi process resolves from its open session directory like an exact identity")
    func kimiSessionDirectoryIdentity() async throws {
        let kimi = "session_55555555-5555-4555-8555-555555555555"
        let runner = ProviderDiscoveryRunner([
            "40 ttys040 /opt/kimi\n",
            "p40\nfcwd\nn/tmp/repository\nf8\nn/Users/example/.kimi-code/sessions/\(kimi)/wire.jsonl\n",
        ])
        let scan = try await WezTermController(runner: runner).knownProviderProcesses(requireComplete: true)
        #expect(scan.resolved.map(\.sessionID) == [kimi])
        #expect(scan.resolved.first?.provider == .kimi)
        #expect(scan.unresolved.isEmpty)
        let locator = ProviderDiscoveryRunner([
            "40 ttys040 /opt/kimi\n",
            "p40\nfcwd\nn/tmp/repository\nf8\nn/Users/example/.kimi-code/sessions/\(kimi)/wire.jsonl\n",
        ])
        #expect(try await WezTermController(runner: locator).locateProviderProcess(
            provider: .kimi, sessionID: kimi, retryDelay: .zero)?.processID == 40)
    }

    @Test("An unresolved Kimi process keeps the conservative fail-closed posture")
    func unresolvedKimiFailsClosed() async throws {
        let sample = ["40 ttys040 /opt/kimi\n", "p40\nfcwd\nn/tmp/repository\n"]
        let runner = ProviderDiscoveryRunner(sample + sample + sample + sample)
        await #expect(throws: WezTermError.self) {
            try await WezTermController(runner: runner).locateProviderProcess(
                provider: .kimi, sessionID: "session_55555555-5555-4555-8555-555555555555",
                retryDelay: .zero)
        }
        #expect(await runner.outputs.isEmpty)
    }
}
