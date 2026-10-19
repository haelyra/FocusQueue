import Foundation

/// How a task search matched its query.
public enum TaskSearchMatch: Equatable, Sendable {
  /// Every keyword appears in each returned task.
  case exact
  /// No task held every keyword, so spelling corrections and synonyms were
  /// applied. `suggestion` is the corrected query when a keyword changed.
  case approximate(suggestion: String?)
  case none
}

/// A query term that narrows by a task field instead of matching text.
public struct TaskSearchFilter: Equatable, Sendable {
  public enum Field: String, Sendable { case status, priority }
  public let field: Field
  /// The value as typed, compacted: "in-progress" is "inprogress".
  public let value: String
  /// The value as typed, lowercased, for display.
  public let label: String

  public init(field: Field, value: String, label: String? = nil) {
    self.field = field
    self.value = value
    self.label = label ?? value
  }
}

public struct TaskSearchResult: Equatable, Sendable {
  public let tickets: [DashboardTicket]
  public let match: TaskSearchMatch
  public let filters: [TaskSearchFilter]

  public init(tickets: [DashboardTicket], match: TaskSearchMatch, filters: [TaskSearchFilter] = []) {
    self.tickets = tickets
    self.match = match
    self.filters = filters
  }
}

/// Filters tasks while the user types. Keywords match first; only when no
/// task holds every keyword does the search retry with close spellings and
/// synonyms, so ordinary typing stays a cheap substring scan.
///
/// A word that is exactly a status or priority ("blocked", "high") filters by
/// that field, as do `status:`/`is:` and `priority:`/`p:` with a partial value.
/// Values of one field are alternatives; different fields must all hold.
public struct TaskSearchIndex: Sendable {
  /// Text is kept as UTF-8 bytes: byte scans are several times faster than
  /// `String.contains` and stay correct because UTF-8 never matches mid-character.
  private struct Entry: Sendable {
    let ticket: DashboardTicket
    /// Every spelling of the task code: "foc018", "foc18", "018", and "18".
    let idForms: Set<String>
    let status: String
    let priority: String
    let title: [UInt8]
    let text: [UInt8]
    let words: Set<String>
  }

  private let entries: [Entry]
  private let vocabulary: [String]
  private let vocabularyBytes: [[UInt8]]
  private let statuses: Set<String>
  private let priorities: Set<String>

  public init(_ tickets: [DashboardTicket]) {
    var vocabulary = Set<String>()
    entries = tickets.map { ticket in
      let id = TaskSearchText.normalized(ticket.id)
      let idForms = TaskSearchText.codeForms(TaskSearchText.words(in: id))
      let title = TaskSearchText.normalized(ticket.title)
      let fields = [ticket.summary, ticket.next, ticket.doneWhen, ticket.category, ticket.taskType,
        ticket.status, ticket.priority].compactMap { $0 }.map(TaskSearchText.normalized)
      let text = ([id] + idForms.sorted() + [title] + fields).joined(separator: " ")
      let words = Set(TaskSearchText.words(in: text))
      vocabulary.formUnion(words)
      return Entry(ticket: ticket, idForms: idForms,
        status: TaskSearchText.compact(ticket.status), priority: TaskSearchText.compact(ticket.priority),
        title: Array(title.utf8), text: Array(text.utf8), words: words)
    }
    self.vocabulary = vocabulary.sorted()
    vocabularyBytes = self.vocabulary.map { Array($0.utf8) }
    statuses = Set(entries.map(\.status).filter { !$0.isEmpty })
    priorities = Set(entries.map(\.priority).filter { !$0.isEmpty }).union(TaskSearchText.priorityNames)
  }

  public func search(_ query: String) -> TaskSearchResult {
    let (filters, text) = parse(query)
    let pool = filters.isEmpty ? entries : entries.filter { Self.passes($0, filters) }
    let tokens = TaskSearchText.words(in: TaskSearchText.normalized(text))
    guard !tokens.isEmpty else {
      return TaskSearchResult(tickets: pool.map(\.ticket),
        match: pool.isEmpty && !filters.isEmpty ? .none : .exact, filters: filters)
    }

    // A full code such as "FOC-18" names one task, so loose word matches
    // ("foc" inside "focus") stay out. A bare number, or a partly typed code
    // such as "FOC-01", still searches broadly.
    let code = tokens.joined()
    if code.contains(where: \.isLetter), code.contains(where: \.isNumber) {
      let named = pool.filter { $0.idForms.contains(code) }
      if !named.isEmpty { return TaskSearchResult(tickets: named.map(\.ticket), match: .exact, filters: filters) }
    }

    let tokenBytes = tokens.map { Array($0.utf8) }
    let exact = pool.filter { entry in tokenBytes.allSatisfy { Self.contains($0, in: entry) } }
    if !exact.isEmpty {
      return TaskSearchResult(tickets: Self.ranked(exact, tokens: tokens, tokenBytes: tokenBytes),
        match: .exact, filters: filters)
    }
    return approximateSearch(tokens, in: pool, filters: filters)
  }

  /// Splits field filters from the text keywords. A qualifier without a value
  /// yet ("status:") is dropped so typing it does not search for "status".
  private func parse(_ query: String) -> (filters: [TaskSearchFilter], text: String) {
    var filters: [TaskSearchFilter] = []
    var text: [Substring] = []
    for term in query.split(whereSeparator: \.isWhitespace) {
      let normalized = TaskSearchText.normalized(String(term))
      if let colon = normalized.firstIndex(of: ":"),
         let field = TaskSearchText.qualifiers[String(normalized[..<colon])] {
        let typed = String(normalized[normalized.index(after: colon)...])
        let value = TaskSearchText.compact(typed)
        if !value.isEmpty { filters.append(TaskSearchFilter(field: field, value: value, label: typed)) }
        continue
      }
      let compact = TaskSearchText.compact(normalized)
      if priorities.contains(compact) {
        filters.append(TaskSearchFilter(field: .priority, value: compact, label: normalized))
      } else if statuses.contains(compact) {
        filters.append(TaskSearchFilter(field: .status, value: compact, label: normalized))
      } else {
        text.append(term)
      }
    }
    return (filters, text.joined(separator: " "))
  }

  private static func passes(_ entry: Entry, _ filters: [TaskSearchFilter]) -> Bool {
    func holds(_ field: TaskSearchFilter.Field) -> Bool {
      let values = filters.filter { $0.field == field }.map(\.value)
      guard !values.isEmpty else { return true }
      return values.contains { value in
        switch field {
        case .priority: return entry.priority.hasPrefix(value)
        case .status:
          if TaskSearchText.openStatusNames.contains(value) { return entry.ticket.isOpen }
          if TaskSearchText.closedStatusNames.contains(value) { return entry.ticket.isCompleted }
          return entry.status.hasPrefix(value)
        }
      }
    }
    return holds(.status) && holds(.priority)
  }

  /// Short keywords match the start of a word so "ui" does not match "build";
  /// longer keywords match anywhere, which also finds "queue" in "focusqueue".
  private static func contains(_ token: [UInt8], in entry: Entry) -> Bool {
    if token.count <= 2 { return entry.words.contains { $0.utf8.starts(with: token) } }
    return TaskSearchText.bytes(entry.text, contain: token)
  }

  private static func wordMatches(_ token: [UInt8], _ word: [UInt8]) -> Bool {
    token.count <= 2 ? word.starts(with: token) : TaskSearchText.bytes(word, contain: token)
  }

  /// ID matches lead, then title matches; queue order breaks ties.
  private static func ranked(_ entries: [Entry], tokens: [String], tokenBytes: [[UInt8]]) -> [DashboardTicket] {
    let queryCodes = TaskSearchText.codeForms(tokens)
    func rank(_ entry: Entry) -> Int {
      if !entry.idForms.isDisjoint(with: queryCodes) { return 0 }
      if tokenBytes.allSatisfy({ TaskSearchText.bytes(entry.title, contain: $0) }) { return 1 }
      return 2
    }
    return entries.enumerated()
      .sorted { lhs, rhs in
        let left = rank(lhs.element), right = rank(rhs.element)
        return left == right ? lhs.offset < rhs.offset : left < right
      }
      .map(\.element.ticket)
  }

  private func approximateSearch(
    _ allTokens: [String], in pool: [Entry], filters: [TaskSearchFilter]
  ) -> TaskSearchResult {
    let none = TaskSearchResult(tickets: [], match: .none, filters: filters)
    let tokens = allTokens.filter { !TaskSearchText.stopWords.contains($0) }
    guard !tokens.isEmpty else { return none }

    var alternatives: [Set<String>] = []
    var corrected: [String] = []
    for token in tokens {
      let candidates = alternativeWords(for: token)
      guard !candidates.words.isEmpty else { return none }
      alternatives.append(candidates.words)
      corrected.append(candidates.correction ?? token)
    }

    let matches = pool.filter { entry in
      alternatives.allSatisfy { !entry.words.isDisjoint(with: $0) }
    }
    guard !matches.isEmpty else { return none }
    let suggestion = corrected.joined(separator: " ")
    return TaskSearchResult(
      tickets: matches.map(\.ticket),
      match: .approximate(suggestion: suggestion == allTokens.joined(separator: " ") ? nil : suggestion),
      filters: filters)
  }

  /// Every indexed word that could stand in for `token`: literal matches and
  /// synonyms, plus close spellings when nothing matches literally. The
  /// correction is the closest spelling, or else the first synonym present.
  private func alternativeWords(for token: String) -> (words: Set<String>, correction: String?) {
    let typed = Array(token.utf8)
    var words = Set<String>()
    for (word, bytes) in zip(vocabulary, vocabularyBytes) where Self.wordMatches(typed, bytes) {
      words.insert(word)
    }
    let hasLiteral = !words.isEmpty

    let synonyms = TaskSearchText.synonyms(for: token)
    var synonymCorrection: String?
    for word in vocabulary where synonyms.contains(where: { word.hasPrefix($0) }) {
      words.insert(word)
      if synonymCorrection == nil, synonyms.contains(word) { synonymCorrection = word }
    }

    if hasLiteral { return (words, nil) }
    // A dictionary word is spelled correctly, so only its synonyms apply.
    if TaskSearchText.isKnownWord(token) { return (words, synonymCorrection) }
    var bestSpelling: (word: String, distance: Int)?
    if let limit = TaskSearchText.spellingLimit(for: token) {
      for (word, bytes) in zip(vocabulary, vocabularyBytes) {
        guard let distance = TaskSearchText.prefixDistance(typed, bytes, limit: limit) else { continue }
        words.insert(word)
        if bestSpelling.map({ distance < $0.distance || (distance == $0.distance && word.count < $0.word.count) })
          ?? true {
          bestSpelling = (word, distance)
        }
      }
    }
    return (words, bestSpelling?.word ?? synonymCorrection)
  }
}

public enum TaskSearch {
  public static func search(_ tickets: [DashboardTicket], query: String) -> TaskSearchResult {
    TaskSearchIndex(tickets).search(query)
  }
}

enum TaskSearchText {
  static func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .lowercased()
      .replacingOccurrences(of: "'", with: "")
      .replacingOccurrences(of: "\u{2019}", with: "")
  }

  static func words(in normalizedText: String) -> [String] {
    normalizedText.split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  /// Letters and digits only, so "In-Progress" and "in progress" agree.
  static func compact(_ text: String) -> String {
    words(in: normalized(text)).joined()
  }

  /// A code matches with or without its prefix, dash, or leading zeros:
  /// "foc 018" yields "foc018", "foc18", "018", and "18".
  static func codeForms(_ words: [String]) -> Set<String> {
    guard let number = words.last, number.allSatisfy(\.isNumber) else { return [words.joined()] }
    let trimmed = number.drop { $0 == "0" }
    let stripped = trimmed.isEmpty ? "0" : String(trimmed)
    let prefix = words.dropLast().joined()
    return [prefix + number, prefix + stripped, number, stripped]
  }

  static let priorityNames: Set<String> = ["critical", "high", "medium", "low"]
  static let openStatusNames: Set<String> = ["open", "active"]
  static let closedStatusNames: Set<String> = ["done", "closed", "completed", "complete"]
  static let qualifiers: [String: TaskSearchFilter.Field] = [
    "status": .status, "is": .status, "priority": .priority, "p": .priority,
  ]

  static let stopWords: Set<String> = [
    "a", "an", "and", "the", "to", "for", "of", "in", "on", "with", "is", "it", "at", "by", "or",
  ]

  /// Task-tracking vocabulary. A word may sit in more than one group.
  private static let synonymGroups: [[String]] = [
    ["bug", "fix", "issue", "error", "defect", "broken", "crash", "regression", "problem", "fail", "failure"],
    ["ui", "view", "layout", "interface", "screen", "panel", "display", "visual", "design"],
    ["test", "qa", "verify", "check", "validate", "validation", "sanity"],
    ["doc", "docs", "documentation", "readme", "guide", "notes", "manual"],
    ["perf", "performance", "speed", "slow", "fast", "lag", "latency", "optimize", "responsiveness"],
    ["search", "find", "filter", "query", "lookup"],
    ["delete", "remove", "clear", "clean", "cleanup", "purge", "archive"],
    ["add", "create", "new", "make", "build", "implement"],
    ["update", "change", "edit", "modify", "rename", "refresh"],
    ["agent", "session", "worker", "provider"],
    ["task", "ticket", "item", "todo", "job"],
    ["setting", "settings", "config", "configuration", "preference", "preferences", "option", "options"],
    ["notification", "alert", "attention", "badge", "banner"],
    ["launch", "start", "open", "run", "spawn"],
    ["install", "deploy", "release", "ship", "publish", "package"],
    ["terminal", "tmux", "shell", "pane", "console", "wezterm"],
    ["report", "summary", "digest", "brief", "recap"],
    ["project", "repo", "repository", "workspace", "worktree"],
    ["plan", "roadmap", "outline", "spec"],
    ["auth", "login", "signin", "credential", "credentials", "token"],
    ["mail", "email", "gmail", "inbox"],
    ["chat", "conversation", "message", "messages", "slack", "discord"],
    ["map", "graph", "diagram", "canvas"],
    ["queue", "order", "priority", "focus"],
  ]

  private static let synonymsByWord: [String: Set<String>] = {
    var map: [String: Set<String>] = [:]
    for group in synonymGroups {
      for word in group { map[word, default: []].formUnion(group.filter { $0 != word }) }
    }
    return map
  }()

  /// The word and its plain stems: "crashes" also reads as "crash".
  private static func forms(of token: String) -> Set<String> {
    var forms: Set<String> = [token]
    for suffix in ["ing", "es", "ed", "s"] where token.hasSuffix(suffix) && token.count - suffix.count >= 3 {
      forms.insert(String(token.dropLast(suffix.count)))
    }
    return forms
  }

  static func isKnownWord(_ token: String) -> Bool {
    forms(of: token).contains { synonymsByWord[$0] != nil }
  }

  /// Synonyms of the word, its plain stem, or a group word it begins once
  /// four letters are typed, so suggestions follow partial typing.
  static func synonyms(for token: String) -> Set<String> {
    var result = Set<String>()
    for form in forms(of: token) { result.formUnion(synonymsByWord[form] ?? []) }
    if token.count >= 4 {
      for (word, group) in synonymsByWord where word.count > token.count && word.hasPrefix(token) {
        result.insert(word)
        result.formUnion(group)
      }
    }
    return result
  }

  /// Edits allowed for a keyword; keywords under three letters need exact text.
  static func spellingLimit(for token: String) -> Int? {
    switch token.count {
    case ..<3: nil
    case ..<8: 1
    default: 2
    }
  }

  /// Edit distance between the keyword and the word or a same-length prefix of
  /// it, so a half-typed misspelling still finds its word. Three-letter
  /// keywords compare whole words: one edit to a prefix is too loose there.
  /// Nil past `limit`.
  static func prefixDistance(_ typed: [UInt8], _ candidate: [UInt8], limit: Int) -> Int? {
    let shortestPrefix = typed.count <= 4 ? typed.count : typed.count - 1
    let longestPrefix = typed.count <= 3 ? 0 : min(typed.count + 1, candidate.count - 1)
    var best: Int?
    func consider(_ length: Int) {
      guard length > 0, abs(length - typed.count) <= limit,
        let distance = editDistance(typed, candidate[..<length], limit: limit) else { return }
      best = min(best ?? distance, distance)
    }
    if longestPrefix >= shortestPrefix {
      for length in shortestPrefix...longestPrefix { consider(length) }
    }
    consider(candidate.count)
    return best
  }

  static func bytes(_ haystack: [UInt8], contain needle: [UInt8]) -> Bool {
    guard !needle.isEmpty else { return true }
    guard haystack.count >= needle.count else { return false }
    let first = needle[0]
    var start = 0
    let last = haystack.count - needle.count
    while start <= last {
      if haystack[start] == first {
        var offset = 1
        while offset < needle.count, haystack[start + offset] == needle[offset] { offset += 1 }
        if offset == needle.count { return true }
      }
      start += 1
    }
    return false
  }

  /// Optimal string alignment distance (adjacent swaps count as one edit),
  /// abandoned as soon as every path exceeds `limit`.
  static func editDistance(_ lhs: [UInt8], _ rhs: ArraySlice<UInt8>, limit: Int) -> Int? {
    if abs(lhs.count - rhs.count) > limit { return nil }
    if lhs.isEmpty || rhs.isEmpty { return max(lhs.count, rhs.count) }
    let base = rhs.startIndex
    var previousPrevious = [Int](repeating: 0, count: rhs.count + 1)
    var previous = Array(0...rhs.count)
    var current = [Int](repeating: 0, count: rhs.count + 1)
    for i in 1...lhs.count {
      current[0] = i
      var rowMinimum = i
      for j in 1...rhs.count {
        let cost = lhs[i - 1] == rhs[base + j - 1] ? 0 : 1
        var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        if i > 1, j > 1, lhs[i - 1] == rhs[base + j - 2], lhs[i - 2] == rhs[base + j - 1] {
          value = min(value, previousPrevious[j - 2] + 1)
        }
        current[j] = value
        rowMinimum = min(rowMinimum, value)
      }
      if rowMinimum > limit { return nil }
      (previousPrevious, previous, current) = (previous, current, previousPrevious)
    }
    let distance = previous[rhs.count]
    return distance <= limit ? distance : nil
  }
}
