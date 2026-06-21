import SwiftUI
import WoodsWhisperKit

/// Shows a document's transcript and its model transformations, and lets the user run a
/// prompt preset against the transcript (or a prior transformation). Output streams live.
struct DocumentDetailView: View {
    @EnvironmentObject private var model: AppModel
    let documentID: UUID

    @State private var selectedPreset: PromptPreset?
    @State private var sourceText: String = ""
    @State private var streamingOutput: String = ""
    @State private var isRunning = false
    @State private var showingPresetPicker = false

    private var document: Document? {
        model.documents.documents.first { $0.id == documentID }
    }

    var body: some View {
        Group {
            if let doc = document {
                content(for: doc)
            } else {
                ContentUnavailableView("Document not found", systemImage: "doc")
            }
        }
        .navigationTitle(document?.title ?? "Document")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(for doc: Document) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Transcript") {
                    Text(doc.transcript.isEmpty ? "—" : doc.transcript)
                        .textSelection(.enabled)
                }

                ForEach(doc.transformations) { t in
                    section(t.presetName) {
                        Text(t.output).textSelection(.enabled)
                    }
                }

                if isRunning {
                    section("Running \(selectedPreset?.name ?? "")…") {
                        Text(streamingOutput.isEmpty ? "…" : streamingOutput)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) { transformBar(for: doc) }
        .confirmationDialog("Transform with…", isPresented: $showingPresetPicker, titleVisibility: .visible) {
            ForEach(model.documents.presets) { preset in
                Button(preset.name) { run(preset, on: doc) }
            }
        }
    }

    private func transformBar(for doc: Document) -> some View {
        HStack {
            Button {
                showingPresetPicker = true
            } label: {
                Label("Transform", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.modelReady || isRunning)
        }
        .padding()
        .background(.bar)
        .overlay(alignment: .top) {
            if !model.modelReady {
                Text("Finish language-model setup in Settings.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
    }

    private func run(_ preset: PromptPreset, on doc: Document) {
        selectedPreset = preset
        streamingOutput = ""
        isRunning = true
        // Transform the transcript; the latest transformation becomes part of the doc on completion.
        let source = doc.transcript
        Task {
            await model.runTransformation(preset, on: doc, source: source) { chunk in
                Task { @MainActor in streamingOutput += chunk }
            }
            isRunning = false
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            body()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
