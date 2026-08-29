import FocusQueueCore
import SwiftUI

struct QueueView: View {
  let model: QueueViewModel
  @State private var showsMoreTasks = false
  @State private var screen: QueueScreen = .queue

  private var focusTickets: [DashboardTicket] { Array(model.openTickets.prefix(5)) }

  private var remainingTickets: [DashboardTicket] { Array(model.openTickets.dropFirst(5)) }

  var body: some View {
    Group {
      if model.isPanelCollapsed {
        compactHeader
      } else if screen == .settings {
        QueueSettingsView(model: model) {
          withAnimation(.easeInOut(duration: 0.18)) { screen = .queue }
        }
      } else {
        queueContent
      }
    }.padding(12).frame(minWidth: 380, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
      .panelSurface(radius: 30).preferredColorScheme(
        model.appearance == .dark ? .dark : .light
      ).environment(\.queueAccentStyle, model.accentStyle).tint(
        QueueAccentPalette.color(.info, style: model.accentStyle))
  }

  private var queueContent: some View {
    VStack(spacing: 10) {
      header
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          SectionHeading(title: "Today's focus", detail: "Top \(focusTickets.count)")

          if focusTickets.isEmpty {
            ContentUnavailableView(
              "Queue is clear", systemImage: "checkmark.circle",
              description: Text("No open tasks are present in the dashboard.")
            ).frame(maxWidth: .infinity).notificationSurface(radius: 18)
          } else {
            ForEach(focusTickets) { ticket in TicketCard(ticket: ticket, model: model) }
          }

          if showsMoreTasks {
            additionalQueue.transition(.opacity.combined(with: .move(edge: .bottom)))
          }
        }.padding(.horizontal, 2).padding(.vertical, 2)
      }.scrollIndicators(.automatic)

      if !remainingTickets.isEmpty || !model.config.dailyRoutines.isEmpty { moreButton }
    }
  }

  private var compactHeader: some View {
    HStack(spacing: 10) {
      Text("ECC Focus Queue").font(.system(size: 19, weight: .bold, design: .rounded))
      Spacer()
      Button {
        model.setPanelCollapsed(false)
      } label: {
        Image(systemName: "rectangle.expand.vertical").font(.system(size: 13, weight: .semibold))
      }.buttonStyle(.plain).frame(width: 40, height: 40).accessibilityLabel(
        "Expand ECC Focus Queue"
      ).help("Expand queue")
    }.padding(.horizontal, 15).frame(height: 58).notificationSurface(radius: 18)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        Circle().fill(
          QueueAccentPalette.color(
            model.loadError == nil ? .success : .warning, style: model.accentStyle)
        ).frame(width: 7, height: 7)
        syncLabel
        Spacer()
        Button {
          withAnimation(.easeInOut(duration: 0.18)) { screen = .settings }
        } label: {
          Image(systemName: "gearshape.fill").font(.system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).frame(width: 40, height: 40).accessibilityLabel(
          "Open ECC Focus Queue settings"
        ).help("Settings")
        Button {
          Task { await model.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).frame(width: 40, height: 40).disabled(model.isRefreshing)
          .accessibilityLabel("Refresh task dashboard").help("Refresh now")
        Button {
          model.setPanelCollapsed(true)
        } label: {
          Image(systemName: "rectangle.compress.vertical").font(
            .system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).frame(width: 40, height: 40).accessibilityLabel(
          "Collapse ECC Focus Queue to its title"
        ).help("Collapse queue")
      }
      HStack(alignment: .firstTextBaseline) {
        Text("ECC Focus Queue").font(.system(size: 21, weight: .bold, design: .rounded))
        Spacer()
        Text("\(model.openTickets.count) active").font(
          .system(size: 12, weight: .semibold).monospacedDigit()
        ).foregroundStyle(.secondary)
      }
      if let error = model.loadError {
        Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12))
          .foregroundStyle(.orange).lineLimit(2)
      }
    }.padding(.horizontal, 15).padding(.vertical, 11).notificationSurface(radius: 18)
  }

  @ViewBuilder private var syncLabel: some View {
    if let lastSync = model.lastSync {
      Text("Synced \(lastSync.formatted(date: .omitted, time: .shortened))")
    } else if model.isRefreshing {
      Text("Waiting for Documents access")
    } else {
      Text("Waiting for dashboard")
    }
  }

  private var additionalQueue: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !model.config.dailyRoutines.isEmpty {
        SectionHeading(
          title: "Daily checklist",
          detail: "\(model.completedRoutineCount)/\(model.config.dailyRoutines.count)")
        VStack(spacing: 1) {
          ForEach(model.config.dailyRoutines) { routine in
            RoutineRow(
              routine: routine, isComplete: model.routineIsComplete(routine.id),
              toggle: { model.toggleRoutine(routine.id) },
              open: { if let url = routine.url { model.open(url) } })
          }
        }.notificationSurface(radius: 16)
      }

      if !remainingTickets.isEmpty {
        SectionHeading(title: "Rest of queue", detail: "\(remainingTickets.count)")
        ForEach(remainingTickets) { ticket in TicketCard(ticket: ticket, model: model) }
      }
    }
  }

  private var moreButton: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.22)) { showsMoreTasks.toggle() }
    } label: {
      HStack(spacing: 9) {
        Image(systemName: showsMoreTasks ? "chevron.up" : "chevron.down").font(
          .system(size: 12, weight: .bold))
        Text(showsMoreTasks ? "Show only top five" : moreButtonLabel).font(
          .system(size: 14, weight: .semibold))
        Spacer()
        Text(showsMoreTasks ? "" : "\(remainingTickets.count) more").font(
          .system(size: 12, weight: .semibold).monospacedDigit()
        ).foregroundStyle(
          .secondary)
      }.padding(.horizontal, 15).frame(height: 46).contentShape(Rectangle())
    }.buttonStyle(.plain).notificationSurface(radius: 16).accessibilityLabel(
      showsMoreTasks ? "Show only top five tasks" : "View more tasks")
  }

  private var moreButtonLabel: String {
    remainingTickets.isEmpty ? "View daily checklist" : "View more tasks"
  }
}

private enum QueueScreen {
  case queue
  case settings
}

private struct QueueSettingsView: View {
  let model: QueueViewModel
  let close: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        Button(action: close) {
          Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
        }.buttonStyle(.plain).frame(width: 40, height: 40).accessibilityLabel(
          "Back to ECC Focus Queue")
        Text("Settings").font(.system(size: 21, weight: .bold, design: .rounded))
        Spacer()
        Text("ECC Focus Queue").font(.system(size: 12, weight: .semibold)).foregroundStyle(
          .secondary)
      }.padding(.horizontal, 14).padding(.vertical, 10).notificationSurface(radius: 18)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          settingsSection(
            title: "Appearance", detail: "Dark uses your WezTerm #1A1D23 background color."
          ) {
            Picker("Appearance", selection: appearanceBinding) {
              Label("Light", systemImage: "sun.max.fill").tag(QueueAppearance.light)
              Label("Dark", systemImage: "moon.stars.fill").tag(QueueAppearance.dark)
            }.pickerStyle(.segmented).labelsHidden()
          }

          settingsSection(
            title: "Accent colors", detail: "Changes status, priority, sync, and review colors."
          ) {
            Picker("Accent colors", selection: accentStyleBinding) {
              ForEach(QueueAccentStyle.allCases) { style in
                Text(style.displayName).tag(style)
              }
            }.pickerStyle(.segmented).labelsHidden()
          }

          settingsSection(
            title: "Screen location", detail: "The panel stays fixed at this horizontal position."
          ) {
            Picker("Screen location", selection: placementBinding) {
              Text("Left").tag(QueueWindowPlacement.upperLeft)
              Text("Center").tag(QueueWindowPlacement.center)
              Text("Right").tag(QueueWindowPlacement.upperRight)
            }.pickerStyle(.segmented).labelsHidden()
          }

          settingsSection(
            title: "Management",
            detail: "The Desktop launcher and menu-bar checklist remain available."
          ) {
            Button("Open advanced configuration", systemImage: "doc.badge.gearshape") {
              model.openConfiguration()
            }.buttonStyle(.bordered)
          }
        }.padding(.horizontal, 2).padding(.vertical, 2)
      }.scrollIndicators(.automatic)

      Spacer(minLength: 0)
    }
  }

  private var appearanceBinding: Binding<QueueAppearance> {
    Binding(get: { model.appearance }, set: { model.setAppearance($0) })
  }

  private var placementBinding: Binding<QueueWindowPlacement> {
    Binding(get: { model.windowPlacement }, set: { model.placeWindow($0) })
  }

  private var accentStyleBinding: Binding<QueueAccentStyle> {
    Binding(get: { model.accentStyle }, set: { model.setAccentStyle($0) })
  }

  private func settingsSection<Content: View>(
    title: String, detail: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Text(title).font(.system(size: 16, weight: .bold))
      Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      content()
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).notificationSurface(radius: 18)
  }
}

private struct SectionHeading: View {
  let title: String
  let detail: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack {
      Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.7)
      Spacer()
      Text(detail).font(.system(size: 11, weight: .semibold).monospacedDigit())
    }.foregroundStyle(.secondary).padding(.horizontal, 11).frame(height: 27).background(
      QueuePalette.component(for: colorScheme), in: Capsule()
    ).overlay {
      Capsule().stroke(QueuePalette.componentBorder(for: colorScheme), lineWidth: 0.6)
    }
  }
}

private struct RoutineRow: View {
  let routine: DailyRoutine
  let isComplete: Bool
  let toggle: () -> Void
  let open: () -> Void
  @Environment(\.queueAccentStyle) private var accentStyle

  var body: some View {
    HStack(spacing: 9) {
      Button(action: toggle) {
        Image(systemName: isComplete ? "checkmark.circle.fill" : "circle").foregroundStyle(
          isComplete ? QueueAccentPalette.color(.success, style: accentStyle) : Color.secondary
        ).font(
          .system(size: 18))
      }.buttonStyle(.plain).frame(minWidth: 36, minHeight: 36).accessibilityLabel(
        isComplete ? "Mark \(routine.title) incomplete" : "Mark \(routine.title) complete"
      ).accessibilityHint("This daily state stays on this computer and resets tomorrow.").help(
        isComplete ? "Mark incomplete" : "Mark complete for today")

      Text(routine.title).font(.system(size: 15, weight: .medium)).strikethrough(
        isComplete, color: .secondary
      ).foregroundStyle(
        isComplete ? .secondary : .primary
      ).frame(maxWidth: .infinity, alignment: .leading)

      if routine.url != nil {
        Button(action: open) { Image(systemName: "arrow.up.right.square").font(.caption) }
          .buttonStyle(.borderless).frame(minWidth: 36, minHeight: 36)
          .accessibilityLabel("Open \(routine.title)").help("Open queue")
      }
    }.padding(.horizontal, 12).padding(.vertical, 5)
  }
}

private struct TicketCard: View {
  let ticket: DashboardTicket
  let model: QueueViewModel
  @Environment(\.queueAccentStyle) private var accentStyle

  private var review: CompletionRequest? { model.latestReview(for: ticket.id) }
  private var isChecked: Bool { model.ticketIsChecked(ticket) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      summary
      if model.isExpanded(ticket.id) {
        Divider().opacity(0.45).padding(.horizontal, 14)
        details.padding(.top, 11).transition(.opacity.combined(with: .move(edge: .top)))
      }
    }.notificationSurface(radius: 18)
  }

  private var summary: some View {
    HStack(alignment: .top, spacing: 11) {
      VStack(spacing: 1) {
        Button {
          if !isChecked { model.requestCompletion(for: ticket) }
        } label: {
          Image(systemName: isChecked ? "checkmark.circle.fill" : "circle").font(
            .system(size: 20, weight: .medium)
          ).foregroundStyle(checkColor)
        }.buttonStyle(.plain).disabled(review?.status == .running).frame(width: 40, height: 36)
          .accessibilityLabel(
            "Request completion review for \(ticket.id)"
          ).accessibilityHint("Queues Hermes evidence review without directly closing the task.")
          .help("Queue an evidence-based Hermes completion review")

        Button {
          toggleExpansion()
        } label: {
          Image(systemName: model.isExpanded(ticket.id) ? "chevron.up" : "chevron.down").font(
            .system(size: 11, weight: .bold)
          ).foregroundStyle(
            .secondary)
        }.buttonStyle(.plain).frame(width: 40, height: 32).accessibilityLabel(
          model.isExpanded(ticket.id)
            ? "Hide details for \(ticket.id)" : "Show details for \(ticket.id)")
      }

      Button(action: toggleExpansion) {
        VStack(alignment: .leading, spacing: 7) {
          HStack(alignment: .top, spacing: 10) {
            Text(ticket.title).font(.system(size: 16, weight: .semibold)).lineLimit(3).frame(
              maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
              Text(ticket.progressLabel).font(
                .system(size: 12, weight: .semibold).monospacedDigit()
              ).foregroundStyle(.secondary).fixedSize()
              Text(ticket.id).font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(priorityColor).fixedSize()
            }
          }
          HStack(spacing: 6) {
            StatusPill(text: ticket.priority, color: priorityColor)
            StatusPill(text: ticket.status, color: statusColor)
            if let review { ReviewPill(status: review.status) }
          }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel(
        "\(ticket.title), \(ticket.progressLabel), \(ticket.id)"
      ).accessibilityHint(
        model.isExpanded(ticket.id) ? "Hides task details." : "Shows task details."
      ).help(model.isExpanded(ticket.id) ? "Hide task details" : "Show task details")
    }.padding(.horizontal, 13).padding(.vertical, 11)
  }

  private func toggleExpansion() {
    withAnimation(.easeInOut(duration: 0.18)) {
      model.setExpanded(!model.isExpanded(ticket.id), ticketID: ticket.id)
    }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 10) {
      DetailBlock(title: "Summary", text: ticket.summary)
      if let next = ticket.next, !next.isEmpty { DetailBlock(title: "Next", text: next) }
      if let doneWhen = ticket.doneWhen, !doneWhen.isEmpty {
        DetailBlock(title: "Done when", text: doneWhen)
      }

      if !ticket.steps.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          DetailLabel(text: "Progress")
          ForEach(ticket.steps) { step in
            HStack(alignment: .top, spacing: 7) {
              Image(systemName: stepIcon(step.status)).foregroundStyle(stepColor(step.status))
                .frame(width: 14)
              VStack(alignment: .leading, spacing: 2) {
                Text(step.label).font(.system(size: 13))
                ForEach(step.evidence, id: \.self) { evidence in
                  Button {
                    model.open(evidence)
                  } label: {
                    Text(URL(fileURLWithPath: evidence).lastPathComponent).font(.system(size: 12))
                      .lineLimit(1)
                  }.buttonStyle(.link).accessibilityLabel(
                    "Open evidence \(URL(fileURLWithPath: evidence).lastPathComponent)")
                }
              }
            }
          }
        }
      }

      if !ticket.prs.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          DetailLabel(text: "Pull requests")
          ForEach(ticket.prs) { pullRequest in
            Button {
              model.open(pullRequest.url)
            } label: {
              HStack(spacing: 6) {
                Image(
                  systemName: pullRequest.isMerged
                    ? "checkmark.arrow.trianglehead.branch" : "arrow.triangle.branch")
                Text("#\(pullRequest.number) \(pullRequest.title)").lineLimit(2)
                Spacer()
                Text(pullRequest.state?.lowercased() ?? "").foregroundStyle(.secondary)
              }.font(.system(size: 13))
            }.buttonStyle(.plain).accessibilityLabel(
              "Open pull request \(pullRequest.number): \(pullRequest.title)")
          }
        }
      }

      if !ticket.links.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          DetailLabel(text: "Evidence and links")
          ForEach(ticket.links) { link in
            Button {
              model.open(link.url)
            } label: {
              Label(link.label, systemImage: linkIcon(link.type)).font(.system(size: 13)).lineLimit(
                2
              ).frame(
                maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityLabel("Open \(link.label)")
          }
        }
      }

      if let review {
        ReviewDetail(review: review, retry: { model.retryReview(for: ticket) }, open: model.open)
      }

      if let message = model.actionMessages[ticket.id] {
        Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }

      HStack(spacing: 7) {
        Button("Focus terminal", systemImage: "terminal") { model.focusTerminal(for: ticket) }
          .buttonStyle(.bordered).accessibilityLabel(
            "Focus terminal for \(ticket.id)"
          ).accessibilityHint(
            "Focuses a matching WezTerm pane or opens a tab in the task directory."
          ).accessibilityIdentifier(
            "focus-terminal-\(ticket.id)")
        if let firstLink = ticket.links.first {
          Button("Open first link", systemImage: "arrow.up.right.square") {
            model.open(firstLink.url)
          }.buttonStyle(.bordered).accessibilityLabel(
            "Open first link for \(ticket.id)")
        }
        Spacer()
      }.controlSize(.regular)
    }.padding(.horizontal, 14).padding(.bottom, 14)
  }

  private var checkColor: Color {
    switch review?.status {
    case .running: QueueAccentPalette.color(.info, style: accentStyle)
    case .pending: QueueAccentPalette.color(.warning, style: accentStyle)
    case .accepted: QueueAccentPalette.color(.success, style: accentStyle)
    default: .secondary
    }
  }

  private var priorityColor: Color {
    switch ticket.priority.lowercased() {
    case "critical": QueueAccentPalette.color(.danger, style: accentStyle)
    case "high": QueueAccentPalette.color(.warning, style: accentStyle)
    case "medium": QueueAccentPalette.color(.info, style: accentStyle)
    default: .secondary
    }
  }

  private var statusColor: Color {
    switch ticket.status.lowercased() {
    case "blocked": QueueAccentPalette.color(.danger, style: accentStyle)
    case "in-progress": QueueAccentPalette.color(.info, style: accentStyle)
    case "backlog": .secondary
    default: QueueAccentPalette.color(.success, style: accentStyle)
    }
  }

  private func stepIcon(_ status: String) -> String {
    switch status.lowercased() {
    case "done": "checkmark.circle.fill"
    case "in-progress": "circle.lefthalf.filled"
    case "blocked": "exclamationmark.octagon.fill"
    default: "circle"
    }
  }

  private func stepColor(_ status: String) -> Color {
    switch status.lowercased() {
    case "done": QueueAccentPalette.color(.success, style: accentStyle)
    case "in-progress": QueueAccentPalette.color(.info, style: accentStyle)
    case "blocked": QueueAccentPalette.color(.danger, style: accentStyle)
    default: .secondary
    }
  }

  private func linkIcon(_ type: String?) -> String {
    switch type?.lowercased() {
    case "github": "arrow.triangle.branch"
    case "plan": "doc.text"
    case "file": "folder"
    default: "link"
    }
  }
}

private struct DetailLabel: View {
  let text: String

  var body: some View {
    Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.4).foregroundStyle(
      .secondary)
  }
}

private struct DetailBlock: View {
  let title: String
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      DetailLabel(text: title)
      Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(
        horizontal: false, vertical: true)
    }
  }
}

private struct StatusPill: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text.replacingOccurrences(of: "-", with: " ").uppercased()).font(
      .system(size: 10, weight: .bold)
    ).tracking(0.3).foregroundStyle(color).padding(
      .horizontal, 7
    ).padding(.vertical, 3).background(color.opacity(0.12), in: Capsule())
  }
}

private struct ReviewPill: View {
  let status: CompletionReviewStatus
  @Environment(\.queueAccentStyle) private var accentStyle

  var body: some View { StatusPill(text: status.rawValue, color: color) }

  private var color: Color {
    switch status {
    case .pending: QueueAccentPalette.color(.warning, style: accentStyle)
    case .running: QueueAccentPalette.color(.info, style: accentStyle)
    case .needsWork: QueueAccentPalette.color(.warning, style: accentStyle)
    case .accepted: QueueAccentPalette.color(.success, style: accentStyle)
    case .failed: QueueAccentPalette.color(.danger, style: accentStyle)
    }
  }
}

private struct ReviewDetail: View {
  let review: CompletionRequest
  let retry: () -> Void
  let open: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      DetailLabel(text: "Completion review")
      if let summary = review.summary, !summary.isEmpty {
        Text(summary).font(.system(size: 13)).lineLimit(6).fixedSize(
          horizontal: false, vertical: true)
      } else {
        Text(
          review.status == .running
            ? "Hermes is reviewing source evidence…" : "Queued for Hermes review."
        ).font(.system(size: 13)).foregroundStyle(
          .secondary)
      }
      HStack(spacing: 7) {
        if [.failed, .needsWork].contains(review.status) {
          Button("Review again", action: retry).buttonStyle(.link).accessibilityLabel(
            "Review completion again")
        }
        if let logPath = review.logPath {
          Button("Open log") { open(logPath) }.buttonStyle(.link).accessibilityLabel(
            "Open completion review log")
        }
      }.font(.system(size: 13))
    }.accessibilityElement(children: .contain)
  }
}

private struct NotificationSurfaceModifier: ViewModifier {
  let radius: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content.background {
      RoundedRectangle(cornerRadius: radius, style: .continuous).fill(
        QueuePalette.component(for: colorScheme))
    }.clipShape(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
    ).overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(
        QueuePalette.componentBorder(for: colorScheme), lineWidth: 0.75)
    }.shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.13), radius: 8, x: 0, y: 3)
  }
}

private struct PanelSurfaceModifier: ViewModifier {
  let radius: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content.background {
      RoundedRectangle(cornerRadius: radius, style: .continuous).fill(
        QueuePalette.panel(for: colorScheme))
    }.clipShape(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
    ).overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(
        QueuePalette.panelBorder(for: colorScheme), lineWidth: 2)
    }
  }
}

private enum QueuePalette {
  static let wezTermBackground = Color(red: 26 / 255, green: 29 / 255, blue: 35 / 255)
  static let lightComponent = Color(red: 240 / 255, green: 242 / 255, blue: 245 / 255)

  static func component(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? wezTermBackground : lightComponent
  }

  static func componentBorder(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.72)
  }

  static func panel(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? wezTermBackground.opacity(0.80) : Color.white.opacity(0.29)
  }

  static func panelBorder(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.white.opacity(0.20) : Color.gray.opacity(0.5)
  }
}

private enum QueueAccentRole {
  case danger
  case warning
  case info
  case success
}

private enum QueueAccentPalette {
  static func color(_ role: QueueAccentRole, style: QueueAccentStyle) -> Color {
    switch style {
    case .monochrome:
      return .secondary
    case .muted:
      switch role {
      case .danger: return Color(red: 0.73, green: 0.42, blue: 0.45)
      case .warning: return Color(red: 0.72, green: 0.55, blue: 0.34)
      case .info: return Color(red: 0.39, green: 0.59, blue: 0.68)
      case .success: return Color(red: 0.39, green: 0.62, blue: 0.50)
      }
    case .pastel:
      switch role {
      case .danger: return Color(red: 0.95, green: 0.57, blue: 0.64)
      case .warning: return Color(red: 0.96, green: 0.72, blue: 0.43)
      case .info: return Color(red: 0.49, green: 0.70, blue: 0.95)
      case .success: return Color(red: 0.49, green: 0.79, blue: 0.60)
      }
    case .vibrant:
      switch role {
      case .danger: return .red
      case .warning: return .orange
      case .info: return .blue
      case .success: return .green
      }
    }
  }
}

private struct QueueAccentStyleKey: EnvironmentKey {
  static let defaultValue = QueueAccentStyle.vibrant
}

extension EnvironmentValues {
  fileprivate var queueAccentStyle: QueueAccentStyle {
    get { self[QueueAccentStyleKey.self] }
    set { self[QueueAccentStyleKey.self] = newValue }
  }
}

extension View {
  fileprivate func notificationSurface(radius: CGFloat) -> some View {
    modifier(NotificationSurfaceModifier(radius: radius))
  }

  fileprivate func panelSurface(radius: CGFloat) -> some View {
    modifier(PanelSurfaceModifier(radius: radius))
  }
}
