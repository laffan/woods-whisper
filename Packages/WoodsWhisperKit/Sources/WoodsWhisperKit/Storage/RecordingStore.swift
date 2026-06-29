import Foundation

/// Persists recordings (audio files + JSON metadata) in the app's Application Support dir.
///
/// Deliberately simple and dependency-free so it compiles identically on watchOS and iOS.
/// Metadata is a single JSON index; audio payloads are individual files alongside it.
@MainActor
public final class RecordingStore: ObservableObject {
    @Published public private(set) var recordings: [Recording] = []

    private let baseURL: URL
    private let audioDirURL: URL
    private let indexURL: URL

    public init(directoryName: String = "Recordings") {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        baseURL = support.appendingPathComponent(directoryName, isDirectory: true)
        audioDirURL = baseURL.appendingPathComponent("audio", isDirectory: true)
        indexURL = baseURL.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: audioDirURL,
                                                 withIntermediateDirectories: true)
        load()
    }

    // MARK: Paths

    public func audioURL(for recording: Recording) -> URL {
        audioDirURL.appendingPathComponent(recording.audioFileName)
    }

    /// A fresh URL to record into. Caller records audio here, then calls `add`.
    public func newAudioURL(id: UUID = UUID()) -> (id: UUID, url: URL, fileName: String) {
        let fileName = "\(id.uuidString).m4a"
        return (id, audioDirURL.appendingPathComponent(fileName), fileName)
    }

    // MARK: CRUD

    public func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        persist()
    }

    /// Import audio bytes received from another device, returning the stored recording.
    @discardableResult
    public func ingest(audio data: Data, recording proto: Recording) throws -> Recording {
        let url = audioDirURL.appendingPathComponent(proto.audioFileName)
        try data.write(to: url, options: .atomic)
        add(proto)
        return proto
    }

    public func rename(_ recording: Recording, to newName: String) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx].name = newName
        persist()
    }

    public func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: audioURL(for: recording))
        recordings.removeAll { $0.id == recording.id }
        persist()
    }

    public func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            try? FileManager.default.removeItem(at: audioURL(for: recordings[index]))
            recordings.remove(at: index)
        }
        persist()
    }

    /// Remove every recording and its audio file (the "Delete All" action).
    public func deleteAll() {
        for recording in recordings {
            try? FileManager.default.removeItem(at: audioURL(for: recording))
        }
        recordings.removeAll()
        persist()
    }

    public func recording(with id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder.iso.decode([Recording].self, from: data) else { return }
        recordings = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder.iso.encode(recordings) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
