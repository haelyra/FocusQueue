import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Schedule run history")
struct ScheduleRunHistoryTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }

  private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

  private func record(_ id: String, ticket: String?, at scheduled: String,
                      recorded: String? = nil, outcome: ScheduleRunOutcome = .completed) -> ScheduleRunRecord {
    ScheduleRunRecord(id: id, kind: .timer, title: "Run \(id)", detail: "detail \(id)",
                      ticketID: ticket, projectID: ticket == nil ? nil : "fq",
                      scheduledAt: date(scheduled), recordedAt: date(recorded ?? scheduled), outcome: outcome)
  }

  @Test("Outcomes label every past run and map report phases")
  func outcomeBasics() {
    #expect(ScheduleRunOutcome.allCases == [.completed, .interrupted, .failed, .skipped])
    #expect(ScheduleRunOutcome(reportPhase: .completed) == .completed)
    #expect(ScheduleRunOutcome(reportPhase: .failed) == .failed)
    #expect(ScheduleRunOutcome(reportPhase: .interrupted) == .interrupted)
    #expect(ScheduleRunOutcome(reportPhase: .running) == nil)
    #expect(record("a", ticket: "FOC-1", at: "2026-11-18T20:00:00Z").trackID == "FOC-1")
    #expect(record("b", ticket: nil, at: "2026-11-18T20:00:00Z").trackID == ScheduleJob.appTrackID)
  }

  @Test("The store round-trips records and prunes anything older than two days")
  func storeRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ScheduleRunHistoryStore(supportDirectory: directory)
    let now = date("2026-11-19T16:00:00Z")
    let recent = record("recent", ticket: "FOC-1", at: "2026-11-18T16:00:00Z")
    let stale = record("stale", ticket: "FOC-1", at: "2026-11-16T15:00:00Z")
    try store.save([recent, stale], now: now)
    #expect(store.load(now: now).map(\.id) == ["recent"])
    // Two days back exactly is kept.
    let edge = record("edge", ticket: "FOC-1", at: "2026-11-17T16:00:00Z")
    try store.save([recent, edge], now: now)
    #expect(store.load(now: now).map(\.id) == ["edge", "recent"])
    // Recording appends without dropping what another writer saved.
    try store.record(record("extra", ticket: nil, at: "2026-11-19T10:00:00Z"), now: now)
    #expect(store.load(now: now).map(\.id) == ["edge", "recent", "extra"])
  }

  @Test("The store caps the history at its maximum record count")
  func storeCap() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ScheduleRunHistoryStore(supportDirectory: directory)
    let now = date("2026-11-19T16:00:00Z")
    let many = (0 ..< ScheduleRunHistoryStore.maximumRecords + 20).map { index in
      record("r\(index)", ticket: "FOC-1",
             at: ISO8601DateFormatter().string(from: now.addingTimeInterval(TimeInterval(index))))
    }
    try store.save(many, now: now.addingTimeInterval(86_400))
    let loaded = store.load(now: now.addingTimeInterval(86_400))
    #expect(loaded.count == ScheduleRunHistoryStore.maximumRecords)
    // The oldest twenty fall off; the newest survive.
    #expect(loaded.first?.id == "r20" && loaded.last?.id == "r319")
  }

  @Test("History gives finished one-shot jobs a track and respects the project scope")
  func groupsIncludeHistoryOnlyTracks() {
    let records = [
      record("done", ticket: "FOC-9", at: "2026-11-18T20:00:00Z"),
      record("app", ticket: nil, at: "2026-11-18T21:00:00Z", outcome: .interrupted),
    ]
    let groups = ScheduleTimeline.groups(
      jobs: [], history: records, projectID: nil,
      projectNames: ["fq": "Focus Queue"], tickets: ["FOC-9": ScheduleTicketInfo(title: "Sweep", projectID: "fq")])
    #expect(groups.map(\.title) == ["App", "Focus Queue"])
    #expect(groups[1].tracks.map(\.id) == ["FOC-9"])
    #expect(groups[1].tracks[0].subtitle == "Sweep")
    // Scoping to another project keeps app-level records only.
    let scoped = ScheduleTimeline.groups(
      jobs: [], history: records, projectID: "other", projectNames: [:], tickets: [:])
    #expect(scoped.map(\.title) == ["App"])
  }

  @Test("Past scheduled fires yield to recorded history clips with outcomes")
  func clipsMixHistoryAndFuture() {
    let now = date("2026-11-18T16:00:00Z")
    let window = DateInterval(start: date("2026-11-18T12:00:00Z"), duration: 86_400)
    let launch = ScheduledLaunch(id: "loop", fireAt: date("2026-11-18T10:00:00Z"),
                                 repeatIntervalSeconds: 4 * 3_600, ticketID: "FOC-1",
                                 prompt: "Check CI", title: "CI check",
                                 preset: AgentLaunchPreset(provider: .claude))
    let jobs = ScheduleTimeline.jobs(
      launches: [launch], dailyReport: nil, decisions: [],
      automation: DecisionAutomationSettings(autoDecide: false),
      tickets: ["FOC-1": ScheduleTicketInfo(title: "CI", projectID: "fq")], now: now)
    #expect(jobs.count == 1)
    let track = ScheduleTrack(id: "FOC-1", title: "FOC-1", subtitle: "CI", projectID: "fq", jobs: jobs)

    // Without a cutoff, past occurrences draw as usual.
    #expect(ScheduleTimeline.clips(for: track, in: window).map(\.start)
      == [date("2026-11-18T14:00:00Z"), date("2026-11-18T18:00:00Z"),
          date("2026-11-18T22:00:00Z"), date("2026-11-19T02:00:00Z"),
          date("2026-11-19T06:00:00Z"), date("2026-11-19T10:00:00Z")])

    // With the cutoff at now, the past comes only from recorded history.
    let ran = record("ran", ticket: "FOC-1", at: "2026-11-18T14:05:00Z")
    let failed = record("oops", ticket: "FOC-1", at: "2026-11-18T15:00:00Z", outcome: .failed)
    let clips = ScheduleTimeline.clips(for: track, in: window, history: [ran, failed],
                                       pastCutoff: now, calendar: calendar)
    #expect(clips.map(\.start) == [date("2026-11-18T14:05:00Z"), date("2026-11-18T15:00:00Z"),
                                   date("2026-11-18T18:00:00Z"), date("2026-11-18T22:00:00Z"),
                                   date("2026-11-19T02:00:00Z"), date("2026-11-19T06:00:00Z"),
                                   date("2026-11-19T10:00:00Z")])
    #expect(clips.map(\.outcome) == [.completed, .failed, nil, nil, nil, nil, nil])
    // History clips are read-only jobs on the same lane.
    #expect(!clips[0].job.isMovable && clips[0].job.title == "Run ran")
    guard case .runRecord(let id) = clips[0].job.source else {
      Issue.record("Expected a run record source, got \(clips[0].job.source)")
      return
    }
    #expect(id == "ran")
    // Records outside the window are ignored.
    #expect(!clips.contains { $0.job.id == "run:elsewhere" })
  }
}
