import Foundation
import Testing
@testable import FocusQueueCore

private func sampleProviders() throws -> [T3ProviderInfo] {
    let root = try T3Fixtures.json("capabilities-sample.json")
    return try (root["providers"]?.arrayValue ?? []).map { item in
        T3ProviderInfo(providerInstanceId: item["providerInstanceId"]?.stringValue ?? "",
                       driverKind: item["driverKind"]?.stringValue ?? "",
                       displayName: item["displayName"]?.stringValue ?? "",
                       models: try item["models"].map { try $0.decode([T3ModelInfo].self) } ?? [],
                       constraints: (item["constraints"]?.arrayValue ?? []).compactMap(\.stringValue))
    }
}

private let questionRequest = T3PendingRequest(requestId: "REQ_1", questions: [
    T3Question(id: "Q1", header: "Choice", question: "Which option?",
               options: [T3QuestionOption(label: "Option A"), T3QuestionOption(label: "Option B")]),
])

@Suite("T3 answers and row presentation")
struct T3PresentationTests {
    @Test("A selected option becomes the answer, and typed text overrides it")
    func answers() throws {
        let request = (try? T3Fixtures.json("tool-t3_pending_request-read.json").decode(T3PendingRequest.self)) ?? questionRequest
        let id = try #require(request.questions.first?.id)
        #expect(T3AnswerBuilder.answers(for: request, selections: [id: "Option B"], freeText: [:]) == [id: "Option B"])
        #expect(T3AnswerBuilder.answers(for: request, selections: [id: "Option B"], freeText: [id: " my own "]) == [id: "my own"])
        #expect(!T3AnswerBuilder.isComplete(request, selections: [:], freeText: [:]))
    }

    private func row(_ change: (inout T3ThreadReference) -> Void, status: TaskSubtaskStatus = .working) -> T3RowPresentation {
        var subtask = T3Samples.t3Subtask(status: status)
        change(&subtask.t3!)
        return T3RowPresentation.make(subtask)
    }

    @Test("Approval only shows Needs approval with Open in T3 Code and no approve or deny")
    func approval() {
        let presentation = row { $0.pendingApprovalCount = 1 }
        #expect(presentation.badge == "Needs approval")
        #expect(presentation.actions.contains(.openInT3))
        #expect(!presentation.actions.contains(.answer))
        #expect(Set(presentation.actions.map(\.rawValue)).isDisjoint(with: ["approve", "deny"]))
    }

    @Test("A question with an approval shows both")
    func questionAndApproval() {
        let presentation = row { $0.openQuestionIds = ["REQ_1"]; $0.pendingApprovalCount = 1 }
        #expect(presentation.badge == "Needs an answer")
        #expect(presentation.notes == ["Needs approval"])
        #expect(presentation.actions.contains(.answer))
    }

    @Test("Reachability, launch, and cleanup states have their exact labels")
    func labels() {
        #expect(row { $0.reachability = .unreachable }.badge == "T3 Code unreachable")
        #expect(row { $0.reachability = .otherServer }.badge == "On another T3 Code server")
        let missing = row { $0.reachability = .threadMissing }
        #expect(missing.badge == "Thread missing")
        #expect(missing.actions == [.removeAgent])
        #expect(row { $0.cleanup = .pending(reason: "T3 Code is unreachable") }.notes == ["Cleanup pending: T3 Code is unreachable"])
        let retained = "Agent worktree retained: it contains uncommitted, untracked, or ignored files."
        #expect(row { $0.cleanup = .retained(message: retained) }.notes == [retained])
        #expect(row { $0.cleanup = .removed }.notes.isEmpty)
        var launching = TaskSubtask(title: "A", runtimeMode: .t3)
        launching.t3Launch = T3LaunchIntent(requestId: "R", environmentId: "E", projectId: "P", worktreePath: "/w",
                                            title: "A", createdAt: Date(), phase: .unknown)
        #expect(T3RowPresentation.make(launching).badge == "Launch status unknown, reconciling")
    }
}

@Suite("T3 launch picker")
struct T3LaunchPickerModelTests {
    @Test("Only enabled providers are offered, and Claude preselects its T3 driver")
    func claude() throws {
        let picker = T3LaunchPickerModel(providers: try sampleProviders(), agentProvider: .claude)
        #expect(!picker.providers.contains { $0.driverKind == "grok" || !$0.available })
        #expect(picker.instanceId == "INSTANCE_CLAUDE")
        #expect(picker.isValid)
    }

    @Test("A Kimi agent is invalid until a provider is chosen")
    func kimi() throws {
        var picker = T3LaunchPickerModel(providers: try sampleProviders(), agentProvider: .kimi)
        #expect(!picker.isValid && picker.choice == nil)
        picker.selectProvider("INSTANCE_CURSOR")
        #expect(picker.choice == T3LaunchChoice(instanceId: "INSTANCE_CURSOR", model: "kimi-k3", options: picker.options))
    }

    @Test("Changing the model resets options to that model's defaults")
    func optionsReset() throws {
        var picker = T3LaunchPickerModel(providers: try sampleProviders(), agentProvider: .claude,
                                         preferredModel: "claude-haiku-5-5")
        let defaults = picker.options
        if let option = picker.selectedModel?.options.first, let other = option.values.last {
            picker.setOption(option.id, other)
            #expect(picker.choice?.options[option.id] == other)
            picker.selectModel("claude-fable-5-2")
            picker.selectModel("claude-haiku-5-5")
            #expect(picker.options == defaults)
        }
        #expect(picker.choice?.model == "claude-haiku-5-5")
    }
}
