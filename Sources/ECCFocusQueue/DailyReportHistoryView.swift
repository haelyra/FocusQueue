import FocusQueueCore
import SwiftUI

struct DailyReportHistoryView: View {
  let snapshot: DailyReportHistorySnapshot
  let onSelectReport: (DailyReportDocument) -> Void
  @State private var visibleReportCount = 20

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if snapshot.reports.isEmpty && snapshot.runs.isEmpty {
        Text("Past reports and run results will appear here.")
          .font(.callout).foregroundStyle(.secondary)
      }
      ForEach(snapshot.reports.prefix(visibleReportCount)) { report in
        Button { onSelectReport(report) } label: {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: snapshot.isUnread(report) ? "circle.fill" : "doc.text")
              .font(.caption).foregroundStyle(snapshot.isUnread(report) ? Color.accentColor : .secondary)
              .accessibilityLabel(snapshot.isUnread(report) ? "Unread" : "Viewed")
            VStack(alignment: .leading, spacing: 3) {
              Text("\(report.reportDate ?? String(report.finishedAt.prefix(10))) · \(report.status.rawValue.capitalized)")
                .font(.callout.weight(.medium))
              Text(report.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Open this daily report")
        Divider()
      }
      if snapshot.reports.count > visibleReportCount {
        Button("Show more reports (\(snapshot.reports.count - visibleReportCount) remaining)") {
          visibleReportCount += 20
        }.font(.caption)
      }
      if !snapshot.runs.isEmpty {
        DisclosureGroup("Run history (\(snapshot.runs.count))") {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(snapshot.runs) { run in
              VStack(alignment: .leading, spacing: 3) {
                Text("\(run.phase.rawValue.capitalized) · \(run.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(run.phase == .failed || run.phase == .interrupted ? Color.orange : .primary)
                Text(run.message).font(.caption).textSelection(.enabled)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
          }.padding(.top, 8)
        }
      }
      if !snapshot.standardOutput.isEmpty || !snapshot.standardError.isEmpty {
        DisclosureGroup("Recent run logs") {
          VStack(alignment: .leading, spacing: 8) {
            Text("Most recent 32 KB per log; logs can contain source message details.")
              .font(.caption).foregroundStyle(.secondary)
            if !snapshot.standardError.isEmpty { log(snapshot.standardError, title: "Errors") }
            if !snapshot.standardOutput.isEmpty { log(snapshot.standardOutput, title: "Output") }
          }.padding(.top, 8)
        }
      }
      ForEach(snapshot.warnings, id: \.self) { warning in
        Text(warning).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
      }
    }
  }

  private func log(_ text: String, title: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.weight(.semibold))
      ScrollView([.horizontal, .vertical]) {
        Text(text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 160)
    }
  }
}
