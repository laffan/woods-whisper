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
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(preset.name)
                                .font(WW.rowTitle)
                                .foregroundStyle(WW.ink)
                            if preset.isBuiltIn {
                                Text("Built-in")
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(1.0)
                                    .textCase(.uppercase)
                                    .foregroundStyle(WW.inkSecondary)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .overlay(Capsule().stroke(WW.hairline, lineWidth: 1))
                            }
                        }
                        Text(preset.template).font(.caption).foregroundStyle(WW.inkSecondary).lineLimit(2)
                    }
                }
                .wwRow()
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                .swipeActions {
                    if !preset.isBuiltIn {
                        Button("Delete", role: .destructive) { model.documents.delete(preset: preset) }
                            .tint(WW.ember)
                    }
                }
            }
        }
        .wwList()
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
    /// Label for the confirm button (e.g. "Save & Run" when creating a transform inline).
    var saveTitle: String = "Save"
    /// Invoked with the saved preset after it's persisted — used to run it immediately.
    var onSaved: ((PromptPreset) -> Void)? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $preset.name)
                } header: {
                    WWSectionHeader("Name")
                }
                .listRowBackground(WW.surface)

                Section {
                    TextField("System prompt", text: $preset.systemPrompt, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    WWSectionHeader("System Prompt")
                }
                .listRowBackground(WW.surface)

                Section {
                    TextField("Template", text: $preset.template, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    WWSectionHeader("Template")
                } footer: {
                    WWFooter("Use \(PromptPreset.transcriptToken) where the transcript should be inserted.")
                }
                .listRowBackground(WW.surface)

                Section {
                    Stepper("Temperature: \(preset.temperature, specifier: "%.1f")",
                            value: $preset.temperature, in: 0...1.5, step: 0.1)
                    Stepper("Max tokens: \(preset.maxTokens)",
                            value: $preset.maxTokens, in: 128...4096, step: 128)
                } header: {
                    WWSectionHeader("Generation")
                }
                .listRowBackground(WW.surface)
            }
            .wwForm()
            .navigationTitle(isNew ? "New Preset" : "Edit Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) {
                        model.documents.save(preset: preset)   // upsert: works for new and edited
                        onSaved?(preset)
                        dismiss()
                    }
                    .disabled(preset.name.isEmpty || preset.template.isEmpty)
                }
            }
        }
    }
}
