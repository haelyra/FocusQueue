import AppKit
import SwiftUI

struct DocumentMetadata: Sendable {
    var kind: String
    var size: Int?
    var modified: Date?
    var exists: Bool
    static func read(_ url: URL) -> Self {
        guard url.isFileURL else { return .init(kind: url.host ?? "Web", exists: false) }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        return .init(kind: url.pathExtension.uppercased(), size: values?.fileSize,
                     modified: values?.contentModificationDate, exists: values?.isRegularFile == true)
    }
}

/// The only active Finder entry point for documents. Map folder launching stays
/// disconnected; reveal is an explicit action in an already opened document.
struct DocumentMetadataStrip: View {
    let url: URL
    let taskID: String
    var revision: Int = 0
    @State private var metadata: DocumentMetadata?
    var body: some View {
        HStack(spacing: 8) {
            Text(url.isFileURL ? url.path : url.absoluteString)
                .font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).help(url.isFileURL ? url.path : url.absoluteString)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let metadata {
                Text(metadata.kind).font(.system(size: 9))
                if let size = metadata.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.system(size: 9)) }
                if let date = metadata.modified { Text(date, style: .date).font(.system(size: 9)).help("Modified \(date.formatted())") }
                if metadata.exists {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.plain).font(.system(size: 10)).help("Reveal this document in Finder")
                }
            }
        }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .accessibilityLabel("Document location and metadata for \(taskID)")
            .task(id: url.absoluteString + String(revision)) {
                let info = await Task.detached(priority: .utility) { DocumentMetadata.read(url) }.value
                if !Task.isCancelled { metadata = info }
            }
    }
}
