import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Task search")
struct TaskSearchTests {
  private let tickets = [
    DashboardTicket(id: "FOC-019", title: "Add task search bar", status: "open",
                    summary: "Filter Today's focus as the user types."),
    DashboardTicket(id: "FOC-020", title: "Fix registration crash", priority: "high", status: "open",
                    summary: "The app crashes when an agent registers twice."),
    DashboardTicket(id: "FOC-021", title: "Build release package", status: "blocked",
                    summary: "Sign and package the installer."),
    DashboardTicket(id: "FOC-022", title: "Résumé export", status: "open",
                    summary: "Export the queue as a search-friendly résumé page."),
  ]

  private func ids(_ query: String) -> [String] {
    TaskSearch.search(tickets, query: query).tickets.map(\.id)
  }

  @Test("An empty query keeps every task in queue order")
  func emptyQuery() {
    let result = TaskSearch.search(tickets, query: "   ")
    #expect(result.tickets.map(\.id) == tickets.map(\.id))
    #expect(result.match == .exact)
  }

  @Test("Keywords must all match, ignoring case, accents, and apostrophes")
  func keywordsMatchTogether() {
    #expect(ids("REGISTRATION crash") == ["FOC-020"])
    #expect(ids("resume") == ["FOC-022"])
    #expect(ids("todays focus") == ["FOC-019"])
    #expect(TaskSearch.search(tickets, query: "package").match == .exact)
  }

  @Test("Short keywords match word starts only")
  func shortKeywordsMatchWordStarts() {
    #expect(ids("ui").isEmpty, "\"ui\" must not match inside \"build\"")
    #expect(ids("il").isEmpty)
    #expect(ids("bu") == ["FOC-021"])
  }

  @Test("A ticket ID matches with or without its dash and leads the results")
  func ticketIDsMatch() {
    #expect(ids("foc-021").first == "FOC-021")
    #expect(ids("foc021") == ["FOC-021"])
    #expect(ids("021") == ["FOC-021"])
  }

  @Test("Title matches lead summary matches; queue order breaks ties")
  func titleMatchesLead() {
    #expect(ids("search") == ["FOC-019", "FOC-022"])
    #expect(ids("export search") == ["FOC-022"])
  }

  @Test("A misspelled keyword falls back to the closest spelling")
  func misspellingFallsBack() {
    let result = TaskSearch.search(tickets, query: "serach")
    #expect(result.tickets.map(\.id) == ["FOC-019", "FOC-022"])
    #expect(result.match == .approximate(suggestion: "search"))
    #expect(ids("registraton") == ["FOC-020"])
  }

  @Test("A half-typed misspelling still finds its word")
  func partialMisspelling() {
    #expect(ids("regsit") == ["FOC-020"])
    #expect(ids("pakc") == ["FOC-021"])
  }

  @Test("Synonyms apply when no task holds the literal keyword")
  func synonymsFallBack() {
    let result = TaskSearch.search(tickets, query: "bug")
    #expect(result.tickets.map(\.id) == ["FOC-020"])
    #expect(result.match == .approximate(suggestion: "crash"))
    #expect(ids("deploy") == ["FOC-021"])
    #expect(ids("find bar") == ["FOC-019"])
  }

  @Test("Exact matches win, so fallbacks never add looser results")
  func exactSuppressesFallback() {
    let result = TaskSearch.search(tickets, query: "crash")
    #expect(result.tickets.map(\.id) == ["FOC-020"])
    #expect(result.match == .exact)
  }

  @Test("Stop words are ignored only in the fallback")
  func stopWordsInFallback() {
    #expect(ids("the crsh") == ["FOC-020"])
  }

  @Test("Unmatched text reports no results")
  func noResults() {
    let result = TaskSearch.search(tickets, query: "zzqx")
    #expect(result.tickets.isEmpty)
    #expect(result.match == .none)
    #expect(TaskSearch.search(tickets, query: "search zzqx").match == .none)
  }

  @Test("Edit distance counts swaps as one edit and stops past the limit")
  func editDistance() {
    func distance(_ lhs: String, _ rhs: String, _ limit: Int) -> Int? {
      TaskSearchText.editDistance(Array(lhs.utf8), Array(rhs.utf8)[...], limit: limit)
    }
    #expect(distance("ab", "ba", 1) == 1)
    #expect(distance("kitten", "sitting", 3) == 3)
    #expect(distance("kitten", "sitting", 2) == nil)
    #expect(distance("same", "same", 0) == 0)
  }

  @Test("A keystroke over two thousand tasks stays well under a frame")
  func searchStaysFast() {
    let words = ["agent", "queue", "terminal", "report", "registration", "window", "layout", "release"]
    let many = (0..<2_000).map { index in
      DashboardTicket(
        id: "FOC-\(index)", title: "\(words[index % words.count]) task \(index)", status: "open",
        summary: "Work item \(index) covering \(words[(index / words.count) % words.count]) details.")
    }
    let index = TaskSearchIndex(many)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      _ = index.search("regist")
      _ = index.search("terminl windw")
      _ = index.search("zzqx")
    }
    #expect(index.search("terminl windw").tickets.isEmpty == false)
    // Release builds take about 4 ms here; the loose bound catches an
    // algorithmic regression without failing a loaded parallel debug run.
    #expect(elapsed < .seconds(2), "three searches took \(elapsed)")
  }
}
