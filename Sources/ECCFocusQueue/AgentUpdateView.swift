import Foundation
import FocusQueueCore
import SwiftUI

struct QueueAgentUpdate: Identifiable, Equatable {
  let id: String
  let ticketID: String
  let title: String
  let summary: String
  var subtaskID: String? = nil
  var date: Date = .distantPast
  var isCleanup = false
  var resultID: String? = nil

  var conciseReason: String { CompletionExplanation.concise(summary) }
  var presentationID: String { id + ":" + (resultID ?? String(date.timeIntervalSince1970)) }
}

struct AgentUpdateView: View {
  let model: QueueViewModel
  let update: QueueAgentUpdate
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
        Button("Dismiss") { model.dismissAgentUpdate(update) }
          .buttonStyle(.bordered).help("Hide this update and keep its history")
        Button { model.closeAgentUpdate() } label: { Image(systemName: "xmark") }
          .buttonStyle(.bordered).accessibilityLabel("Close agent update")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(update.summary.isEmpty ? "The agent recorded completion without a summary." : update.summary)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          if let ticket {
            LabeledContent("Task status", value: ticket.status)
            LabeledContent("Task type", value: ticket.queueTaskKind.title)
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
            DisclosureGroup("View Context") {
              TaskContextGridView(ticket: ticket, model: model).frame(height: 320)
            }
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
      if model.isChatResponding(ticketID: update.ticketID) {
        ProgressView("Waiting for the agent response…").controlSize(.small)
      }
      HStack {
        TextField("Ask about this update", text: $draft).textFieldStyle(.roundedBorder)
          .onSubmit(send)
        Button("Send", action: send)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isChatResponding(ticketID: update.ticketID) || model.reportIsRunning)
      }
    }.padding(14).frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
      .background(.background, in: RoundedRectangle(cornerRadius: 14))
      .task(id: update.presentationID) {
        await model.acknowledgeAgentUpdate(update)
      }
  }

  private func send() {
    guard !model.isChatResponding(ticketID: update.ticketID), !model.reportIsRunning,
          !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    model.sendQueueAgentMessage("Regarding the update \"\(update.title)\": \(update.summary)\n\n\(draft)", ticketID: update.ticketID)
    draft = ""
  }
}
