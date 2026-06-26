import SwiftUI
import WoodsWhisperKit

struct TrashView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingEmptyConfirmation = false

    private var trash: [Document] { model.documents.trash }

    var body: some View {
        List {
            Section {
                Button(role: .destructive) {
                    showingEmptyConfirmation = true
                } label: {
                    Label("Empty Trash", systemImage: "trash.slash")
                }
            }

            Section {
                ForEach(trash) { doc in
                    TrashDocumentRow(document: doc)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                model.documents.permanentlyDelete(doc)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Restore") {
                                model.documents.restoreFromTrash(doc)
                            }
                            .tint(.green)
                        }
                }
            }
        }
        .navigationTitle("Trash")
        .overlay {
            if trash.isEmpty {
                ContentUnavailableView("Trash is empty",
                                       systemImage: "trash",
                                       description: Text("Deleted documents will appear here."))
            }
        }
        .confirmationDialog("Empty Trash?",
                            isPresented: $showingEmptyConfirmation,
                            titleVisibility: .visible) {
            Button("Delete All Permanently", role: .destructive) {
                model.documents.emptyTrash()
            }
        } message: {
            Text("This will permanently delete \(trash.count) document\(trash.count == 1 ? "" : "s") and all associated recordings. This cannot be undone.")
        }
    }
}

private struct TrashDocumentRow: View {
    let document: Document
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(document.title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    private var subtitle: String {
        let paras = document.paragraphs.count
        let body = "\(paras) paragraph\(paras == 1 ? "" : "s")"
        let count = document.recordings.count
        let clips = count == 0 ? "" : " · \(count) recording\(count == 1 ? "" : "s")"
        return body + clips
    }
}
