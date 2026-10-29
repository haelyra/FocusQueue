import Foundation
import Testing

@testable import ECCFocusQueue

@Suite("Help menu feedback")
struct QueueHelpMenuTests {
  private let repository = URL(string: "https://github.com/example/FocusQueue")!

  private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }

  @Test("Feedback opens the labeled issue form with every field prefilled")
  func issueURL() throws {
    let draft = FeedbackDraft(
      kind: .bug, title: "  Panel jumps & flickers ", details: "Steps:\n1. Open settings", includesEnvironment: true)
    let url = try #require(draft.issueURL(repository: repository, environment: "Focus Queue 0.3.0 · macOS 26"))
    #expect(url.absoluteString.hasPrefix("https://github.com/example/FocusQueue/issues/new?"))
    let items = query(url)
    #expect(items["template"] == "feedback.yml")
    #expect(items["title"] == "Bug: Panel jumps & flickers")
    #expect(items["kind"] == "Bug")
    #expect(items["details"] == "Steps:\n1. Open settings")
    #expect(items["environment"] == "Focus Queue 0.3.0 · macOS 26")
  }

  @Test("Opting out of environment details leaves them out of the report")
  func environmentOptOut() throws {
    let draft = FeedbackDraft(kind: .suggestion, title: "Dark icons", details: "", includesEnvironment: false)
    let url = try #require(draft.issueURL(repository: repository, environment: "secret"))
    #expect(query(url)["environment"] == nil)
    let email = try #require(draft.emailURL(to: "feedback@example.com", environment: "secret"))
    #expect(!(query(email)["body"] ?? "").contains("secret"))
  }

  @Test("An untitled report borrows its title from the details, and blank reports cannot submit")
  func titleFallbackAndValidation() {
    #expect(!FeedbackDraft(title: "  ", details: "\n").canSubmit)
    let draft = FeedbackDraft(kind: .question, title: "", details: "How do I pin a task?")
    #expect(draft.canSubmit)
    #expect(draft.issueTitle == "Question: How do I pin a task?")
  }

  @Test("Long details are shortened so the issue link stays within GitHub's limit")
  func longDetailsBounded() throws {
    let draft = FeedbackDraft(details: String(repeating: "a", count: FeedbackDraft.maximumDetailsLength + 500))
    #expect(draft.boundedDetails.hasSuffix("[Details shortened to fit the link.]"))
    let url = try #require(draft.issueURL(repository: repository))
    #expect(url.absoluteString.count < 8_000)
  }

  @Test("Email feedback carries a tagged subject and the environment footer")
  func emailURL() throws {
    let draft = FeedbackDraft(kind: .other, title: "Hello", details: "Thanks!")
    let url = try #require(draft.emailURL(to: "feedback@example.com", environment: "Focus Queue 0.3.0"))
    #expect(url.scheme == "mailto")
    let items = query(url)
    #expect(items["subject"] == "[Focus Queue] Other: Hello")
    #expect(items["body"] == "Thanks!\n\n---\nFocus Queue 0.3.0")
  }

  @Test("Unpublished destinations stay visible as coming soon instead of opening a dead link")
  func placeholderLinks() {
    #expect(QueueHelpLinks.documentation == nil)
    #expect(QueueHelpLinks.repository != nil)
  }
}
