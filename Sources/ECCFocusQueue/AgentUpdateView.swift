import Foundation
import FocusQueueCore
import SwiftUI

struct QueueAgentUpdate: Identifiable, Equatable {
  let id: String
  let ticketID: String
  let title: String
  let summary: String
  var review: CompletionRequest? = nil
  var subtaskID: String? = nil
  var date: Date = .distantPast
  var isCleanup = false
  var resultID: String? = nil

  var conciseReason: String { CompletionExplanation.concise(summary) }
}

struct AgentUpdateView: View {
  let model: QueueViewModel
  let update: QueueAgentUpdate
  @State private var reviewOutput = ""
  @State private var logError: String?
  @Binding var draft: String

  private var ticket: DashboardTicket? {
    model.dashboard.tickets.first { $0.id == update.ticketID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(update.conciseReason).font(.title3.bold()).lineLimit(4)
          Text(update.title).font(.caption).foregroundStyle(.secondary)
          Text(update.ticketID).font(.caption).foregroundStyle(.secondary)
          if update.date != .distantPast {
            Text(update.date.formatted(date: .abbreviated, time: .shortened))
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if model.agentUpdates.count > 1 {
          Menu("Updates (\(model.agentUpdates.count))") {
            ForEach(model.agentUpdates) { item in
              Button("\(item.ticketID) · \(item.title)") { model.openAgentUpdate(item) }
            }
          }.fixedSize().accessibilityLabel("Choose another agent update")
        }
        Button { model.closeAgentUpdate() } label: { Image(systemName: "xmark") }
          .buttonStyle(.bordered).accessibilityLabel("Close agent update")
      }
      if update.review != nil, let ticket,
         let subtask = model.subtasks(for: ticket.id).first(where: { $0.id == update.subtaskID }) {
        HStack {
          Button("Override: mark complete") { model.overrideCompletion(subtask, for: ticket) }
            .buttonStyle(.borderedProminent)
          Button(subtask.isAssignmentOnly ? "Remove agents" : "Remove agent") { model.removeAgent(subtask, from: ticket); model.closeAgentUpdate() }
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(update.summary.isEmpty ? "The agent recorded completion without a summary." : update.summary)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          if let ticket {
            LabeledContent("Task status", value: ticket.status)
            LabeledContent("Task type", value: ticket.queueTaskKind.title)
            if let review = update.review {
              LabeledContent("Review verdict", value: review.status.rawValue)
              if let criteria = ticket.doneWhen, !criteria.isEmpty {
                Text("Completion criteria").font(.headline)
                Text(criteria).textSelection(.enabled)
              }
              if !reviewOutput.isEmpty {
                Text("Verifier output").font(.headline)
                Text(reviewOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              }
              if let logError { Text(logError).font(.caption).foregroundStyle(.orange) }
              HStack {
                Button("Review again") {
                  if let subtaskID = review.subtaskID,
                     let subtask = model.subtasks(for: ticket.id).first(where: { $0.id == subtaskID }) {
                    model.requestSubtaskCompletion(subtask, for: ticket)
                  } else { model.retryReview(for: ticket) }
                }.disabled(model.localState.completionRequests.contains {
                  $0.ticketID == ticket.id && $0.subtaskID == review.subtaskID && [.pending, .running].contains($0.status)
                })
                if let path = review.logPath { Button("Open full log") { model.open(path) } }
              }
            }
            if update.isCleanup {
              Button("Retry task cleanup") { model.retryCleanup(for: ticket) }
            }
            if let subtaskID = update.subtaskID,
               let subtask = model.subtasks(for: ticket.id).first(where: { $0.id == subtaskID }),
               let session = model.session(for: subtask, ticketID: ticket.id) {
              Button { model.viewAgent(session, for: ticket) } label: {
                if model.isOpening(session) {
                  HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Opening agent session…")
                  }
                } else {
                  Label("Open agent session", systemImage: "terminal")
                }
              }
              .disabled(model.isOpening(session))
              .accessibilityLabel(
                model.isOpening(session) ? "Opening agent session" : "Open agent session"
              )
            }
            DisclosureGroup("Context, evidence & links") { TaskContextLinksView(ticket: ticket, model: model) }
          }
          if !model.chatMessages(ticketID: update.ticketID).isEmpty {
            Text("Task conversation").font(.headline)
            ForEach(model.chatMessages(ticketID: update.ticketID)) { message in
              VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .agent ? "Agent" : "You").font(.caption.bold()).foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
              }.padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
          }
          if let message = model.actionMessages[update.ticketID] {
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      if model.isQueueAgentResponding && model.respondingTicketID == update.ticketID {
        ProgressView("Waiting for the agent response…").controlSize(.small)
      }
      HStack {
        TextField("Ask about this update", text: $draft).textFieldStyle(.roundedBorder)
          .onSubmit(send)
        Button("Send", action: send)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isQueueAgentResponding || model.isDailyReportRunning)
      }
    }.padding(14).frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
      .background(.background, in: RoundedRectangle(cornerRadius: 14))
      .task(id: update.id) {
        reviewOutput = ""
        logError = nil
        await model.acknowledgeAgentUpdate(update)
        guard let path = update.review?.logPath else { return }
        do {
          let output = try await Task.detached {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            let length = try file.seekToEnd()
            let limit: UInt64 = 128 * 1024
            try file.seek(toOffset: length > limit ? length - limit : 0)
            return (length > limit ? "Showing the last 128 KB. Use Open full log for earlier output.\n\n" : "")
              + String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
          }.value
          guard !Task.isCancelled else { return }
          reviewOutput = output
        } catch {
          guard !Task.isCancelled else { return }
          logError = "Could not read verifier output: \(error.localizedDescription)"
        }
      }
  }

  private func send() {
    guard !model.isQueueAgentResponding, !model.isDailyReportRunning,
          !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    model.sendQueueAgentMessage("Regarding the update \"\(update.title)\": \(update.summary)\n\n\(draft)", ticketID: update.ticketID)
    draft = ""
  }
}

struct TaskContextLinksView: View {
  let ticket: DashboardTicket
  let model: QueueViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Button("View Central Plan", systemImage: "doc.text") { model.openPlan(for: ticket) }
      if let context = model.taskContexts[ticket.id] {
        Button("Open context folder", systemImage: "folder") { model.open(context.contextDirectory.path) }
      }
      ForEach(ticket.links) { link in
        Button(link.label, systemImage: "link") { open(link.url) }.multilineTextAlignment(.leading)
      }
      ForEach(Array(Set(ticket.steps.flatMap(\.evidence))).sorted(), id: \.self) { evidence in
        Button(ResourceLocator.url(for: evidence)?.lastPathComponent ?? evidence, systemImage: "doc") { open(evidence) }
          .multilineTextAlignment(.leading)
      }
      ForEach(ticket.prs) { pr in
        Button("PR #\(pr.number): \(pr.title)", systemImage: "arrow.triangle.branch") { model.open(pr.url) }
          .multilineTextAlignment(.leading)
      }
      if ticket.links.isEmpty && ticket.steps.allSatisfy({ $0.evidence.isEmpty }) && ticket.prs.isEmpty {
        Text("No additional evidence or links have been attached.").font(.caption).foregroundStyle(.secondary)
      }
    }.buttonStyle(.link).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
  }

  private func open(_ value: String) {
    if let url = ResourceLocator.url(for: value), let document = EmbeddedDocumentLink.documentURL(url) {
      model.openPlan(for: ticket, sourceURL: document)
    } else { model.open(value) }
  }
}
