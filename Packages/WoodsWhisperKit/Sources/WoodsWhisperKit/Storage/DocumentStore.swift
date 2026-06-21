import Foundation

/// Persists `Document`s and `PromptPreset`s. iOS/iPadOS only (the Watch has no documents UI).
@MainActor
public final class DocumentStore: ObservableObject {
    @Published public private(set) var documents: [Document] = []
    @Published public private(set) var presets: [PromptPreset] = []

    private let baseURL: URL
    private let documentsURL: URL
    private let presetsURL: URL

    public init(directoryName: String = "Documents") {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        baseURL = support.appendingPathComponent(directoryName, isDirectory: true)
        documentsURL = baseURL.appendingPathComponent("documents.json")
        presetsURL = baseURL.appendingPathComponent("presets.json")
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: Documents

    public func add(_ document: Document) {
        documents.insert(document, at: 0)
        persistDocuments()
    }

    public func update(_ document: Document) {
        guard let idx = documents.firstIndex(where: { $0.id == document.id }) else { return }
        var updated = document
        updated.updatedAt = Date()
        documents[idx] = updated
        persistDocuments()
    }

    public func rename(_ document: Document, to title: String) {
        guard let idx = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[idx].title = title
        documents[idx].updatedAt = Date()
        persistDocuments()
    }

    public func delete(_ document: Document) {
        documents.removeAll { $0.id == document.id }
        persistDocuments()
    }

    public func delete(at offsets: IndexSet) {
        documents.remove(atOffsets: offsets)
        persistDocuments()
    }

    public func appendTransformation(_ transformation: Document.Transformation,
                                     to documentID: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == documentID }) else { return }
        documents[idx].transformations.append(transformation)
        documents[idx].updatedAt = Date()
        persistDocuments()
    }

    // MARK: Presets

    public func add(preset: PromptPreset) {
        presets.append(preset)
        persistPresets()
    }

    public func update(preset: PromptPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx] = preset
        persistPresets()
    }

    public func delete(preset: PromptPreset) {
        presets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    public func resetBuiltInPresets() {
        let custom = presets.filter { !$0.isBuiltIn }
        presets = PromptPreset.builtIns + custom
        persistPresets()
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: documentsURL),
           let decoded = try? JSONDecoder.iso.decode([Document].self, from: data) {
            documents = decoded.sorted { $0.updatedAt > $1.updatedAt }
        }
        if let data = try? Data(contentsOf: presetsURL),
           let decoded = try? JSONDecoder.iso.decode([PromptPreset].self, from: data),
           !decoded.isEmpty {
            presets = decoded
        } else {
            presets = PromptPreset.builtIns      // seed on first launch
            persistPresets()
        }
    }

    private func persistDocuments() {
        guard let data = try? JSONEncoder.iso.encode(documents) else { return }
        try? data.write(to: documentsURL, options: .atomic)
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder.iso.encode(presets) else { return }
        try? data.write(to: presetsURL, options: .atomic)
    }
}
