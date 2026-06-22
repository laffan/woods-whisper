import SwiftUI
import WoodsWhisperKit

struct DocumentsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var renameTarget: Document?
    @State private var renameText = ""

    private var documents: [Document] { model.documents.documents }

    var body: some View {
        NavigationStack {
            List {
                ForEach(documents) { doc in
                    NavigationLink(value: doc) {
                        DocumentRow(document: doc)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { model.documents.delete(doc) }
                        Button("Rename") { startRename(doc) }.tint(.blue)
                    }
                }
            }
            .navigationTitle("Documents")
            .navigationDestination(for: Document.self) { DocumentDetailView(documentID: $0.id) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let doc = model.documents.createDocument()
                        startRename(doc)
                    } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .overlay {
                if documents.isEmpty {
                    ContentUnavailableView("No documents yet",
                                           systemImage: "doc.text",
                                           description: Text("Tap ✎ to start a document, then record into it. Recordings from your Watch land in “Inbox.”"))
                }
            }
            .alert("Rename document", isPresented: Binding(get: { renameTarget != nil },
                                                           set: { if !$0 { renameTarget = nil } })) {
                TextField("Title", text: $renameText)
                Button("Save") {
                    if let t = renameTarget { model.documents.rename(t, to: renameText) }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
        }
    }

    private func startRename(_ document: Document) {
        renameText = document.title
        renameTarget = document
    }
}

private struct DocumentRow: View {
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
        let count = document.recordings.count
        let clips = "\(count) recording\(count == 1 ? "" : "s")"
        let transforms = document.transformations.isEmpty
            ? "" : " · \(document.transformations.count) transform\(document.transformations.count == 1 ? "" : "s")"
        return clips + transforms
    }
}
