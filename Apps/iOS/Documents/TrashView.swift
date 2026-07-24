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
                        .foregroundStyle(WW.ember)
                }
                .wwRow()
            }

            Section {
                ForEach(trash) { doc in
                    TrashDocumentRow(document: doc)
                        .wwRow()
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                model.documents.permanentlyDelete(doc)
                            }
                            .tint(WW.ember)
                        }
                        .swipeActions(edge: .leading) {
                            Button("Restore") {
                                model.documents.restoreFromTrash(doc)
                            }
                            .tint(WW.moss)
                        }
                }
            }
        }
        .wwList()
        .navigationTitle("Trash")
        .overlay {
            if trash.isEmpty {
                WWEmptyState(title: "Trash is empty",
                             systemImage: "trash",
                             message: "Deleted documents will appear here.")
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
        VStack(alignment: .leading, spacing: 3) {
            Text(document.title)
                .font(WW.rowTitle)
                .foregroundStyle(WW.ink)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(WW.inkSecondary)
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
