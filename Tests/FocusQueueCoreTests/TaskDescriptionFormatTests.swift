import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Task description format")
struct TaskDescriptionFormatTests {
  @Test("A direct what/why/how description passes")
  func compliantDescription() {
    let text = "What: Ship ECC Focus Queue, a persistent macOS panel that tracks ECC tasks. "
      + "Why: The current ECC design is outdated and loads the user's working memory. "
      + "How: A SwiftUI panel backed by a durable library registers agents and records evidence."
    #expect(TaskDescriptionFormat.issues(for: text).isEmpty)
  }

  @Test("Empty text is allowed because creation falls back to the title")
  func emptyDescription() {
    #expect(TaskDescriptionFormat.issues(for: "").isEmpty)
    #expect(TaskDescriptionFormat.issues(for: "   \n").isEmpty)
  }

  @Test("Opening with a commit hash is rejected, with or without a leading verb")
  func commitHashOpening() {
    for text in [
      "Installed c14198d adds repository-backed project views. It also retains tracking. Acceptance remains.",
      "c14198d adds repository-backed project views. It also retains tracking. Acceptance remains.",
    ] {
      let issues = TaskDescriptionFormat.issues(for: text)
      #expect(issues.contains { $0.contains("commit hash") }, "expected commit-hash issue for: \(text)")
    }
  }

  @Test("A lowercase word opening is never mistaken for a hash")
  func wordOpeningIsNotAHash() {
    let text = "Defaced dashboards confused readers. The queue now shows descriptions directly. "
      + "It renders the summary inline in every task detail."
    #expect(TaskDescriptionFormat.issues(for: text).isEmpty)
  }

  @Test("Descriptions must total 3-6 sentences")
  func sentenceCount() {
    let tooShort = TaskDescriptionFormat.issues(for: "Track tasks. Keep evidence organized.")
    #expect(tooShort.contains { $0.contains("3-6 sentences") })
    let long = (1...7).map { "Sentence number \($0)." }.joined(separator: " ")
    let tooLong = TaskDescriptionFormat.issues(for: long)
    #expect(tooLong.contains { $0.contains("3-6 sentences") })
  }

  @Test("Overly long sentences are flagged")
  func longSentence() {
    let sentence = (1...50).map { "word\($0)" }.joined(separator: " ")
    let text = "\(sentence). Short one. Short two."
    #expect(TaskDescriptionFormat.issues(for: text).contains { $0.contains("simple") })
  }
}
