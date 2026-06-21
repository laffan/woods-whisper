import SwiftUI
import WoodsWhisperKit

struct DocumentsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var renameTarget: Document?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.documents.documents) { doc in
                    NavigationLink(value: doc) {
                        VStack(alignment: .leading) {
                            Text(doc.title)
                            Text("\(doc.transformations.count) transformation(s) · \(doc.updatedAt, style: .date)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { model.documents.delete(doc) }
                        Button("Rename") { renameText = doc.title; renameTarget = doc }.tint(.blue)
                    }
                }
                .onDelete { model.documents.delete(at: $0) }
            }
            .navigationTitle("Documents")
            .navigationDestination(for: Document.self) { DocumentDetailView(documentID: $0.id) }
            .overlay {
                if model.documents.documents.isEmpty {
                    ContentUnavailableView("No documents yet",
                                           systemImage: "doc.text",
                                           description: Text("Transcribe a recording to create one."))
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
}
