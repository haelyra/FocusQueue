import Foundation

/// Checks that a task description answers what, why, and how directly:
/// 1-2 simple sentences for each, never opening with a commit hash or code.
public enum TaskDescriptionFormat {
  public static let sentenceCountRange = 3...6
  public static let maximumSentenceWords = 45

  /// Returns one user-facing issue per violation; an empty result means the
  /// description follows the required format. Empty text is allowed because
  /// task creation falls back to the title.
  public static func issues(for text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    var issues: [String] = []
    if opensWithCommitReference(trimmed) {
      issues.append("Never open with a commit hash or code; start with what the task is.")
    }
    let sentences = splitSentences(trimmed)
    if !sentenceCountRange.contains(sentences.count) {
      issues.append(
        "Use 1-2 sentences each for what, why, and how "
          + "(\(sentenceCountRange.lowerBound)-\(sentenceCountRange.upperBound) sentences total; "
          + "found \(sentences.count)).")
    }
    if sentences.contains(where: { wordCount(of: $0) > maximumSentenceWords }) {
      issues.append("Keep every sentence simple (at most \(maximumSentenceWords) words).")
    }
    return issues
  }

  private static func opensWithCommitReference(_ text: String) -> Bool {
    // Matches "c14198d ..." and "Installed c14198d, ..." style openings. The token
    // must contain a digit so plain lowercase words are never flagged.
    let pattern = #"^\s*(?:installed|committed?|at|from|in)\s+([\[\(]?[0-9a-f]{7,40}[\]\)]?)|^\s*([\[\(]?[0-9a-f]{7,40}[\]\)]?)[\s:,-]"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return false
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return false }
    for index in 1...2 {
      guard let tokenRange = Range(match.range(at: index), in: text) else { continue }
      let token = text[tokenRange].trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
      if token.contains(where: { $0.isNumber }) { return true }
    }
    return false
  }

  private static func splitSentences(_ text: String) -> [String] {
    var sentences: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
      if let substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        sentences.append(substring)
      }
    }
    return sentences
  }

  private static func wordCount(of sentence: String) -> Int {
    sentence.split { $0.isWhitespace || $0.isNewline }.count
  }
}
