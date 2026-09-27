import Foundation
import Testing

@testable import FocusQueueCore

@Suite("Escalation launch request inbox")
struct AgentLaunchRequestInboxTests {
    @Test("Pending requests decode in file order and broken files are skipped")
    func pendingDecoding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-requests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(AgentLaunchRequest(ticketId: "ECC-002", title: "Second",
            provider: "claude", model: "claude-test", effort: "high", prompt: "Work on ECC-002",
            version: 1, requestedAt: "2026-09-27T08:00:00Z"))
            .write(to: root.appendingPathComponent("ECC-002.json"))
        try encoder.encode(AgentLaunchRequest(ticketId: "ECC-001"))
            .write(to: root.appendingPathComponent("ECC-001.json"))
        try Data("broken".utf8).write(to: root.appendingPathComponent("bad.json"))
        try encoder.encode(AgentLaunchRequest(ticketId: "  "))
            .write(to: root.appendingPathComponent("blank.json"))
        let inbox = AgentLaunchRequestInbox(directory: root)

        let pending = try await inbox.pending()

        #expect(pending.map(\.ticketId) == ["ECC-001", "ECC-002"])
        let second = try #require(pending.last)
        #expect(second.title == "Second")
        #expect(second.provider == "claude")
        #expect(second.model == "claude-test")
        #expect(second.effort == "high")
        #expect(second.prompt == "Work on ECC-002")
        #expect(second.requestedAt == "2026-09-27T08:00:00Z")
    }

    @Test("A missing inbox directory has no pending requests")
    func missingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-requests-missing-\(UUID().uuidString)", isDirectory: true)
        let inbox = AgentLaunchRequestInbox(directory: root)
        #expect(try await inbox.pending().isEmpty)
    }

    @Test("Consumption removes only the matching ticket's request file")
    func consumption() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-requests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(AgentLaunchRequest(ticketId: "ECC-001"))
            .write(to: root.appendingPathComponent("ECC-001.json"))
        try encoder.encode(AgentLaunchRequest(ticketId: "ECC-002"))
            .write(to: root.appendingPathComponent("ECC-002.json"))
        let inbox = AgentLaunchRequestInbox(directory: root)

        await inbox.consume(AgentLaunchRequest(ticketId: "ECC-001"))
        await inbox.consume(AgentLaunchRequest(ticketId: "../ecc-002"))

        #expect(try await inbox.pending().map(\.ticketId) == ["ECC-002"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ECC-001.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ECC-002.json").path))
    }
}
