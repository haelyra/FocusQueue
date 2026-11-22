import FocusQueueCore
import SwiftUI

/// A document's purpose, related work, and build-owned guidance, above its actions.
struct PlanningDocumentInformationMenu: View {
  let model: QueueViewModel
  let description: String
  let taskIDs: [String]
  let guidelines: [String]
  let url: URL?

  var body: some View {
    Menu {
      Text(description)
      Divider()
      if let url {
        Button("Open document", systemImage: "doc.text") {
          model.openDocumentViewer(url, scope: model.selectedProject.map { .project($0.id) })
        }
      } else {
        Text("Document not created yet")
      }
      Section("Linked tasks") {
        if taskIDs.isEmpty { Text("No linked tasks") }
        ForEach(taskIDs, id: \.self) { id in
          let title = model.dashboard.tickets.first { $0.id == id }?.title
          Button(title.map { "\(id): \($0)" } ?? id) { model.revealMapTask(id) }
        }
      }
      Section("Guideline files") {
        if guidelines.isEmpty { Text("No bundled guideline for this document") }
        ForEach(guidelines, id: \.self) { name in
          Button(name, systemImage: "book.closed") { model.openDevelopmentGuideline(name) }
        }
      }
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
        .frame(width: 22, height: 22).contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help(description)
    .accessibilityLabel("Document information: \(url?.lastPathComponent ?? "planned document")")
  }
}
