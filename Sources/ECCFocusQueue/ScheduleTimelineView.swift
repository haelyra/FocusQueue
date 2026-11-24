import AppKit
import FocusQueueCore
import SwiftUI

enum ScheduleTimelineMetrics {
  static let headerWidth: CGFloat = 168
  static let rulerHeight: CGFloat = 46
  static let groupHeight: CGFloat = 22
  static let rowHeight: CGFloat = 50
  static let clipHeight: CGFloat = 44
  static let lanePadding: CGFloat = 4
  /// A fire closer than this to the previous one in its row moves to a new row.
  static let minimumClipGap: CGFloat = 26
  /// Past kept left of now when the view opens on now, so the marker reads.
  static let nowLeadIn: CGFloat = 16
  /// The most an hour may stretch at full zoom.
  static let maximumPointsPerHour: Double = 240

  static func laneHeight(rows: Int) -> CGFloat {
    CGFloat(max(1, rows)) * rowHeight + 2 * lanePadding
  }

  @MainActor static let titleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
  @MainActor static let lineFont = NSFont.systemFont(ofSize: 9)

  /// The width a clip needs to show its three lines untruncated.
  @MainActor static func naturalWidth(title: String, lines: [String]) -> CGFloat {
    let titleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
    let lineWidth = lines.map { ($0 as NSString).size(withAttributes: [.font: lineFont]).width }.max() ?? 0
    return ceil(max(titleWidth, lineWidth + 12)) + 14
  }
}

extension ScheduleJobKind {
  var color: Color {
    switch self {
    case .timer: Color(red: 0.18, green: 0.49, blue: 0.96)
    case .interval: Color(red: 0.54, green: 0.36, blue: 0.96)
    case .cron: Color(red: 0.91, green: 0.51, blue: 0.23)
    case .autoDecide: Color(red: 0.84, green: 0.27, blue: 0.44)
    }
  }

  var symbol: String {
    switch self {
    case .timer: "timer"
    case .interval: "repeat"
    case .cron: "calendar.badge.clock"
    case .autoDecide: "arrow.triangle.branch"
    }
  }
}

extension ScheduleRunOutcome {
  var color: Color {
    switch self {
    case .completed: Color(red: 0.25, green: 0.75, blue: 0.42)
    case .interrupted: Color(red: 0.62, green: 0.62, blue: 0.66)
    case .failed: Color(red: 0.93, green: 0.30, blue: 0.26)
    case .skipped: Color(red: 0.93, green: 0.72, blue: 0.20)
    }
  }

  var symbol: String {
    switch self {
    case .completed: "checkmark.circle.fill"
    case .interrupted: "stop.circle.fill"
    case .failed: "xmark.circle.fill"
    case .skipped: "forward.circle.fill"
    }
  }
}

/// The schedule side panel: an arrangement view of every scheduled job. Each
/// row is the task a job acts on (app-wide jobs share one row). A clip is as
/// wide as its label, or as its expected run once zoomed in far enough, and
/// stops before the next fire. Drag a clip to retime it; click it to select
/// it and see details. Zooming keeps the selected clip centered, or now at
/// the leading edge; the past is reachable by scrolling back.
struct ScheduleTimelineView: View {
  let model: QueueViewModel
  @AppStorage("scheduleTimelineRangeDays") private var rangeDays = ScheduleRange.threeDays.rawValue
  @AppStorage("scheduleTimelineAllProjects") private var showsAllProjects = false
  /// Empty means this Mac's zone.
  @AppStorage("scheduleTimelineTimeZone") private var timeZoneID = ""
  @State private var zoomSlider = 0.0
  @State private var jobs: [ScheduleJob] = []
  @State private var drag: (clipID: String, offset: CGFloat)?
  @State private var selectedClipID: String?
  @State private var detailClipID: String?
  @State private var hoveredClipID: String?
  /// The selected clip's start, which zooming keeps centered; nil keeps now at the leading edge.
  @State private var focusDate: Date?
  @State private var status: String?
  /// Starts pending so the first layout opens on the focus date.
  @State private var scrollRequest = HorizontalScrollTarget.Request()

  init(model: QueueViewModel, initialZoom: Double = 0) {
    self.model = model
    _zoomSlider = State(initialValue: initialZoom)
  }

  private var range: ScheduleRange { ScheduleRange(rawValue: rangeDays) ?? .threeDays }
  private var timeZone: TimeZone { timeZoneID.isEmpty ? .current : TimeZone(identifier: timeZoneID) ?? .current }
  private var calendar: Calendar {
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    return calendar
  }
  private var scopeProjectID: String? { showsAllProjects ? nil : model.selectedProjectID }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      controls
      if let status {
        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      TimelineView(.periodic(from: .now, by: 30)) { context in
        arrangement(now: context.date)
      }
      legend
    }
    .onAppear(perform: reload)
    .onChange(of: model.scheduledLaunches) { _, _ in reload() }
    .onChange(of: model.scheduledAgentResumes) { _, _ in reload() }
    .onChange(of: model.config.dailyReport) { _, _ in reload() }
  }

  private func reload() { jobs = model.scheduleJobs() }

  // MARK: Header and controls

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "calendar.day.timeline.left")
        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
      VStack(alignment: .leading, spacing: 0) {
        Text("Schedule").font(.headline)
        Text("\(jobs.count) scheduled job\(jobs.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button { reload() } label: { Image(systemName: "arrow.clockwise") }
        .buttonStyle(.plain)
        .frame(minWidth: 30, minHeight: 30).contentShape(Rectangle())
        .accessibilityLabel("Reload schedule")
        .help("Reload scheduled jobs and pending decisions")
      Button { model.setSchedulePresented(false) } label: { Image(systemName: "xmark") }
        .buttonStyle(.plain)
        .frame(minWidth: 30, minHeight: 30).contentShape(Rectangle())
        .accessibilityLabel("Close schedule")
        .help("Close schedule")
    }
  }

  private var controls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) { scopePicker; rangePicker; zoomControl; Spacer(minLength: 0); timeZoneMenu }
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) { scopePicker; rangePicker; Spacer(minLength: 0) }
        HStack(spacing: 8) { zoomControl; Spacer(minLength: 0); timeZoneMenu }
      }
    }
  }

  private var scopePicker: some View {
    Picker("Projects", selection: $showsAllProjects) {
      Text(model.selectedProject.map { "This project · \($0.name)" } ?? "This project").tag(false)
      Text("All projects").tag(true)
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .fixedSize()
    .disabled(model.selectedProjectID == nil)
    .help("Show jobs for the selected project, or for every project")
  }

  private var rangePicker: some View {
    Picker("Range", selection: $rangeDays) {
      ForEach(ScheduleRange.allCases) { Text($0.label).tag($0.rawValue) }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize()
    .help("How many days the timeline covers")
  }

  private var zoomControl: some View {
    HStack(spacing: 4) {
      Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
      Slider(value: $zoomSlider, in: 0...1)
        .controlSize(.small)
        .frame(width: 110)
        .accessibilityLabel("Zoom")
      Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
    }
    .help("Zoom in on the timeline. Keeps the selected clip centered, or now at the left edge.")
  }

  private static let zoneChoices = [
    "UTC", "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York",
    "Europe/London", "Europe/Berlin", "Asia/Kolkata", "Asia/Tokyo", "Australia/Sydney",
  ]

  private var timeZoneMenu: some View {
    Menu {
      Button { timeZoneID = "" } label: {
        Text("This Mac · \(Self.zoneLabel(.current))")
      }
      Divider()
      ForEach(Self.zoneChoices, id: \.self) { id in
        if let zone = TimeZone(identifier: id) {
          Button { timeZoneID = id } label: {
            Text("\(id.replacingOccurrences(of: "_", with: " ")) · \(Self.zoneLabel(zone))")
          }
        }
      }
    } label: {
      Label(Self.zoneLabel(timeZone), systemImage: "globe")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Time zone, \(Self.zoneLabel(timeZone))")
    .help("Show times in another zone. Jobs still run on this Mac's clock.")
  }

  /// "EST · UTC−5".
  static func zoneLabel(_ zone: TimeZone, at date: Date = Date()) -> String {
    let seconds = zone.secondsFromGMT(for: date)
    let hours = seconds / 3_600
    let minutes = abs(seconds % 3_600) / 60
    let sign = seconds < 0 ? "−" : "+"
    let offset = seconds == 0 ? "UTC" : "UTC\(sign)\(abs(hours))\(minutes == 0 ? "" : String(format: ":%02d", minutes))"
    let abbreviation = zone.abbreviation(for: date) ?? zone.identifier
    return abbreviation == offset || abbreviation == "GMT" && seconds == 0 ? offset : "\(abbreviation) · \(offset)"
  }

  // MARK: Arrangement

  private func window(now: Date) -> DateInterval {
    // Past runs stay reachable by scrolling back; the view opens on now.
    ScheduleTimeline.window(now: now, days: range.days,
                            pastSpan: ScheduleRunHistoryStore.retention, calendar: calendar)
  }

  private struct LaidOutTrack: Identifiable {
    let track: ScheduleTrack
    let clips: [ScheduleClip]
    var id: String { track.id }
    var height: CGFloat { ScheduleTimelineMetrics.laneHeight(rows: (clips.map(\.row).max() ?? 0) + 1) }
  }

  private struct LaidOutGroup: Identifiable {
    let group: ScheduleTrackGroup
    let tracks: [LaidOutTrack]
    var id: String { group.id }
  }

  @ViewBuilder private func arrangement(now: Date) -> some View {
    let window = window(now: now)
    let history = model.scheduleRunHistory(now: now)
    let groups = ScheduleTimeline.groups(
      jobs: jobs, history: history, projectID: scopeProjectID,
      projectNames: model.scheduleProjectNames, tickets: model.scheduleTicketInfo)
    if groups.isEmpty {
      ContentUnavailableView {
        Label("Nothing scheduled", systemImage: "calendar.badge.clock")
      } description: {
        Text("Schedule an agent from the new-task form, turn on the daily report in Settings, or wait for a pending decision.")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      GeometryReader { geometry in
        let fitWidth = max(120, geometry.size.width - ScheduleTimelineMetrics.headerWidth)
        // 1x fits the chosen range ahead of now into one screen; the past
        // extends off screen to the left.
        let fitScale = ScheduleTimeline.scale(width: Double(fitWidth), days: range.days, zoom: 1,
                                              leadIn: Double(ScheduleTimelineMetrics.nowLeadIn))
        let maximumZoom = ScheduleTimelineMetrics.maximumPointsPerHour / 3_600 / fitScale
        let scale = fitScale * ScheduleTimeline.zoomFactor(slider: zoomSlider, maximum: maximumZoom)
        let contentWidth = CGFloat(window.duration * scale)
        let laidOut = groups.map { group in
          LaidOutGroup(group: group, tracks: group.tracks.map { track in
            LaidOutTrack(track: track, clips: ScheduleTimeline.clips(
              for: track, in: window,
              minimumGap: Double(ScheduleTimelineMetrics.minimumClipGap) / scale,
              history: history.filter { $0.trackID == track.id },
              pastCutoff: now, calendar: calendar))
          })
        }
        let showsGroupTitles = groups.count > 1 || groups.first?.id != "~app"
        // A selected clip is centered; otherwise now sits at the leading edge.
        let focusX = focusDate.map { CGFloat($0.timeIntervalSince(window.start) * scale) }
          ?? CGFloat(now.timeIntervalSince(window.start) * scale) - ScheduleTimelineMetrics.nowLeadIn
        ScrollView(.vertical) {
          HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
              zoneHeader
              Divider()
              ForEach(laidOut) { group in
                if showsGroupTitles { groupTitle(group.group.title) }
                ForEach(group.tracks) { item in
                  trackHeader(item.track).frame(height: item.height)
                  Divider()
                }
              }
            }
            .frame(width: ScheduleTimelineMetrics.headerWidth)
            .overlay(alignment: .trailing) { Divider() }
            ScrollView(.horizontal) {
              VStack(alignment: .leading, spacing: 0) {
                ScheduleRuler(window: window, calendar: calendar, scale: scale, now: now)
                  .frame(width: contentWidth, height: ScheduleTimelineMetrics.rulerHeight, alignment: .topLeading)
                  // Scrolls the focus date into place whenever a request is made.
                  .background(HorizontalScrollTarget(
                    x: focusX, anchor: focusDate == nil ? 0 : 0.5, request: scrollRequest))
                Divider()
                ForEach(laidOut) { group in
                  if showsGroupTitles { groupTitle("") }
                  ForEach(group.tracks) { item in
                    lane(item, window: window, scale: scale, width: contentWidth, now: now)
                    Divider()
                  }
                }
              }
              .frame(width: contentWidth, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .onChange(of: zoomSlider) { _, _ in scrollRequest.bump(animated: false) }
            .onChange(of: rangeDays) { _, _ in scrollRequest.bump(animated: false) }
            .onChange(of: showsAllProjects) { _, _ in scrollRequest.bump(animated: false) }
            .onChange(of: selectedClipID) { _, id in if id != nil { scrollRequest.bump(animated: true) } }
          }
        }
        .scrollIndicators(.automatic)
      }
      .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor).opacity(0.55)))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.18)))
    }
  }

  private func groupTitle(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.leading, 8)
      .frame(maxWidth: .infinity, minHeight: ScheduleTimelineMetrics.groupHeight,
             maxHeight: ScheduleTimelineMetrics.groupHeight, alignment: .leading)
      .background(Color.secondary.opacity(0.08))
  }

  private var zoneHeader: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("Times in \(timeZone.abbreviation() ?? timeZone.identifier)")
        .font(.system(size: 10, weight: .semibold))
      Text(timeZoneID.isEmpty ? Self.zoneLabel(timeZone) : "This Mac: \(Self.zoneLabel(.current))")
        .font(.system(size: 9)).foregroundStyle(.secondary)
    }
    .lineLimit(1)
    .padding(.horizontal, 8)
    .frame(width: ScheduleTimelineMetrics.headerWidth, height: ScheduleTimelineMetrics.rulerHeight, alignment: .leading)
  }

  private func trackHeader(_ track: ScheduleTrack) -> some View {
    let ticket = model.dashboard.tickets.first { $0.id.caseInsensitiveCompare(track.id) == .orderedSame }
    let label = VStack(alignment: .leading, spacing: 1) {
      Text(track.title).font(.system(size: 11, weight: .semibold))
      Text(track.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
    }
    .lineLimit(1)
    .padding(.horizontal, 8)
    .frame(width: ScheduleTimelineMetrics.headerWidth, alignment: .leading)
    .frame(maxHeight: .infinity)
    .contentShape(Rectangle())
    return Group {
      if let ticket {
        Button { model.openPlan(for: ticket) } label: { label }
          .buttonStyle(.plain)
          .help("Open \(track.title)'s plan")
      } else {
        label.help(track.subtitle)
      }
    }
  }

  private func lane(_ item: LaidOutTrack, window: DateInterval, scale: Double, width: CGFloat, now: Date) -> some View {
    ZStack(alignment: .topLeading) {
      ScheduleGrid(window: window, calendar: calendar, scale: scale)
        .contentShape(Rectangle())
        .onTapGesture { selectedClipID = nil; focusDate = nil }
      Rectangle().fill(Color.red).frame(width: 1.5)
        .offset(x: CGFloat(now.timeIntervalSince(window.start) * scale))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      ForEach(item.clips) { clip in
        clipView(clip, window: window, scale: scale)
      }
    }
    .frame(width: width, height: item.height, alignment: .topLeading)
    .zIndex(item.clips.contains { $0.id == hoveredClipID || $0.id == drag?.clipID } ? 1 : 0)
  }

  private func clipView(_ clip: ScheduleClip, window: DateInterval, scale: Double) -> some View {
    let job = clip.job
    let x = CGFloat(clip.start.timeIntervalSince(window.start) * scale)
    let dragOffset = drag?.clipID == clip.id ? drag?.offset ?? 0 : 0
    let shown = dragOffset == 0 ? clip.start
      : ScheduleTimeline.snap(clip.start.addingTimeInterval(Double(dragOffset) / scale),
                              minutes: ScheduleTimeline.snapMinutes(pointsPerHour: scale * 3_600), calendar: calendar)
    let lines = clip.outcome.map { Self.historyLines(clip, outcome: $0, calendar: calendar) }
      ?? Self.clipLines(job, start: shown, calendar: calendar)
    let natural = ScheduleTimelineMetrics.naturalWidth(title: job.title, lines: [lines.when, lines.run])
    let run = clip.outcome == nil ? CGFloat(job.expectedDuration * scale) : 0
    let slot = CGFloat(clip.end.timeIntervalSince(clip.start) * scale) - 3
    let width = max(8, min(slot, max(natural, run)))
    let truncated = width < natural
    let selected = selectedClipID == clip.id
    let showsCard = (hoveredClipID == clip.id && truncated || dragOffset != 0) && detailClipID != clip.id
    return ScheduleClipView(job: job, outcome: clip.outcome, when: lines.when, run: lines.run,
                            runWidth: min(run, width), selected: selected, lifted: dragOffset != 0)
      .frame(width: width, height: ScheduleTimelineMetrics.clipHeight, alignment: .leading)
      .overlay(alignment: .topLeading) {
        if showsCard {
          ScheduleClipCard(job: job, outcome: clip.outcome, when: lines.when, run: lines.run)
            .offset(y: ScheduleTimelineMetrics.clipHeight + 3)
            .allowsHitTesting(false)
        }
      }
      .offset(x: x + dragOffset,
              y: ScheduleTimelineMetrics.lanePadding
                + (ScheduleTimelineMetrics.rowHeight - ScheduleTimelineMetrics.clipHeight) / 2
                + CGFloat(clip.row) * ScheduleTimelineMetrics.rowHeight)
      .zIndex(selected || showsCard ? 2 : 0)
      .onHover { inside in
        if inside { hoveredClipID = clip.id } else if hoveredClipID == clip.id { hoveredClipID = nil }
      }
      .onTapGesture {
        hoveredClipID = nil
        selectedClipID = clip.id
        focusDate = clip.start
        detailClipID = clip.id
      }
      .gesture(job.isMovable ? dragGesture(clip, scale: scale) : nil)
      .popover(isPresented: Binding(
        get: { detailClipID == clip.id },
        set: { if !$0, detailClipID == clip.id { detailClipID = nil } })
      ) {
        ScheduleClipDetail(model: model, clip: clip, calendar: calendar, zone: Self.zoneLabel(timeZone),
                           run: lines.run) { detailClipID = nil }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(clip.outcome.map { "\(job.title), \($0.label.lowercased()), \(lines.when)" }
        ?? "\(job.title), \(lines.when), \(lines.run)")
      .accessibilityHint(job.isMovable ? "Drag to retime. Activate to select and see details." : "Read-only. Activate for details.")
      .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// Line two (outcome and exact time) and line three (what happened) for a
  /// past run drawn from the history.
  static func historyLines(_ clip: ScheduleClip, outcome: ScheduleRunOutcome,
                           calendar: Calendar) -> (when: String, run: String) {
    let when = "\(outcome.label) · \(clipTime(clip.start, calendar: calendar))"
    let run = clip.job.detail.isEmpty ? outcome.explanation : clip.job.detail
    return (when, run)
  }

  private func dragGesture(_ clip: ScheduleClip, scale: Double) -> some Gesture {
    DragGesture(minimumDistance: 4)
      .onChanged { value in
        detailClipID = nil
        drag = (clip.id, value.translation.width)
      }
      .onEnded { value in
        drag = nil
        let target = clip.start.addingTimeInterval(Double(value.translation.width) / scale)
        guard let moved = model.moveScheduleJob(
          clip.job, from: clip.start, to: target,
          snapMinutes: ScheduleTimeline.snapMinutes(pointsPerHour: scale * 3_600), calendar: calendar)
        else {
          status = "\(clip.job.title) could not move."
          return
        }
        if selectedClipID == clip.id { focusDate = moved }
        status = clip.job.kind == .cron
          ? "\(clip.job.title) now runs daily at \(Self.clipTime(moved, calendar: calendar, weekday: false))."
          : "\(clip.job.title) next runs \(Self.clipTime(moved, calendar: calendar))."
        reload()
      }
  }

  /// Line two (kind and exact time) and line three (estimated run window).
  static func clipLines(_ job: ScheduleJob, start: Date, calendar: Calendar) -> (when: String, run: String) {
    let action = job.actionLabel.map { " · \($0)" } ?? ""
    let when = "\(job.kind.label)\(repeatSuffix(job))\(action) · \(clipTime(start, calendar: calendar))"
    let end = start.addingTimeInterval(job.expectedDuration)
    let run = job.expectedDuration > 0
      ? "Run ≈ \(clipTime(start, calendar: calendar, weekday: false, zone: false)) – \(clipTime(end, calendar: calendar, weekday: false, zone: false))"
      : "Instant"
    return (when, run)
  }

  static func repeatSuffix(_ job: ScheduleJob) -> String {
    guard job.kind == .interval, let interval = job.repeatInterval else { return "" }
    return " · \(ScheduleTimeline.intervalDescription(interval))"
  }

  static func clipTime(_ date: Date, calendar: Calendar, weekday: Bool = true, zone: Bool = true) -> String {
    let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
    var parts: [String] = []
    if weekday { parts.append(date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated))) }
    parts.append(time)
    if zone, let abbreviation = calendar.timeZone.abbreviation(for: date) { parts.append(abbreviation) }
    return parts.joined(separator: " ")
  }

  private var legend: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 12) {
        ForEach(ScheduleJobKind.allCases, id: \.self) { kind in
          HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 9, height: 9)
            Text("\(kind.label) · \(kind.explanation.lowercased())")
          }
        }
      }
      HStack(spacing: 12) {
        Text("Past runs:")
        ForEach(ScheduleRunOutcome.allCases, id: \.self) { outcome in
          HStack(spacing: 4) {
            Image(systemName: outcome.symbol).foregroundStyle(outcome.color)
            Text("\(outcome.label.lowercased()) · \(outcome.explanation.lowercased())")
          }
        }
      }
    }
    .font(.system(size: 10)).foregroundStyle(.secondary)
    .lineLimit(1).minimumScaleFactor(0.8)
  }
}

/// One fire: a filled clip with the title, the kind and exact time, and the
/// estimated run window, truncated when the next fire is close. When zoomed in
/// past its label width, a darker band marks the expected run. A past run
/// (outcome set) draws dimmed with its outcome marking the leading edge.
private struct ScheduleClipView: View {
  let job: ScheduleJob
  var outcome: ScheduleRunOutcome? = nil
  let when: String
  let run: String
  let runWidth: CGFloat
  let selected: Bool
  let lifted: Bool
  @State private var showsHand = false

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(job.title).font(Font(ScheduleTimelineMetrics.titleFont))
      HStack(spacing: 3) {
        Image(systemName: outcome?.symbol ?? (job.isMovable ? job.kind.symbol : "lock.fill"))
          .font(.system(size: 8))
        Text(when)
      }
      .font(Font(ScheduleTimelineMetrics.lineFont))
      Text(run).font(Font(ScheduleTimelineMetrics.lineFont)).opacity(0.85)
    }
    .lineLimit(1)
    .truncationMode(.tail)
    .foregroundStyle(.white)
    .padding(.leading, 7).padding(.trailing, 4)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(alignment: .leading) {
      ZStack(alignment: .leading) {
        job.kind.color.opacity(outcome == nil ? (job.isMovable ? 0.88 : 0.7) : 0.45)
        if runWidth > 12 {
          // The expected run, visible once it is wider than a sliver.
          Color.black.opacity(0.14).frame(width: runWidth)
        }
        Rectangle().fill(outcome?.color ?? .white.opacity(0.85)).frame(width: 2)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 5))
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2))
    .shadow(color: .black.opacity(lifted || selected ? 0.25 : 0), radius: 5, y: 2)
    .contentShape(Rectangle())
    .onHover { inside in
      guard job.isMovable, inside != showsHand else { return }
      showsHand = inside
      if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
    }
    .onDisappear { if showsHand { showsHand = false; NSCursor.pop() } }
  }
}

/// The hover card for a truncated clip: its full label, never cut off.
private struct ScheduleClipCard: View {
  let job: ScheduleJob
  var outcome: ScheduleRunOutcome? = nil
  let when: String
  let run: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(job.title).font(.system(size: 11, weight: .semibold))
      Text(when)
      if outcome != nil {
        Text(run).lineLimit(3).fixedSize(horizontal: false, vertical: true)
      } else {
        Text(job.expectedDuration > 0 ? "\(run) (estimate)" : "Instant: happens at this moment")
      }
      Text(job.isMovable ? "Drag to retime · click for details" : "Read-only · click for details")
        .foregroundStyle(.secondary)
    }
    .font(.system(size: 10))
    .fixedSize()
    .padding(.horizontal, 8).padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
    .overlay(alignment: .leading) { Rectangle().fill(job.kind.color).frame(width: 3) }
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(job.kind.color.opacity(0.6)))
    .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
  }
}

/// The details popover for a clicked clip, with the actions that fit its job.
private struct ScheduleClipDetail: View {
  let model: QueueViewModel
  let clip: ScheduleClip
  let calendar: Calendar
  let zone: String
  let run: String
  let dismiss: () -> Void

  var body: some View {
    let job = clip.job
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: job.kind.symbol).foregroundStyle(job.kind.color)
        Text(job.title).font(.headline).lineLimit(2)
      }
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
        row("Type", "\(job.kind.label) · \(job.kind.explanation.lowercased())")
        if let outcome = clip.outcome {
          row("Outcome", "\(outcome.label) · \(outcome.explanation.lowercased())")
        }
        row(clip.outcome == nil ? "This run" : "Scheduled", ScheduleTimelineView.clipTime(clip.start, calendar: calendar))
        if clip.outcome == nil {
          row("Expected", job.expectedDuration > 0 ? "\(run) (estimate)" : "Instant")
        }
        if let interval = job.repeatInterval {
          row("Repeats", job.kind == .cron
            ? "daily at \(ScheduleTimelineView.clipTime(job.anchor, calendar: .current, weekday: false)) on this Mac"
            : ScheduleTimeline.intervalDescription(interval))
        }
        if let ticketID = job.ticketID { row("Task", ticketID) }
        if let action = job.actionLabel { row("Action", action) }
        if let target = job.targetLabel { row("Target", target) }
        row("Zone", zone)
      }
      .font(.system(size: 11))
      if !job.detail.isEmpty {
        Text(job.detail).font(.system(size: 11)).foregroundStyle(.secondary)
          .lineLimit(6).textSelection(.enabled)
      }
      if !job.isMovable, clip.outcome == nil {
        Label("Set by the decision auto-decide window in Settings.", systemImage: "lock.fill")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        if let ticketID = job.ticketID,
           let ticket = model.dashboard.tickets.first(where: { $0.id.caseInsensitiveCompare(ticketID) == .orderedSame }) {
          Button("Open task") { dismiss(); model.openPlan(for: ticket) }
        }
        Spacer()
        if case .scheduledLaunch(let id) = job.source {
          Button("Cancel schedule", role: .destructive) { dismiss(); model.cancelScheduledLaunch(id: id) }
        }
        if case .scheduledResume(let id) = job.source {
          Button("Cancel schedule", role: .destructive) { dismiss(); model.cancelScheduledAgentResume(id: id) }
        }
      }
      .controlSize(.small)
    }
    .padding(12)
    .frame(width: 300)
  }

  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }
}

/// Day and hour labels across the top of the arrangement.
private struct ScheduleRuler: View {
  let window: DateInterval
  let calendar: Calendar
  let scale: Double
  let now: Date

  var body: some View {
    let marks = ScheduleGrid.marks(window: window, calendar: calendar, scale: scale)
    let firstDay = marks.first(where: \.isDay)
    ZStack(alignment: .topLeading) {
      // The partial first day gets its date at the left edge unless midnight is close.
      if firstDay.map({ $0.date.timeIntervalSince(window.start) * scale >= 90 }) ?? true {
        Text(window.start.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day()))
          .font(.system(size: 10, weight: .semibold)).fixedSize()
          .padding(.leading, 3).offset(y: 3)
      }
      // The view opens on now, so today's date rides on the playhead unless
      // a day label already sits close on either side.
      let nowX = now.timeIntervalSince(window.start) * scale
      if !marks.contains(where: { $0.isDay && abs($0.date.timeIntervalSince(window.start) * scale - nowX) < 90 }) {
        Text(now.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day()))
          .font(.system(size: 10, weight: .semibold)).fixedSize()
          .offset(x: CGFloat(nowX) - 7, y: 3)
      }
      ForEach(marks, id: \.date) { mark in
        Text(mark.isDay ? mark.date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day())
             : mark.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)))
          .font(.system(size: mark.isDay ? 10 : 9, weight: mark.isDay ? .semibold : .regular))
          .foregroundStyle(mark.isDay ? .primary : .secondary)
          .fixedSize()
          .padding(.leading, 3)
          .offset(x: CGFloat(mark.date.timeIntervalSince(window.start) * scale), y: mark.isDay ? 3 : 19)
      }
      Text("now").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
        .padding(.horizontal, 3).background(Capsule().fill(Color.red))
        .fixedSize()
        .offset(x: CGFloat(now.timeIntervalSince(window.start) * scale) - 10, y: ScheduleTimelineMetrics.rulerHeight - 13)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .clipped()
  }
}

/// Day lines and lighter hour lines behind each lane.
private struct ScheduleGrid: View {
  struct Mark { let date: Date; let isDay: Bool }

  let window: DateInterval
  let calendar: Calendar
  let scale: Double

  /// Midnights plus hour ticks spaced so their labels never collide.
  static func marks(window: DateInterval, calendar: Calendar, scale: Double) -> [Mark] {
    let step = ScheduleTimeline.tickHours(pointsPerHour: scale * 3_600)
    var marks: [Mark] = []
    var date = calendar.dateInterval(of: .hour, for: window.start)?.start ?? window.start
    while date <= window.end {
      let hour = calendar.component(.hour, from: date)
      if date >= window.start {
        if hour == 0 { marks.append(Mark(date: date, isDay: true)) }
        else if step < 24, hour % step == 0 { marks.append(Mark(date: date, isDay: false)) }
      }
      guard let next = calendar.date(byAdding: .hour, value: 1, to: date) else { break }
      date = next
    }
    return marks
  }

  var body: some View {
    Canvas { context, size in
      for mark in Self.marks(window: window, calendar: calendar, scale: scale) {
        let x = mark.date.timeIntervalSince(window.start) * scale
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(.secondary.opacity(mark.isDay ? 0.35 : 0.12)), lineWidth: mark.isDay ? 1 : 0.5)
      }
    }
  }
}

/// Scrolls the enclosing horizontal `NSScrollView` so content x `x` sits at
/// `anchor` (0 leading, 0.5 center) of the visible width. It acts once per
/// new `request`, after layout, so the user's own scrolling is left alone.
/// `ScrollViewReader.scrollTo` proved unreliable for this nested scroll view.
struct HorizontalScrollTarget: NSViewRepresentable {
  struct Request: Equatable {
    var serial = 1
    var animated = false
    mutating func bump(animated: Bool) {
      serial += 1
      self.animated = animated
    }
  }

  let x: CGFloat
  let anchor: CGFloat
  let request: Request

  final class Coordinator { var handled = 0 }

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    guard context.coordinator.handled != request.serial else { return }
    context.coordinator.handled = request.serial
    let x = x, anchor = anchor, animated = request.animated
    // Wait one turn so the new content width is laid out before scrolling.
    DispatchQueue.main.async {
      guard let scrollView = view.enclosingScrollView else { return }
      let clip = scrollView.contentView
      let visible = clip.bounds.width
      let limit = max(0, (scrollView.documentView?.frame.width ?? 0) - visible)
      let origin = NSPoint(x: min(max(0, x - visible * anchor), limit), y: clip.bounds.origin.y)
      if animated {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.25
          clip.animator().setBoundsOrigin(origin)
        }
      } else {
        clip.setBoundsOrigin(origin)
      }
      scrollView.reflectScrolledClipView(clip)
    }
  }
}
