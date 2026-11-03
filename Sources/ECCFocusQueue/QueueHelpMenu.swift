import AppKit
import SwiftUI

/// Destinations behind the header's info menu. A nil link shows its menu item
/// as "coming soon" until the destination exists.
enum QueueHelpLinks {
  /// Fill in once the documentation site is published.
  static let documentation: URL? = nil
  static let repository: URL? = URL(string: "https://github.com/haelyra/FocusQueue")
  /// Optional email fallback for people without a GitHub account.
  static let feedbackEmail: String? = nil
  /// Matches `.github/ISSUE_TEMPLATE/feedback.yml`, which labels every report.
  static let feedbackIssueTemplate = "feedback.yml"
}

enum FeedbackKind: String, CaseIterable, Identifiable {
  case bug = "Bug"
  case suggestion = "Suggestion"
  case question = "Question"
  case other = "Other"

  var id: String { rawValue }
}

/// A feedback report turned into a prefilled GitHub issue or email. The issue
/// form applies the triage labels, so no token ships inside the app.
struct FeedbackDraft: Equatable {
  /// GitHub rejects very long URLs; longer details are cut with a note.
  static let maximumDetailsLength = 4_000

  var kind: FeedbackKind = .suggestion
  var title = ""
  var details = ""
  var includesEnvironment = true

  var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
  var trimmedDetails: String { details.trimmingCharacters(in: .whitespacesAndNewlines) }
  var canSubmit: Bool { !trimmedTitle.isEmpty || !trimmedDetails.isEmpty }

  var issueTitle: String {
    let summary = trimmedTitle.isEmpty ? String(trimmedDetails.prefix(80)) : trimmedTitle
    return "\(kind.rawValue): \(summary)"
  }

  var boundedDetails: String {
    guard trimmedDetails.count > Self.maximumDetailsLength else { return trimmedDetails }
    return String(trimmedDetails.prefix(Self.maximumDetailsLength)) + "\n\n[Details shortened to fit the link.]"
  }

  static var environmentSummary: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let app = [version, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return "Focus Queue \(app.isEmpty ? "development build" : app) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
  }

  func issueURL(repository: URL, environment: String = Self.environmentSummary) -> URL? {
    guard var components = URLComponents(
      url: repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false
    ) else { return nil }
    var items = [
      URLQueryItem(name: "template", value: QueueHelpLinks.feedbackIssueTemplate),
      URLQueryItem(name: "title", value: issueTitle),
      URLQueryItem(name: "kind", value: kind.rawValue),
      URLQueryItem(name: "details", value: boundedDetails),
    ]
    if includesEnvironment { items.append(URLQueryItem(name: "environment", value: environment)) }
    components.queryItems = items
    return components.url
  }

  func emailURL(to address: String, environment: String = Self.environmentSummary) -> URL? {
    var body = boundedDetails
    if includesEnvironment { body += "\n\n---\n\(environment)" }
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = address
    components.queryItems = [
      URLQueryItem(name: "subject", value: "[Focus Queue] \(issueTitle)"),
      URLQueryItem(name: "body", value: body),
    ]
    return components.url
  }
}

/// The header's info button: documentation, the repository, the walkthrough,
/// and feedback. Replaces the old notifications bell.
struct QueueHelpMenu: View {
  let sendFeedback: () -> Void
  /// Nil until the walkthrough ships; the item then reads "coming soon".
  var replayWalkthrough: (() -> Void)?

  var body: some View {
    Menu {
      linkItem("Documentation", systemImage: "book", url: QueueHelpLinks.documentation)
      linkItem("GitHub repository", systemImage: "chevron.left.forwardslash.chevron.right",
        url: QueueHelpLinks.repository)
      Button(
        replayWalkthrough == nil ? "Replay walkthrough (coming soon)" : "Replay walkthrough",
        systemImage: "play.circle"
      ) { replayWalkthrough?() }
        .disabled(replayWalkthrough == nil)
      Divider()
      Button("Send feedback…", systemImage: "bubble.left.and.exclamationmark.bubble.right") {
        sendFeedback()
      }
    } label: {
      Image(systemName: "info.circle").font(.system(size: 13, weight: .semibold))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Help and feedback")
    .help("Help, documentation, and feedback")
  }

  @ViewBuilder private func linkItem(_ title: String, systemImage: String, url: URL?) -> some View {
    Button(url == nil ? "\(title) (coming soon)" : title, systemImage: systemImage) {
      if let url { NSWorkspace.shared.open(url) }
    }
    .disabled(url == nil)
  }
}

struct FeedbackSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft = FeedbackDraft()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Send feedback").font(.title2.bold())
      Text("Report a bug, suggest an idea, or ask a question. Submitting opens a prefilled GitHub issue you can review before posting.")
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Picker("Type", selection: $draft.kind) {
        ForEach(FeedbackKind.allCases) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).labelsHidden()
      TextField("Short summary", text: $draft.title).textFieldStyle(.roundedBorder)
      TextEditor(text: $draft.details)
        .font(.body)
        .frame(minHeight: 140)
        .padding(4)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
          if draft.details.isEmpty {
            Text("What happened, what you expected, or what would help")
              .foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4)
              .allowsHitTesting(false)
          }
        }
        .accessibilityLabel("Feedback details")
      Toggle("Include app and macOS versions", isOn: $draft.includesEnvironment)
      Text(FeedbackDraft.environmentSummary).font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        if let address = QueueHelpLinks.feedbackEmail, let url = draft.emailURL(to: address) {
          Button("Email") { submit(url) }.disabled(!draft.canSubmit)
        }
        if let repository = QueueHelpLinks.repository, let url = draft.issueURL(repository: repository) {
          Button("Open GitHub issue") { submit(url) }
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canSubmit)
        }
      }
    }
    .padding(20)
    .frame(width: 460)
  }

  private func submit(_ url: URL) {
    NSWorkspace.shared.open(url)
    dismiss()
  }
}
