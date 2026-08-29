import FocusQueueCore
import SwiftUI

struct QueueView: View {
    let model: QueueViewModel
    @State private var showsMoreTasks = false

    private var focusTickets: [DashboardTicket] { Array(model.openTickets.prefix(5)) }

    private var remainingTickets: [DashboardTicket] { Array(model.openTickets.dropFirst(5)) }

    var body: some View {
        VStack(spacing: 10) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    SectionHeading(title: "Today's focus", detail: "Top \(focusTickets.count)")

                    if focusTickets.isEmpty {
                        ContentUnavailableView(
                            "Queue is clear", systemImage: "checkmark.circle", description: Text("No open tasks are present in the dashboard.")
                        ).frame(maxWidth: .infinity).notificationSurface(radius: 18)
                    } else {
                        ForEach(focusTickets) { ticket in TicketCard(ticket: ticket, model: model) }
                    }

                    if showsMoreTasks { additionalQueue.transition(.opacity.combined(with: .move(edge: .bottom))) }
                }.padding(.horizontal, 2).padding(.vertical, 2)
            }.scrollIndicators(.automatic)

            if !remainingTickets.isEmpty || !model.config.dailyRoutines.isEmpty { moreButton }
        }.padding(12).frame(minWidth: 380, idealWidth: 440, maxWidth: .infinity, minHeight: 480, idealHeight: 700, maxHeight: .infinity).panelSurface(
            radius: 30
        ).preferredColorScheme(.light)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(model.loadError == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                syncLabel
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                }.buttonStyle(.plain).frame(width: 32, height: 32).disabled(model.isRefreshing).accessibilityLabel("Refresh task dashboard").help("Refresh now")
            }
            HStack(alignment: .firstTextBaseline) {
                Text("ECC Focus Queue").font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer()
                Text("\(model.openTickets.count) active").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2)
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
                SectionHeading(title: "Daily checklist", detail: "\(model.completedRoutineCount)/\(model.config.dailyRoutines.count)")
                VStack(spacing: 1) {
                    ForEach(model.config.dailyRoutines) { routine in
                        RoutineRow(
                            routine: routine, isComplete: model.routineIsComplete(routine.id), toggle: { model.toggleRoutine(routine.id) },
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
                Image(systemName: showsMoreTasks ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .bold))
                Text(showsMoreTasks ? "Show only top five" : moreButtonLabel).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(showsMoreTasks ? "" : "\(remainingTickets.count) more").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(
                    .secondary)
            }.padding(.horizontal, 15).frame(height: 46).contentShape(Rectangle())
        }.buttonStyle(.plain).notificationSurface(radius: 16).accessibilityLabel(showsMoreTasks ? "Show only top five tasks" : "View more tasks")
    }

    private var moreButtonLabel: String { remainingTickets.isEmpty ? "View daily checklist" : "View more tasks" }
}

private struct SectionHeading: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.7)
            Spacer()
            Text(detail).font(.system(size: 11, weight: .semibold).monospacedDigit())
        }.foregroundStyle(.secondary).padding(.horizontal, 11).frame(height: 27).background(
            Color(red: 0.94, green: 0.95, blue: 0.96).opacity(0.55), in: Capsule()
        ).overlay { Capsule().stroke(Color.white.opacity(0.4), lineWidth: 0.6) }
    }
}

private struct RoutineRow: View {
    let routine: DailyRoutine
    let isComplete: Bool
    let toggle: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: toggle) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle").foregroundStyle(isComplete ? Color.green : Color.secondary).font(
                    .system(size: 18))
            }.buttonStyle(.plain).frame(minWidth: 36, minHeight: 36).accessibilityLabel(
                isComplete ? "Mark \(routine.title) incomplete" : "Mark \(routine.title) complete"
            ).accessibilityHint("This daily state stays on this computer and resets tomorrow.").help(isComplete ? "Mark incomplete" : "Mark complete for today")

            Text(routine.title).font(.system(size: 15, weight: .medium)).strikethrough(isComplete, color: .secondary).foregroundStyle(
                isComplete ? .secondary : .primary
            ).frame(maxWidth: .infinity, alignment: .leading)

            if routine.url != nil {
                Button(action: open) { Image(systemName: "arrow.up.right.square").font(.caption) }.buttonStyle(.borderless).frame(minWidth: 36, minHeight: 36)
                    .accessibilityLabel("Open \(routine.title)").help("Open queue")
            }
        }.padding(.horizontal, 12).padding(.vertical, 5)
    }
}

private struct TicketCard: View {
    let ticket: DashboardTicket
    let model: QueueViewModel

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
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle").font(.system(size: 20, weight: .medium)).foregroundStyle(checkColor)
                }.buttonStyle(.plain).disabled(review?.status == .running).frame(width: 40, height: 36).accessibilityLabel(
                    "Request completion review for \(ticket.id)"
                ).accessibilityHint("Queues Hermes evidence review without directly closing the task.").help("Queue an evidence-based Hermes completion review")

                Button {
                    toggleExpansion()
                } label: {
                    Image(systemName: model.isExpanded(ticket.id) ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(
                        .secondary)
                }.buttonStyle(.plain).frame(width: 40, height: 32).accessibilityLabel(
                    model.isExpanded(ticket.id) ? "Hide details for \(ticket.id)" : "Show details for \(ticket.id)")
            }

            Button(action: toggleExpansion) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(ticket.title).font(.system(size: 16, weight: .semibold)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(ticket.progressLabel).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                            Text(ticket.id).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(priorityColor).fixedSize()
                        }
                    }
                    HStack(spacing: 6) {
                        StatusPill(text: ticket.priority, color: priorityColor)
                        StatusPill(text: ticket.status, color: statusColor)
                        if let review { ReviewPill(status: review.status) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(ticket.title), \(ticket.progressLabel), \(ticket.id)").accessibilityHint(
                model.isExpanded(ticket.id) ? "Hides task details." : "Shows task details."
            ).help(model.isExpanded(ticket.id) ? "Hide task details" : "Show task details")
        }.padding(.horizontal, 13).padding(.vertical, 11)
    }

    private func toggleExpansion() { withAnimation(.easeInOut(duration: 0.18)) { model.setExpanded(!model.isExpanded(ticket.id), ticketID: ticket.id) } }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailBlock(title: "Summary", text: ticket.summary)
            if let next = ticket.next, !next.isEmpty { DetailBlock(title: "Next", text: next) }
            if let doneWhen = ticket.doneWhen, !doneWhen.isEmpty { DetailBlock(title: "Done when", text: doneWhen) }

            if !ticket.steps.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    DetailLabel(text: "Progress")
                    ForEach(ticket.steps) { step in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: stepIcon(step.status)).foregroundStyle(stepColor(step.status)).frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.label).font(.system(size: 13))
                                ForEach(step.evidence, id: \.self) { evidence in
                                    Button {
                                        model.open(evidence)
                                    } label: {
                                        Text(URL(fileURLWithPath: evidence).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                    }.buttonStyle(.link).accessibilityLabel("Open evidence \(URL(fileURLWithPath: evidence).lastPathComponent)")
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
                                Image(systemName: pullRequest.isMerged ? "checkmark.arrow.trianglehead.branch" : "arrow.triangle.branch")
                                Text("#\(pullRequest.number) \(pullRequest.title)").lineLimit(2)
                                Spacer()
                                Text(pullRequest.state?.lowercased() ?? "").foregroundStyle(.secondary)
                            }.font(.system(size: 13))
                        }.buttonStyle(.plain).accessibilityLabel("Open pull request \(pullRequest.number): \(pullRequest.title)")
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
                            Label(link.label, systemImage: linkIcon(link.type)).font(.system(size: 13)).lineLimit(2).frame(
                                maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityLabel("Open \(link.label)")
                    }
                }
            }

            if let review { ReviewDetail(review: review, retry: { model.retryReview(for: ticket) }, open: model.open) }

            if let message = model.actionMessages[ticket.id] {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 7) {
                Button("Focus terminal", systemImage: "terminal") { model.focusTerminal(for: ticket) }.buttonStyle(.bordered).accessibilityLabel(
                    "Focus terminal for \(ticket.id)"
                ).accessibilityHint("Focuses a matching WezTerm pane or opens a tab in the task directory.").accessibilityIdentifier(
                    "focus-terminal-\(ticket.id)")
                if let firstLink = ticket.links.first {
                    Button("Open first link", systemImage: "arrow.up.right.square") { model.open(firstLink.url) }.buttonStyle(.bordered).accessibilityLabel(
                        "Open first link for \(ticket.id)")
                }
                Spacer()
            }.controlSize(.regular)
        }.padding(.horizontal, 14).padding(.bottom, 14)
    }

    private var checkColor: Color {
        switch review?.status {
        case .running: .blue
        case .pending: .orange
        case .accepted: .green
        default: .secondary
        }
    }

    private var priorityColor: Color {
        switch ticket.priority.lowercased() {
        case "critical": .red
        case "high": .orange
        case "medium": .blue
        default: .secondary
        }
    }

    private var statusColor: Color {
        switch ticket.status.lowercased() {
        case "blocked": .red
        case "in-progress": .blue
        case "backlog": .secondary
        default: .green
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
        case "done": .green
        case "in-progress": .blue
        case "blocked": .red
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

    var body: some View { Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.4).foregroundStyle(.secondary) }
}

private struct DetailBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            DetailLabel(text: title)
            Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.replacingOccurrences(of: "-", with: " ").uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.3).foregroundStyle(color).padding(
            .horizontal, 7
        ).padding(.vertical, 3).background(color.opacity(0.12), in: Capsule())
    }
}

private struct ReviewPill: View {
    let status: CompletionReviewStatus

    var body: some View { StatusPill(text: status.rawValue, color: color) }

    private var color: Color {
        switch status {
        case .pending: .orange
        case .running: .blue
        case .needsWork: .orange
        case .accepted: .green
        case .failed: .red
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
                Text(summary).font(.system(size: 13)).lineLimit(6).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(review.status == .running ? "Hermes is reviewing source evidence…" : "Queued for Hermes review.").font(.system(size: 13)).foregroundStyle(
                    .secondary)
            }
            HStack(spacing: 7) {
                if [.failed, .needsWork].contains(review.status) {
                    Button("Review again", action: retry).buttonStyle(.link).accessibilityLabel("Review completion again")
                }
                if let logPath = review.logPath { Button("Open log") { open(logPath) }.buttonStyle(.link).accessibilityLabel("Open completion review log") }
            }.font(.system(size: 13))
        }.accessibilityElement(children: .contain)
    }
}

private struct NotificationSurfaceModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.background { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(red: 0.94, green: 0.95, blue: 0.96).opacity(0.76)) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)).overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.5), lineWidth: 0.75)
            }.shadow(color: Color.black.opacity(0.13), radius: 8, x: 0, y: 3)
    }
}

private struct PanelSurfaceModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial).opacity(0.14)
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.03))
            }
        }.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)).overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.gray.opacity(0.5), lineWidth: 2)
        }
    }
}

extension View {
    fileprivate func notificationSurface(radius: CGFloat) -> some View { modifier(NotificationSurfaceModifier(radius: radius)) }

    fileprivate func panelSurface(radius: CGFloat) -> some View { modifier(PanelSurfaceModifier(radius: radius)) }
}
