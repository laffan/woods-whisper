import Foundation

/// Persists `Document`s (each containing `Recording`s), their audio files, and `PromptPreset`s.
/// iOS/iPadOS only — the Watch keeps its own flat `RecordingStore`.
@MainActor
public final class DocumentStore: ObservableObject {
    @Published public private(set) var documents: [Document] = []
    @Published public private(set) var presets: [PromptPreset] = []

    private let baseURL: URL
    private let audioDirURL: URL
    private let documentsURL: URL
    private let presetsURL: URL

    /// Title used for the auto-created container that receives Watch recordings.
    public static let inboxTitle = "Inbox"

    public init(directoryName: String = "Library") {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        baseURL = support.appendingPathComponent(directoryName, isDirectory: true)
        audioDirURL = baseURL.appendingPathComponent("audio", isDirectory: true)
        documentsURL = baseURL.appendingPathComponent("documents.json")
        presetsURL = baseURL.appendingPathComponent("presets.json")
        try? FileManager.default.createDirectory(at: audioDirURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: Audio paths

    public func audioURL(for recording: Recording) -> URL {
        audioDirURL.appendingPathComponent(recording.audioFileName)
    }

    /// A fresh URL to record into. Caller records audio here, then calls `addRecording`.
    public func newAudioURL(id: UUID = UUID()) -> (id: UUID, url: URL, fileName: String) {
        let fileName = "\(id.uuidString).m4a"
        return (id, audioDirURL.appendingPathComponent(fileName), fileName)
    }

    // MARK: Documents

    @discardableResult
    public func createDocument(title: String = "New Document") -> Document {
        let doc = Document(title: title)
        documents.insert(doc, at: 0)
        persistDocuments()
        return doc
    }

    public func rename(_ document: Document, to title: String) {
        guard let idx = index(of: document.id) else { return }
        documents[idx].title = title
        touch(idx)
    }

    public func delete(_ document: Document) {
        if let idx = index(of: document.id) {
            for recording in documents[idx].recordings { removeAudio(recording) }
        }
        documents.removeAll { $0.id == document.id }
        persistDocuments()
    }

    public func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            for recording in documents[index].recordings { removeAudio(recording) }
            documents.remove(at: index)
        }
        persistDocuments()
    }

    public func document(with id: UUID) -> Document? {
        documents.first { $0.id == id }
    }

    /// The container that receives incoming Watch recordings, created on demand.
    @discardableResult
    public func inboxDocument() -> Document {
        if let existing = documents.first(where: { $0.title == Self.inboxTitle }) {
            return existing
        }
        let inbox = Document(title: Self.inboxTitle)
        documents.append(inbox)            // keep at the bottom; user docs surface on top
        persistDocuments()
        return inbox
    }

    // MARK: Recordings within a document

    /// Add a recording to a document. If `audioData` is provided (e.g. from the Watch), it is
    /// written to the audio directory; otherwise the audio is assumed already on disk at
    /// `audioURL(for:)` (e.g. recorded in place via `newAudioURL`).
    public func addRecording(_ recording: Recording,
                             audioData: Data? = nil,
                             toDocument documentID: UUID) {
        if let audioData {
            try? audioData.write(to: audioURL(for: recording), options: .atomic)
        }
        guard let idx = index(of: documentID) else { return }
        documents[idx].recordings.append(recording)
        touch(idx)
    }

    public func updateRecording(_ recording: Recording, inDocument documentID: UUID) {
        guard let docIdx = index(of: documentID),
              let recIdx = documents[docIdx].recordings.firstIndex(where: { $0.id == recording.id })
        else { return }
        documents[docIdx].recordings[recIdx] = recording
        touch(docIdx)
    }

    public func renameRecording(_ recordingID: UUID, inDocument documentID: UUID, to name: String) {
        guard let docIdx = index(of: documentID),
              let recIdx = documents[docIdx].recordings.firstIndex(where: { $0.id == recordingID })
        else { return }
        documents[docIdx].recordings[recIdx].name = name
        touch(docIdx)
    }

    public func deleteRecording(_ recordingID: UUID, fromDocument documentID: UUID) {
        guard let docIdx = index(of: documentID),
              let recIdx = documents[docIdx].recordings.firstIndex(where: { $0.id == recordingID })
        else { return }
        removeAudio(documents[docIdx].recordings[recIdx])
        documents[docIdx].recordings.remove(at: recIdx)
        touch(docIdx)
    }

    /// Move a recording (and its audio, which stays at the same path) to another document.
    public func moveRecording(_ recordingID: UUID, from sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              let srcIdx = index(of: sourceID),
              let recIdx = documents[srcIdx].recordings.firstIndex(where: { $0.id == recordingID }),
              let dstIdx = index(of: targetID)
        else { return }
        let recording = documents[srcIdx].recordings.remove(at: recIdx)
        documents[dstIdx].recordings.append(recording)
        documents[srcIdx].updatedAt = Date()
        touch(dstIdx)
    }

    // MARK: Batch operations (selection mode)

    public func deleteRecordings(_ ids: Set<UUID>, fromDocument documentID: UUID) {
        guard let docIdx = index(of: documentID) else { return }
        for recording in documents[docIdx].recordings where ids.contains(recording.id) {
            removeAudio(recording)
        }
        documents[docIdx].recordings.removeAll { ids.contains($0.id) }
        touch(docIdx)
    }

    public func moveRecordings(_ ids: Set<UUID>, from sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              let srcIdx = index(of: sourceID),
              let dstIdx = index(of: targetID) else { return }
        let moving = documents[srcIdx].recordings.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        documents[srcIdx].recordings.removeAll { ids.contains($0.id) }
        documents[dstIdx].recordings.append(contentsOf: moving)
        documents[srcIdx].updatedAt = Date()
        touch(dstIdx)
    }

    // MARK: Document body (paragraphs)

    /// Append a paragraph to the bottom of the body (e.g. from "Re-transcribe").
    public func appendParagraph(_ text: String, to documentID: UUID) {
        guard let idx = index(of: documentID) else { return }
        documents[idx].paragraphs.append(Document.Paragraph(text: text))
        touch(idx)
    }

    /// Insert a paragraph at `position` in the body (used by the inter-paragraph "+" button).
    public func insertParagraph(_ text: String, at position: Int, in documentID: UUID) {
        guard let idx = index(of: documentID) else { return }
        let clamped = max(0, min(position, documents[idx].paragraphs.count))
        documents[idx].paragraphs.insert(Document.Paragraph(text: text), at: clamped)
        touch(idx)
    }

    public func updateParagraph(_ paragraphID: UUID, in documentID: UUID, to text: String) {
        guard let docIdx = index(of: documentID),
              let pIdx = documents[docIdx].paragraphs.firstIndex(where: { $0.id == paragraphID })
        else { return }
        documents[docIdx].paragraphs[pIdx].text = text
        touch(docIdx)
    }

    public func deleteParagraph(_ paragraphID: UUID, in documentID: UUID) {
        guard let docIdx = index(of: documentID) else { return }
        documents[docIdx].paragraphs.removeAll { $0.id == paragraphID }
        touch(docIdx)
    }

    public func moveParagraphs(in documentID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let docIdx = index(of: documentID) else { return }
        documents[docIdx].paragraphs.move(fromOffsets: offsets, toOffset: destination)
        touch(docIdx)
    }

    /// Replace the entire body with new paragraphs (used by a whole-document transform).
    public func setParagraphs(_ paragraphs: [Document.Paragraph], in documentID: UUID) {
        guard let idx = index(of: documentID) else { return }
        documents[idx].paragraphs = paragraphs
        touch(idx)
    }

    // MARK: Presets

    public func add(preset: PromptPreset) { presets.append(preset); persistPresets() }

    public func update(preset: PromptPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx] = preset
        persistPresets()
    }

    /// Insert a new preset or replace the existing one with the same id. The editor uses this so
    /// saving never depends on a separate "is new" flag being correct — a brand-new preset that
    /// (for any reason) reached `update`'s "not found" path would previously be silently dropped.
    public func save(preset: PromptPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
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

    // MARK: Helpers

    private func index(of id: UUID) -> Int? { documents.firstIndex { $0.id == id } }

    private func touch(_ idx: Int) {
        documents[idx].updatedAt = Date()
        persistDocuments()
    }

    private func removeAudio(_ recording: Recording) {
        try? FileManager.default.removeItem(at: audioURL(for: recording))
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
            presets = PromptPreset.builtIns
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
