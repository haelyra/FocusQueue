import Foundation
import Testing
import FocusQueueCore
@testable import ECCFocusQueue

/// Exercises the actual document model, source harness, and installed provider without UI automation.
@Test("Live ephemeral reader answers from document/task context and searches without editing",
    .enabled(if: ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_LIVE_DOCUMENT_TESTS"] == "1"))
@MainActor
func liveDocumentReaderSanity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-document-reader-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try await TaskContextStore(root: root).ensureContext(
        ticket: .init(id: "ECC-907", title: "Reader workflow sanity", status: "open", summary: "Explain this document."))
    let document = root.appendingPathComponent("report.md")
    let facts = root.appendingPathComponent("supporting-facts.txt")
    let forbidden = root.appendingPathComponent("must-not-create.txt")
    try Data("The document marker is READER_DOCUMENT_842.\n".utf8).write(to: document)
    try Data("The task marker is READER_TASK_842.\n".utf8).write(to: URL(fileURLWithPath: context.planPath))
    let searchMarker = UUID().uuidString
    try Data("The supporting marker is \(searchMarker).\n".utf8).write(to: facts)
    let provider = AgentProvider(rawValue: ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_DOCUMENT_PROVIDER"] ?? "codex") ?? .codex
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = source.appendingPathComponent("Scripts/focus_queue_\(provider.rawValue).py").path
    let executable = root.appendingPathComponent("reader-harness").path
    let quotedScript = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    try Data("#!/bin/sh\nexec /usr/bin/env python3 \(quotedScript) \"$@\"\n".utf8)
        .write(to: URL(fileURLWithPath: executable))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
    let agent = HarnessQueueAgent(provider: provider)
    let services = DocumentChatServices(agent: { _ in agent }, executable: { _ in executable },
        resolveCreator: { _ in nil }, modelChoices: { _ in [] })
    let chat = DocumentConversation(document: document, subject: .init(kind: .task(context)), support: root,
        services: services, configuration: .init(enabled: true, executable: executable, sessionName: "unused", timeoutSeconds: 90),
        dashboardPath: root.appendingPathComponent("dashboard.json").path, workspace: root.path, provider: provider)
    await chat.load()
    func ask(_ question: String) async throws -> String {
        chat.draft = question; chat.send()
        for _ in 0..<1_100 where chat.isResponding { try await Task.sleep(for: .milliseconds(100)) }
        try #require(!chat.isResponding, "Reader did not finish within its run budget")
        return try #require(chat.messages.last?.text)
    }
    let first = try await ask("Return only the document marker and task marker, separated by one space.")
    try #require(first.contains("READER_DOCUMENT_842") && first.contains("READER_TASK_842"), "\(first)")
    let second = try await ask("Read \(facts.path) with your read/search tools. Return its exact complete contents. Do not infer contents from earlier messages.")
    try #require(second.contains(searchMarker), "\(second)")
    _ = try await ask("Create \(forbidden.path) containing hello.")
    try #require(!FileManager.default.fileExists(atPath: forbidden.path))
    try #require(String(contentsOf: document, encoding: .utf8) == "The document marker is READER_DOCUMENT_842.\n")
    let key = DocumentConversation.key(document: document, taskID: context.ticketID)
    let sessions = context.contextDirectory.appendingPathComponent("document-agents/\(key.prefix(16))/sessions.json")
    if FileManager.default.fileExists(atPath: sessions.path) {
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sessions)) as? [String: Any])
        let mapping = try #require(state["sessions"] as? [String: String])
        try #require(mapping.isEmpty)
    }
    print("LIVE_DOCUMENT_READER \(provider.rawValue): document/task context, tool search, edit refusal, no resumed-session mapping verified")
}

/// Runs the real document model, source harness, and installed provider on a
/// temporary document: one selected-cell edit, then checks the file and ledger.
@Test("Live document editor applies a selected-cell edit in one small call",
    .enabled(if: ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_LIVE_DOCUMENT_TESTS"] == "1"))
@MainActor
func liveDocumentEditorSanity() async throws {
    // Kimi matches sessions by real path, and the temporary directory is a symlink.
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("live-document-editor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try await TaskContextStore(root: root).ensureContext(
        ticket: .init(id: "ECC-908", title: "Editor workflow sanity", status: "open", summary: "Edit this document."))
    let document = root.appendingPathComponent("plan.md")
    let original = "# Plan\n\n## Decisions\n\n| Area | Options | Decision |\n| --- | --- | --- |\n"
        + "| Desktop | Electron packaging matrix with signed installers | Pending |\n"
        + "| Editing | CodeMirror language subset and draft recovery | Pending |\n\n"
        + String(repeating: "Unrelated planning prose about other things entirely.\n", count: 400)
    try Data(original.utf8).write(to: document)
    let provider = AgentProvider(rawValue: ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_DOCUMENT_PROVIDER"] ?? "claude") ?? .claude
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = source.appendingPathComponent("Scripts/focus_queue_\(provider.rawValue).py").path
    let executable = root.appendingPathComponent("editor-harness").path
    let quotedScript = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    try Data("#!/bin/sh\nexec /usr/bin/env python3 \(quotedScript) \"$@\"\n".utf8).write(to: URL(fileURLWithPath: executable))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
    let agent = HarnessQueueAgent(provider: provider)
    let services = DocumentChatServices(agent: { _ in agent }, executable: { _ in executable },
        resolveCreator: { _ in nil }, modelChoices: { _ in [] })
    let chat = DocumentConversation(document: document, subject: .init(kind: .task(context)), support: root,
        services: services, configuration: .init(enabled: true, executable: executable, sessionName: "unused", timeoutSeconds: 90),
        dashboardPath: root.appendingPathComponent("dashboard.json").path, workspace: root.path, provider: provider)
    await chat.load()
    chat.setRecipient(.newAgent)
    chat.selection = PlanCanvasSelection(kind: .text, documentPath: document.path, selector: "tr:nth-of-type(2) > td:nth-of-type(2)",
        tag: "td", excerpt: "Editing CodeMirror language subset and draft recovery")
    chat.draft = "Set this row's Decision to B."
    chat.send()
    for _ in 0..<1_100 where chat.isResponding { try await Task.sleep(for: .milliseconds(100)) }
    try #require(!chat.isResponding, "Editor did not finish within its run budget")
    let edited = try String(contentsOf: document, encoding: .utf8)
    try #require(edited == original.replacingOccurrences(of: "draft recovery | Pending", with: "draft recovery | B"), "\(chat.messages.last?.text ?? "")")
    let ledger = try String(contentsOf: root.appendingPathComponent("analytics/prompt-usage.jsonl"), encoding: .utf8)
    let usage = ledger.split(separator: "\n").compactMap { line -> [String: Any]? in
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }.first { $0["component"] as? String == "provider_usage" }
    let total = ["actualInputTokens", "actualOutputTokens", "cachedInputTokens"].reduce(0) { $0 + (usage?[$1] as? Int ?? 0) }
    print("LIVE_DOCUMENT_EDITOR \(provider.rawValue): edited one cell, \(usage == nil ? "usage not recorded" : "\(total) tokens"), reply: \(chat.messages.last?.text ?? "")")
    if provider == .claude { try #require(usage != nil && total < 6_000, "Editor used \(total) tokens") }
}
