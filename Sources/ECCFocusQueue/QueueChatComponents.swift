import FocusQueueCore
import SwiftUI

/// The message list shared by the task chat and the document chat.
struct QueueChatTranscript: View {
  let messages: [QueueChatMessage]
  let emptyText: String
  /// The label above agent messages, e.g. "ORCHESTRATOR".
  let agentLabel: String
  /// Shown as an animated row while a reply is pending; nil hides it.
  let progressText: String?
  @Environment(\.colorScheme) private var colorScheme

  static let progressID = "queue-agent-progress"

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          if messages.isEmpty {
            Text(emptyText)
              .font(.callout).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(14)
          }
          ForEach(messages) { message in
            QueueChatMessageRow(message: message, agentLabel: agentLabel).id(message.id)
          }
          if let progressText {
            HStack(spacing: 4) {
              Text(progressText)
                .font(.system(size: 12)).foregroundStyle(.secondary)
              QueueChatEllipsisIndicator()
              Spacer()
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(QueueChatMessageRow.surface(for: .agent, colorScheme: colorScheme))
            .id(Self.progressID)
          }
        }
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.automatic)
      .background(QueueChatMessageRow.surface(for: .agent, colorScheme: colorScheme), in: Rectangle())
      .clipShape(Rectangle())
      .overlay(Rectangle().stroke(Color.primary.opacity(0.10), lineWidth: 1))
      .onChange(of: messages.count) { _, _ in scrollToBottom(using: proxy) }
      .onChange(of: progressText != nil) { _, _ in scrollToBottom(using: proxy) }
    }
  }

  private func scrollToBottom(using proxy: ScrollViewProxy) {
    Task { @MainActor in
      await Task.yield()
      if progressText != nil {
        proxy.scrollTo(Self.progressID, anchor: .bottom)
      } else if let last = messages.last {
        proxy.scrollTo(last.id, anchor: .bottom)
      }
    }
  }
}

/// The rounded composer with its send/stop button and attached selection,
/// shared by the task chat and the document chat.
struct QueueChatComposer: View {
  @Binding var draft: String
  var isFocused: FocusState<Bool>.Binding
  var focusRequest: Int
  var maxHeight: CGFloat
  let placeholder: String
  let accessibilityLabel: String
  let isResponding: Bool
  /// Whether a non-empty draft may be sent now.
  let canSend: Bool
  let sendLabel: String
  let stopLabel: String
  var notice: String? = nil
  var selection: PlanCanvasSelection? = nil
  var clearSelection: () -> Void = {}
  var clearSelectionLabel = "Clear selected passage"
  let onSend: () -> Void
  let onStop: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 7) {
      if let notice {
        Text(notice).font(.caption).foregroundStyle(.secondary)
      }
      if let selection {
        selectionContext(selection)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
      HStack(alignment: .bottom, spacing: 4) {
        QueueChatComposerTextView(
          text: $draft, isFocused: isFocused, focusRequest: focusRequest,
          maxHeight: maxHeight, onSend: onSend)
          .fixedSize(horizontal: false, vertical: true)
          .overlay(alignment: .topLeading) {
            if draft.isEmpty {
              Text(placeholder)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
          }
          .padding(.leading, 13)
          .padding(.vertical, 11)
          .accessibilityLabel(accessibilityLabel)

        Button {
          if isResponding { onStop() } else { onSend() }
        } label: {
          Image(systemName: isResponding ? "stop.circle.fill" : "arrow.up.circle.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 42, height: 42)
            .padding(.trailing, 4)
        }
        .buttonStyle(.plain)
        .disabled(
          !isResponding && (!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        .accessibilityLabel(isResponding ? stopLabel : sendLabel)
      }
      .notificationSurface(radius: 16)
      .overlay {
        RoundedRectangle(cornerRadius: 16)
          .stroke(isFocused.wrappedValue ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
          .allowsHitTesting(false)
      }
    }
    .animation(.easeOut(duration: 0.16), value: selection?.id)
  }

  private func selectionContext(_ selection: PlanCanvasSelection) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: selection.kind.systemImage)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 24, height: 24)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
      VStack(alignment: .leading, spacing: 2) {
        Text([selection.kind.title, selection.readableLocation].compactMap { $0 }.joined(separator: " · "))
          .font(.system(size: 10.5, weight: .semibold))
        Text(selection.compactExcerpt)
          .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer(minLength: 2)
      Button(action: clearSelection) {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
          .frame(width: 40, height: 40)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(clearSelectionLabel)
      .help("Remove the selected passage from this message")
    }
    .padding(9)
    .background(
      Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.07),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
        .allowsHitTesting(false)
    )
  }
}

/// Provider, model, and effort pickers in the chat settings bar.
struct QueueChatAgentMenus: View {
  let provider: AgentProvider
  let model: String?
  let effort: String?
  let modelChoices: [AgentModelChoice]
  var providerEnabled = true
  var providerDisabledHelp = "Choose the chat provider"
  let setProvider: (AgentProvider) -> Void
  let setModel: (String?) -> Void
  let setEffort: (String?) -> Void

  var body: some View {
    HStack(spacing: 8) {
      providerMenu
      modelMenu
      effortMenu
    }
  }

  private var providerMenu: some View {
    Menu {
      ForEach(AgentProvider.allCases, id: \.self) { choice in
        Button {
          setProvider(choice)
        } label: {
          if provider == choice {
            Label(choice.displayName, systemImage: "checkmark")
          } else {
            Text(choice.displayName)
          }
        }
      }
    } label: {
      Self.label(provider.displayName)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(!providerEnabled)
    .accessibilityLabel("Chat provider: \(provider.displayName)")
    .help(providerEnabled ? "Choose the chat provider" : providerDisabledHelp)
  }

  private var modelMenu: some View {
    let current = model ?? ""
    let currentLabel = modelChoices.first { ($0.model ?? "") == current }?.label
      ?? (current.isEmpty ? "Default" : current)
    return Menu {
      ForEach(modelChoices) { choice in
        Button {
          setModel(choice.model)
        } label: {
          if (choice.model ?? "") == current {
            Label(choice.label, systemImage: "checkmark")
          } else {
            Text(choice.label)
          }
        }
      }
    } label: {
      Self.label(currentLabel)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Chat model: \(currentLabel)")
    .help("Choose the chat model")
  }

  private var effortMenu: some View {
    let current = effort ?? ""
    return Menu {
      Button {
        setEffort(nil)
      } label: {
        if current.isEmpty {
          Label("Default", systemImage: "checkmark")
        } else {
          Text("Default")
        }
      }
      ForEach(AppConfiguration.agentEffortLevels(for: provider), id: \.self) { level in
        Button {
          setEffort(level)
        } label: {
          if current == level {
            Label(level, systemImage: "checkmark")
          } else {
            Text(level)
          }
        }
      }
    } label: {
      Self.label(current.isEmpty ? "Default" : current)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Chat effort: \(current.isEmpty ? "Default" : current)")
    .help("Choose the chat reasoning effort")
  }

  static func label(_ text: String) -> some View {
    HStack(spacing: 3) {
      Text(text).font(.caption).lineLimit(1).foregroundStyle(.primary)
      Image(systemName: "chevron.down")
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(.secondary)
    }
  }
}

/// The rounded bar that holds a chat's title, pickers, and Clear Chat.
struct QueueChatSettingsBar<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) { content }
      .padding(.horizontal, 8).padding(.vertical, 7)
      .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1)
          .allowsHitTesting(false)
      )
  }
}

/// Cycles ".", "..", "...", then a blank frame instead of a spinner.
struct QueueChatEllipsisIndicator: View {
  private static let frames = [".", "..", "...", " "]
  private static let frameInterval: TimeInterval = 0.4

  var body: some View {
    TimelineView(.periodic(from: .now, by: Self.frameInterval)) { context in
      let index = Int(context.date.timeIntervalSince1970 / Self.frameInterval)
      Text(Self.frames[index % Self.frames.count])
        .font(.system(size: 12, weight: .bold, design: .monospaced))
        .foregroundStyle(.secondary)
        .fixedSize()
        .lineLimit(1)
        .frame(minWidth: 16, alignment: .leading)
    }
  }
}
