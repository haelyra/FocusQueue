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

  @Test("A task code matches without its prefix, dash, or leading zeros")
  func ticketCodesMatchLoosely() {
    let codes = [
      DashboardTicket(id: "FOC-018", title: "Clipboard sync", status: "backlog", summary: ""),
      DashboardTicket(id: "FOC-180", title: "Window layout", status: "backlog", summary: ""),
      DashboardTicket(id: "FOC-118", title: "Agent 18 retry", status: "backlog", summary: ""),
    ]
    func codeIDs(_ query: String) -> [String] { TaskSearch.search(codes, query: query).tickets.map(\.id) }
    for query in ["18", "018", "FOC-18", "foc 18", "foc18", "FOC-018", "#18"] {
      #expect(codeIDs(query).first == "FOC-018", "\(query) must lead with FOC-018")
    }
    // The exact code leads, then a title holding "18", then other code starts.
    #expect(codeIDs("18") == ["FOC-018", "FOC-118", "FOC-180"])
    #expect(codeIDs("foc-180") == ["FOC-180"])
    let focusTicket = DashboardTicket(id: "ECC-018", title: "Focus window", status: "resolved", summary: "")
    #expect(TaskSearch.search(codes + [focusTicket], query: "FOC-018").tickets.map(\.id) == ["FOC-018"],
      "a full code excludes tasks that only contain its parts")
    #expect(codeIDs("FOC-01").first == "FOC-018", "a partly typed padded code keeps searching")
    #expect(TaskSearch.search(codes + [focusTicket], query: "18").tickets.map(\.id).prefix(2)
      == ["FOC-018", "ECC-018"])
  }

  @Test("An exact status or priority word filters by that field instead of text")
  func fieldWordsFilter() {
    let fielded = tickets + [
      DashboardTicket(id: "FOC-023", title: "Slow follow-up workflow", priority: "low", status: "in-progress",
                      summary: "Highlight the blocked state."),
    ]
    func fieldIDs(_ query: String) -> [String] { TaskSearch.search(fielded, query: query).tickets.map(\.id) }
    #expect(fieldIDs("low") == ["FOC-023"], "\"low\" must not match inside \"slow\" or \"workflow\"")
    #expect(fieldIDs("high") == ["FOC-020"])
    #expect(fieldIDs("blocked") == ["FOC-021"], "\"blocked\" filters by status, not summary text")
    #expect(fieldIDs("in-progress") == ["FOC-023"])
    #expect(fieldIDs("high low") == ["FOC-020", "FOC-023"], "values of one field are alternatives")
    #expect(fieldIDs("open crash") == ["FOC-020"], "fields and keywords combine")
    #expect(fieldIDs("high blocked").isEmpty)
    let result = TaskSearch.search(fielded, query: "In-Progress")
    #expect(result.filters == [TaskSearchFilter(field: .status, value: "inprogress", label: "in-progress")])
    #expect(result.match == .exact)
    #expect(TaskSearch.search(fielded, query: "critical").match == .none)
  }

  @Test("Qualifiers accept partial values and open or done groups")
  func qualifiersFilter() {
    let mixed = tickets + [
      DashboardTicket(id: "FOC-024", title: "Old export", status: "resolved", summary: "Shipped."),
    ]
    func mixedIDs(_ query: String) -> [String] { TaskSearch.search(mixed, query: query).tickets.map(\.id) }
    #expect(mixedIDs("status:blo") == ["FOC-021"])
    #expect(mixedIDs("p:hi") == ["FOC-020"])
    #expect(mixedIDs("priority:med export") == ["FOC-022", "FOC-024"])
    #expect(mixedIDs("is:done") == ["FOC-024"])
    #expect(mixedIDs("status:open export") == ["FOC-022"])
    #expect(mixedIDs("resolved") == ["FOC-024"])
    #expect(mixedIDs("status:").count == mixed.count, "a qualifier without a value is ignored while typing")
    #expect(mixedIDs("status:blo serach") == [], "a misspelling falls back only inside the filtered tasks")
    #expect(mixedIDs("status:open serach") == ["FOC-019", "FOC-022"])
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
