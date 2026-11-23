import FocusQueueCore
import SwiftUI

/// The T3 Code part of an agent row: state notes, the open question with its
/// options, a follow-up prompt, and Open in T3 Code. There are no approve or
/// deny controls because T3 Code does not let outside apps answer approvals.
struct T3AgentRowDetails: View {
  let agent: TaskSubtask
  let ticket: DashboardTicket
  let model: QueueViewModel
  @State private var prompt = ""
  @State private var selections: [String: String] = [:]
  @State private var freeText: [String: String] = [:]
  @State private var showsPrompt = false

  private var presentation: T3RowPresentation { T3RowPresentation.make(agent) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        if let badge = presentation.badge {
          Text(badge)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(badgeColor.opacity(0.18), in: Capsule())
        }
        ForEach(presentation.notes, id: \.self) { note in
          Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        Spacer(minLength: 0)
        if presentation.actions.contains(.openInT3) {
          Button("Open in T3 Code", systemImage: "arrow.up.forward.app") { model.openT3Thread(agent, for: ticket) }
            .buttonStyle(.borderless).font(.system(size: 11))
        }
        if presentation.actions.contains(.removeAgent) {
          Button("Remove agent", systemImage: "trash") { model.removeMissingT3Agent(agent, for: ticket) }
            .buttonStyle(.borderless).font(.system(size: 11))
        }
        if presentation.actions.contains(.sendPrompt) {
          Button(showsPrompt ? "Hide prompt" : "Prompt", systemImage: "text.bubble") { showsPrompt.toggle() }
            .buttonStyle(.borderless).font(.system(size: 11))
        }
      }
      if presentation.actions.contains(.answer) { questionView }
      if showsPrompt, presentation.actions.contains(.sendPrompt) {
        HStack(spacing: 6) {
          TextField("Follow-up for \(agent.title)", text: $prompt, axis: .vertical)
            .textFieldStyle(.roundedBorder).lineLimit(1...4)
            .onSubmit(send)
          Button("Send", action: send).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .onAppear { model.acknowledgeT3(agent, for: ticket) }
    .onChange(of: agent.t3?.openQuestionIds) { _, ids in
      selections = [:]; freeText = [:]
      if ids?.isEmpty == false { model.loadT3Question(agent, for: ticket) }
    }
  }

  @ViewBuilder private var questionView: some View {
    if let request = model.t3Question(for: agent, ticketID: ticket.id) {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(request.questions, id: \.id) { question in
          VStack(alignment: .leading, spacing: 4) {
            if let header = question.header, !header.isEmpty {
              Text(header).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(question.question).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            ForEach(question.options, id: \.label) { option in
              Button {
                selections[question.id] = option.label
              } label: {
                HStack(alignment: .top, spacing: 6) {
                  Image(systemName: selections[question.id] == option.label ? "largecircle.fill.circle" : "circle")
                  VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 11, weight: .medium))
                    if let detail = option.description, !detail.isEmpty {
                      Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                  }
                }
              }
              .buttonStyle(.plain)
            }
            TextField("Or type an answer", text: Binding(
              get: { freeText[question.id] ?? "" }, set: { freeText[question.id] = $0 }))
              .textFieldStyle(.roundedBorder).font(.system(size: 11))
          }
        }
        Button("Submit answer") {
          model.answerT3Question(agent, for: ticket, request: request, selections: selections, freeText: freeText)
        }
        .disabled(!T3AnswerBuilder.isComplete(request, selections: selections, freeText: freeText))
      }
      .padding(8)
      .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    } else {
      Button("Answer", systemImage: "questionmark.bubble") { model.loadT3Question(agent, for: ticket) }
        .buttonStyle(.borderless).font(.system(size: 11))
        .onAppear { model.loadT3Question(agent, for: ticket) }
    }
  }

  private var badgeColor: Color {
    switch presentation.badge {
    case T3RowPresentation.needsAnswer, T3RowPresentation.needsApproval: .orange
    case T3RowPresentation.threadMissing, T3RowPresentation.unreachable, T3RowPresentation.otherServer: .red
    default: .secondary
    }
  }

  private func send() {
    let text = prompt
    prompt = ""
    model.sendT3Prompt(agent, for: ticket, text: text)
  }
}
