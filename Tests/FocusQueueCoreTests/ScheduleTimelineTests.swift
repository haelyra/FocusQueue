import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Schedule timeline")
struct ScheduleTimelineTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }

  private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

  private func launch(_ id: String, ticket: String, at fire: String, every: TimeInterval? = nil) -> ScheduledLaunch {
    ScheduledLaunch(id: id, fireAt: date(fire), repeatIntervalSeconds: every, ticketID: ticket,
                    prompt: "Do \(id)", title: "Job \(id)", preset: AgentLaunchPreset(provider: .claude))
  }

  private func decisionTree(task: String, created: String) -> DecisionTree {
    var tree = DecisionTree(taskID: task, agentID: "A1", agentTitle: nil, provider: nil, now: created)
    tree.nodes = [DecisionNode(id: "D1", parentID: nil, parentOptionID: nil, title: "Pick layout",
                               divergence: .taskPlan, detail: nil,
                               options: [DecisionOption(id: "a", label: "Grid"), DecisionOption(id: "b", label: "List")],
                               createdAt: created)]
    return tree
  }

  private func sampleJobs(now: Date) -> [ScheduleJob] {
    var report = DailyReportConfiguration()
    report.enabled = true
    report.scheduleHour = 8
    report.scheduleMinute = 30
    return ScheduleTimeline.jobs(
      launches: [launch("t", ticket: "FOC-1", at: "2026-11-18T20:00:00Z"),
                 launch("r", ticket: "ABC-2", at: "2026-11-18T18:00:00Z", every: 6 * 3_600)],
      dailyReport: report,
      decisions: [decisionTree(task: "FOC-1", created: "2026-11-18T17:00:00.000Z")],
      automation: DecisionAutomationSettings(autoDecide: true, autoDecideMinutes: 90),
      tickets: ["FOC-1": ScheduleTicketInfo(title: "Timeline", projectID: "fq")],
      projectForTicket: { $0.hasPrefix("ABC-") ? "abc" : nil },
      now: now, calendar: calendar)
  }

  @Test("Collects launches, the daily report, and pending decisions with their kinds")
  func collectsJobs() {
    let jobs = sampleJobs(now: date("2026-11-18T16:00:00Z"))
    #expect(jobs.map(\.kind) == [.timer, .interval, .cron, .autoDecide])
    #expect(jobs[0].projectID == "fq" && jobs[1].projectID == "abc")
    #expect(jobs[2].ticketID == nil && jobs[2].trackID == ScheduleJob.appTrackID)
    // The decision settles 90 minutes after it was raised and cannot be dragged.
    #expect(jobs[3].anchor == date("2026-11-18T18:30:00Z") && !jobs[3].isMovable)
    // A disabled report and auto-decide produce nothing.
    let quiet = ScheduleTimeline.jobs(
      launches: [], dailyReport: DailyReportConfiguration(),
      decisions: [decisionTree(task: "FOC-1", created: "2026-11-18T17:00:00.000Z")],
      automation: DecisionAutomationSettings(autoDecide: false), tickets: [:])
    #expect(quiet.isEmpty)
  }

  @Test("Projects a pending existing-agent resume with explicit action and target labels")
  func existingAgentResumeLabel() throws {
    let fireAt = date("2026-11-18T20:00:00Z")
    let runtime = TmuxSessionReference(
      name: "fq-task-foc-1", serverPID: 1, createdAt: 2,
      paneID: "%3", panePID: 4, tty: "/dev/ttys003", executable: "/opt/homebrew/bin/tmux")
    let resume = ScheduledAgentResume(
      id: "resume-1", fireAt: fireAt, expiresAt: fireAt.addingTimeInterval(900),
      title: "Continue scheduler", prompt: "Continue the existing queue.",
      target: ScheduledAgentResumeTarget(
        taskID: "FOC-1", agentID: "agent-7", provider: .codex,
        sessionID: "11111111-2222-4333-8444-555555555555",
        workspacePath: "/tmp/foc-1", runtime: runtime))
    let jobs = ScheduleTimeline.jobs(
      launches: [], resumes: [resume], dailyReport: nil, decisions: [],
      automation: DecisionAutomationSettings(autoDecide: false),
      tickets: ["FOC-1": ScheduleTicketInfo(title: "Scheduler", projectID: "fq")])
    let job = try #require(jobs.first)
    #expect(job.source == .scheduledResume(id: "resume-1"))
    #expect(job.actionLabel == "Resume existing agent")
    #expect(job.targetLabel?.contains("agent-7") == true)
    #expect(job.targetLabel?.contains("11111111-2222-4333-8444-555555555555") == true)
    #expect(job.projectID == "fq" && job.trackID == "FOC-1" && job.isMovable)

    var terminal = resume
    terminal.state = .failed
    #expect(ScheduleTimeline.jobs(
      launches: [], resumes: [terminal], dailyReport: nil, decisions: [],
      automation: DecisionAutomationSettings(autoDecide: false), tickets: [:]).isEmpty)
  }

  @Test("Groups tracks by task under each project and filters by scope")
  func groupsTracks() {
    let jobs = sampleJobs(now: date("2026-11-18T16:00:00Z"))
    let names = ["fq": "Focus Queue", "abc": "Alpha"]
    let tickets = ["FOC-1": ScheduleTicketInfo(title: "Timeline", projectID: "fq")]
    let all = ScheduleTimeline.groups(jobs: jobs, projectID: nil, projectNames: names, tickets: tickets)
    #expect(all.map(\.title) == ["App", "Alpha", "Focus Queue"])
    let fq = all[2].tracks
    #expect(fq.map(\.id) == ["FOC-1"] && fq[0].subtitle == "Timeline")
    #expect(fq[0].jobs.map(\.kind) == [.autoDecide, .timer])
    // One project keeps app-wide jobs and drops other projects.
    let scoped = ScheduleTimeline.groups(jobs: jobs, projectID: "fq", projectNames: names, tickets: tickets)
    #expect(scoped.map(\.title) == ["App", "Focus Queue"])
  }

  @Test("Expands repeats and daily jobs inside the window, following the wall clock across DST")
  func expandsOccurrences() {
    let now = date("2026-11-18T16:00:00Z")
    let jobs = sampleJobs(now: now)
    let window = DateInterval(start: date("2026-11-18T14:00:00Z"), duration: 86_400)
    #expect(ScheduleTimeline.occurrences(of: jobs[0], in: window) == [date("2026-11-18T20:00:00Z")])
    #expect(ScheduleTimeline.occurrences(of: jobs[1], in: window).count == 4)
    // 08:30 New York is 13:30 UTC; the window starts at 14:00, so tomorrow's run is the only one.
    #expect(ScheduleTimeline.occurrences(of: jobs[2], in: window, calendar: calendar) == [date("2026-11-19T13:30:00Z")])
    // Across the November DST change the daily run stays at 08:30 local.
    var report = jobs[2]
    report.anchor = date("2026-10-30T12:30:00Z")
    let dst = DateInterval(start: date("2026-10-30T04:00:00Z"), duration: 4 * 86_400)
    let runs = ScheduleTimeline.occurrences(of: report, in: dst, calendar: calendar)
    #expect(runs.map { calendar.component(.hour, from: $0) } == [8, 8, 8, 8])
    #expect(runs.last == date("2026-11-02T13:30:00Z"))
  }

  @Test("Clip slots end at the lane's next fire; bars span only the expected run")
  func clipsDoNotOverlap() {
    let jobs = sampleJobs(now: date("2026-11-18T16:00:00Z"))
    let window = DateInterval(start: date("2026-11-18T14:00:00Z"), duration: 86_400)
    let track = ScheduleTrack(id: "FOC-1", title: "FOC-1", subtitle: "", projectID: "fq", jobs: [jobs[3], jobs[0]])
    let clips = ScheduleTimeline.clips(for: track, in: window)
    #expect(clips.map(\.start) == [date("2026-11-18T18:30:00Z"), date("2026-11-18T20:00:00Z")])
    #expect(clips[0].end == clips[1].start)
    #expect(clips[1].end == window.end)
    // Bars span the expected run, not the slot: decisions are instant, launches about 30 minutes.
    #expect(clips[0].runEnd == clips[0].start)
    #expect(clips[1].runEnd == date("2026-11-18T20:30:00Z"))
    #expect(jobs[2].expectedDuration == ScheduleJob.estimatedDailyReportRun)
    #expect(clips.allSatisfy { $0.row == 0 })
    // Fires closer than the minimum gap stack into a second row instead of overlapping.
    var twin = jobs[0]
    twin.source = .scheduledLaunch(id: "twin")
    twin.anchor = date("2026-11-18T20:10:00Z")
    let crowded = ScheduleTrack(id: "FOC-1", title: "FOC-1", subtitle: "", projectID: "fq", jobs: [jobs[0], twin, jobs[3]])
    let stacked = ScheduleTimeline.clips(for: crowded, in: window, minimumGap: 30 * 60)
    #expect(stacked.map(\.row) == [0, 0, 1])
    #expect(stacked[0].end == stacked[1].start && stacked[2].end == window.end)
  }

  @Test("Drags snap, shift repeating series, and never land in the past")
  func dragMath() {
    let now = date("2026-11-18T16:00:00Z")
    let jobs = sampleJobs(now: now)
    // Timer: 20:00 dragged to 21:07 snaps to 21:00 at 15-minute resolution.
    #expect(ScheduleTimeline.movedFireDate(of: jobs[0], from: jobs[0].anchor, to: date("2026-11-18T21:07:00Z"),
                                           snapMinutes: 15, now: now, calendar: calendar) == date("2026-11-18T21:00:00Z"))
    // Timer dragged before now clamps to now.
    #expect(ScheduleTimeline.movedFireDate(of: jobs[0], from: jobs[0].anchor, to: date("2026-11-18T10:00:00Z"),
                                           snapMinutes: 15, now: now, calendar: calendar) == now)
    // Repeat: dragging its third run (06:00 next day) one hour later shifts the series to 19:00.
    #expect(ScheduleTimeline.movedFireDate(of: jobs[1], from: date("2026-11-19T06:00:00Z"), to: date("2026-11-19T07:00:00Z"),
                                           snapMinutes: 15, now: now, calendar: calendar) == date("2026-11-18T19:00:00Z"))
    // Repeat dragged into the past rolls forward by whole intervals.
    #expect(ScheduleTimeline.movedFireDate(of: jobs[1], from: jobs[1].anchor, to: date("2026-11-18T08:00:00Z"),
                                           snapMinutes: 15, now: now, calendar: calendar) == date("2026-11-18T20:00:00Z"))
    let time = ScheduleTimeline.timeOfDay(date("2026-11-19T14:52:00Z"), snapMinutes: 5, calendar: calendar)
    #expect(time.hour == 9 && time.minute == 50)
    #expect(ScheduleTimeline.intervalDescription(6 * 3_600) == "every 6 hours")
    #expect(ScheduleTimeline.intervalDescription(90 * 60) == "every 90 minutes")
    #expect(ScheduleRange.allCases.map(\.days) == [1, 3, 7, 14])
    // Zoom: snapping and ruler ticks follow how wide an hour is.
    #expect(ScheduleTimeline.snapMinutes(pointsPerHour: 200) == 5)
    #expect(ScheduleTimeline.snapMinutes(pointsPerHour: 8) == 60)
    #expect(ScheduleTimeline.tickHours(pointsPerHour: 70) == 1)
    #expect(ScheduleTimeline.tickHours(pointsPerHour: 12) == 6)
    #expect(ScheduleTimeline.tickHours(pointsPerHour: 2) == 24)
    #expect(ScheduleTimeline.zoomFactor(slider: 0, maximum: 16) == 1)
    #expect(ScheduleTimeline.zoomFactor(slider: 0.5, maximum: 16) == 4)
    #expect(ScheduleTimeline.zoomFactor(slider: 1, maximum: 16) == 16)
  }

  @Test func oneDayRangeFillsOneScreenFromNow() {
    let now = date("2026-11-24T15:20:00Z")
    let window = ScheduleTimeline.window(now: now, days: 1, pastSpan: 2 * 86_400, calendar: calendar)
    // Past runs stay reachable: the window reaches back to the start of that day.
    #expect(window.start == calendar.startOfDay(for: now.addingTimeInterval(-2 * 86_400)))
    // The future ends exactly one day ahead, not three.
    #expect(window.end == now.addingTimeInterval(86_400))
    // At 1x, one screen spans a 16-point lead-in plus exactly one day ahead.
    let width = 800.0
    let scale = ScheduleTimeline.scale(width: width, days: 1, zoom: 1, leadIn: 16)
    #expect(abs(86_400 * scale - (width - 16)) < 1e-6)
    // The past sits off screen to the left of the opening position.
    #expect(now.timeIntervalSince(window.start) * scale - 16 > width)
    // Zoom scales the same span narrower.
    #expect(abs(ScheduleTimeline.scale(width: width, days: 1, zoom: 4, leadIn: 16) - 4 * scale) < 1e-9)
    #expect(ScheduleTimeline.window(now: now, days: 7, pastSpan: 0, calendar: calendar).end
      == now.addingTimeInterval(7 * 86_400))
  }
}
