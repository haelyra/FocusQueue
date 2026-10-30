import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Computer-local task and usage dates")
struct LocalDateTests {
  @Test("Completion timestamps convert across midnight, including fractional and offset timestamps",
        arguments: ["2026-10-30T01:00:00Z", "2026-10-30T01:00:00.123Z", "2026-10-30T10:00:00+09:00"])
  func completionDates(timestamp: String) throws {
    let ticket = DashboardTicket(id: "FOC-1", title: "Done", status: "resolved", summary: "",
                                 completedAt: timestamp)
    #expect(ticket.completionDay(in: try #require(TimeZone(identifier: "America/Los_Angeles"))) == "2026-10-29")
    #expect(ticket.completionDay(in: try #require(TimeZone(identifier: "Asia/Tokyo"))) == "2026-10-30")
    #expect(ticket.completionTimestamp == timestamp)
    let date = try #require(TaskTriagePolicy.date(from: timestamp))
    #expect(ticket.completionDateLabel == date.formatted(Date.FormatStyle(
      date: .abbreviated, time: .shortened, timeZone: .autoupdatingCurrent)))
  }

  @Test("Date-only legacy completions and deadlines preserve their calendar date",
        arguments: ["America/Los_Angeles", "Asia/Tokyo", "Pacific/Kiritimati"])
  func dateOnlyRecords(zoneName: String) throws {
    let zone = try #require(TimeZone(identifier: zoneName))
    let ticket = DashboardTicket(id: "FOC-1", title: "Legacy", status: "resolved", summary: "",
                                 updatedAt: "2026-10-29")
    #expect(ticket.completionDay(in: zone) == "2026-10-29")
    #expect(ticket.completionDateLabel == "2026-10-29")
    let due = try #require(TaskTriagePolicy.date(from: "2026-10-29", timeZone: zone))
    #expect(TaskTriagePolicy.dateOnlyString(for: due, timeZone: zone) == "2026-10-29")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    #expect(calendar.component(.hour, from: due) == 0)
  }

  @Test("A completion late in UTC belongs to the following day east of UTC")
  func nextLocalDay() throws {
    let ticket = DashboardTicket(id: "FOC-1", title: "Done", status: "resolved", summary: "",
                                 completedAt: "2026-10-29T23:30:00Z")
    let zone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    #expect(ticket.completionDay(in: zone) == "2026-10-30")
  }

  @Test("Usage ranges keep consecutive local days across daylight saving changes",
        arguments: ["2026-03-09T01:00:00Z", "2026-11-02T01:00:00Z"])
  func daylightSavingRanges(timestamp: String) throws {
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try Date(timestamp, strategy: .iso8601)
    let days = TokenUsageDay.recent(7, now: now, timeZone: zone)
    #expect(days.count == 7)
    #expect(Set(days).count == 7)
    #expect(days == (timestamp.contains("03-09")
      ? ["2026-03-02", "2026-03-03", "2026-03-04", "2026-03-05", "2026-03-06", "2026-03-07", "2026-03-08"]
      : ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"]))
    #expect(days.last == TokenUsageDay.key(now, timeZone: zone))
    #expect(TokenUsageDay.recent(1, now: now, timeZone: zone) == [TokenUsageDay.key(now, timeZone: zone)])
    #expect(TokenUsageDay.recent(0, now: now, timeZone: zone).isEmpty)
  }

  @Test("Unchanged transcripts regroup when the computer time zone changes",
        arguments: ["claude", "codex"])
  func transcriptCacheTimeZone(provider: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("session.jsonl")
    let line = provider == "claude"
      ? #"{"timestamp":"2026-10-30T01:00:00Z","message":{"id":"msg_one","usage":{"input_tokens":10,"output_tokens":2}}}"#
      : #"{"timestamp":"2026-10-30T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":2},"last_token_usage":{"input_tokens":10,"output_tokens":2}}}}"#
    try Data(line.utf8).write(to: url)
    let westZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let eastZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let west = try #require(AgentTranscriptUsage.usage(of: url, provider: provider,
      timeZone: westZone))
    let east = try #require(AgentTranscriptUsage.usage(of: url, provider: provider,
      timeZone: eastZone))
    #expect(west.daily["2026-10-29"]?.total == 12)
    #expect(east.daily["2026-10-30"]?.total == 12)
    #expect(west.totals == east.totals)
  }
}
