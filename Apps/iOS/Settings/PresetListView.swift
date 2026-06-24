import SwiftUI
import WoodsWhisperKit

struct PresetListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: PromptPreset?
    @State private var isNew = false

    var body: some View {
        List {
            ForEach(model.documents.presets) { preset in
                Button {
                    editing = preset; isNew = false
                } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(preset.name)
                            if preset.isBuiltIn {
                                Text("built-in").font(.caption2).padding(.horizontal, 6)
                                    .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
                            }
                        }
                        Text(preset.template).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .swipeActions {
                    if !preset.isBuiltIn {
                        Button("Delete", role: .destructive) { model.documents.delete(preset: preset) }
                    }
                }
            }
        }
        .navigationTitle("Presets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = PromptPreset(name: "New Preset", template: "")
                    isNew = true
                } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Reset built-ins") { model.documents.resetBuiltInPresets() }
            }
        }
        .sheet(item: $editing) { preset in
            PresetEditorView(preset: preset, isNew: isNew)
        }
    }
}

struct PresetEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var preset: PromptPreset
    let isNew: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $preset.name)
                }
                Section {
                    TextField("System prompt", text: $preset.systemPrompt, axis: .vertical)
                        .lineLimit(2...6)
                } header: { Text("System Prompt") }

                Section {
                    TextField("Template", text: $preset.template, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("Template")
                } footer: {
                    Text("Use \(PromptPreset.transcriptToken) where the transcript should be inserted.")
                }

                Section("Generation") {
                    Stepper("Temperature: \(preset.temperature, specifier: "%.1f")",
                            value: $preset.temperature, in: 0...1.5, step: 0.1)
                    Stepper("Max tokens: \(preset.maxTokens)",
                            value: $preset.maxTokens, in: 128...4096, step: 128)
                }
            }
            .navigationTitle(isNew ? "New Preset" : "Edit Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.documents.save(preset: preset)   // upsert: works for new and edited
                        dismiss()
                    }
                    .disabled(preset.name.isEmpty || preset.template.isEmpty)
                }
            }
        }
    }
}
