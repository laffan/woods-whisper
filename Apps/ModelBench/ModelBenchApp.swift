import SwiftUI
import UIKit
import WoodsWhisperKit

#if canImport(MLXLLM)
import MLXLLM          // LLMModelFactory + GenerateParameters
import MLXLMCommon     // ModelConfiguration, ChatSession
import MLXHuggingFace  // #huggingFaceTokenizerLoader() macro
import HuggingFace     // referenced by the tokenizer-loader macro expansion
import Tokenizers      // AutoTokenizer, referenced by the tokenizer-loader macro expansion
#endif

/// **Model Bench**: a small app of its own for one question — which on-device language model tidies
/// a transcript best? Download a few, write (or paste) one piece of text and one instruction, and
/// run the transform step through each model in turn, so the answers sit one under another with
/// how long each took.
///
/// It's the main app's transform step and nothing else: the same downloader
/// (`URLSessionHubDownloader`, shared from `GemmaTransformService.swift`), the same MLX loading,
/// the same stop and `<think>` filters from the kit. Models are loaded one at a time and let go
/// before the next, since a phone can't hold two. Weights live in this app's own container, apart
/// from the main app's.
@main
struct ModelBenchApp: App {
    @StateObject private var bench = Bench()

    var body: some Scene {
        WindowGroup {
            BenchView()
                .environmentObject(bench)
        }
    }
}

// MARK: - Models and results

/// A model that can be compared: the Hugging Face repo its MLX weights come from.
struct BenchModel: Identifiable, Codable, Hashable {
    let repo: String
    var name: String
    var note: String
    var id: String { repo }
}

/// One model's answer to the text, and what it cost.
struct BenchResult: Identifiable, Codable {
    var id = UUID()
    let repo: String
    let name: String
    var answer = ""
    var reasoning = ""
    var loadSeconds: Double = 0
    var generateSeconds: Double = 0
    /// Streamed pieces, which for these models is close to one per token.
    var chunks = 0
    var error: String?
    var finished = false

    var tokensPerSecond: Double? {
        generateSeconds > 0 && chunks > 0 ? Double(chunks) / generateSeconds : nil
    }
}

// MARK: - The bench

@MainActor
final class Bench: ObservableObject {

    /// The models offered to start with: the one the app ships, and the others it has shipped or
    /// tried. Any other MLX repo can be added by name.
    static let builtIns: [BenchModel] = [
        BenchModel(repo: "lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit",
                   name: "LFM2.5 1.2B", note: "In Woods Whisper now · ~0.7 GB"),
        BenchModel(repo: "mlx-community/Llama-3.2-1B-Instruct-4bit",
                   name: "Llama 3.2 1B", note: "~0.7 GB"),
        BenchModel(repo: "mlx-community/gemma-3-1b-it-qat-4bit",
                   name: "Gemma 3 1B", note: "~0.8 GB"),
        BenchModel(repo: "mlx-community/Qwen3-1.7B-4bit",
                   name: "Qwen3 1.7B", note: "Reasons first · ~1 GB"),
        BenchModel(repo: "LiquidAI/LFM2.5-2.6B-MLX-4bit",
                   name: "LFM2.5 2.6B", note: "Reasons first · ~1.5 GB"),
        BenchModel(repo: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                   name: "Llama 3.2 3B", note: "~1.8 GB"),
        BenchModel(repo: "mlx-community/Qwen3-4B-4bit",
                   name: "Qwen3 4B", note: "Reasons first · ~2.3 GB"),
        BenchModel(repo: "mlx-community/gemma-3-4b-it-qat-4bit",
                   name: "Gemma 3 4B", note: "~3 GB · needs a phone with 8 GB"),
    ]

    /// The instructions the main app ships, to start from.
    static let presets = PromptPreset.builtIns.filter { !$0.isNumberParagraphs }

    /// Turn-end markers of every chat template in the lineup, so whichever model is running stops
    /// at the end of its answer rather than running on to the token limit.
    static let turnEnds = ["<|im_end|>", "<|endoftext|>", "<end_of_turn>", "<|eot_id|>", "<|end|>"]

    static let sampleText = "so um the trail up past the creek was washed out again we should "
        + "probably bring the the bigger tarp next time and. Question do we have enough fuel for "
        + "three nights also remind me to check the water filter it was. Slow yesterday and the "
        + "left boot is rubbing my heel again"

    @Published var text: String { didSet { save() } }
    @Published var instruction: String { didSet { save() } }
    @Published var systemPrompt: String { didSet { save() } }
    @Published var temperature: Double { didSet { save() } }
    @Published var maxTokens: Int { didSet { save() } }
    /// Append Qwen3's `/no_think` switch to the prompt, to see it answer without reasoning first.
    @Published var noThink: Bool { didSet { save() } }
    @Published var custom: [BenchModel] { didSet { save() } }
    @Published var chosen: Set<String> { didSet { save() } }
    @Published var results: [BenchResult] { didSet { if runningRepo == nil { save() } } }

    @Published private(set) var downloaded: [String: Int64] = [:]
    @Published private(set) var downloading: [String: Double] = [:]
    @Published private(set) var runningRepo: String?
    @Published var errorMessage: String?

    private var runTask: Task<Void, Never>?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var loading = true

    var allModels: [BenchModel] { Self.builtIns + custom }
    var isRunning: Bool { runTask != nil }
    var runnable: [BenchModel] {
        allModels.filter { chosen.contains($0.repo) && downloaded[$0.repo] != nil }
    }

    init() {
        let saved = Self.loadSaved()
        text = saved?.text ?? Self.sampleText
        instruction = saved?.instruction ?? Self.presets.first?.template ?? PromptPreset.transcriptToken
        systemPrompt = saved?.systemPrompt ?? PromptPreset.defaultSystemPrompt
        temperature = saved?.temperature ?? 0.3
        maxTokens = saved?.maxTokens ?? 1024
        noThink = saved?.noThink ?? false
        custom = saved?.custom ?? []
        chosen = Set(saved?.chosen ?? [])
        results = saved?.results ?? []
        loading = false
        refreshDownloaded()
    }

    func isCustom(_ model: BenchModel) -> Bool { custom.contains(model) }

    func toggle(_ model: BenchModel) {
        if chosen.contains(model.repo) { chosen.remove(model.repo) } else { chosen.insert(model.repo) }
    }

    /// Add any MLX repo by its Hugging Face id ("owner/name", or a pasted URL).
    func addModel(_ entry: String) {
        var repo = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = repo.range(of: "huggingface.co/") { repo = String(repo[range.upperBound...]) }
        repo = repo.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = repo.split(separator: "/")
        guard parts.count >= 2 else {
            errorMessage = "That doesn't look like a repo — it should read owner/name."
            return
        }
        repo = "\(parts[0])/\(parts[1])"
        guard !allModels.contains(where: { $0.repo == repo }) else { return }
        custom.append(BenchModel(repo: repo, name: String(parts[1]), note: "Added"))
    }

    func remove(_ model: BenchModel) {
        delete(model)
        custom.removeAll { $0 == model }
        chosen.remove(model.repo)
    }

    // MARK: Downloads

    func download(_ model: BenchModel) {
        guard downloadTasks[model.repo] == nil else { return }
        let repo = model.repo
        downloading[repo] = 0
        downloadTasks[repo] = Task {
            #if canImport(MLXLLM)
            do {
                _ = try await URLSessionHubDownloader.shared.download(
                    id: repo, revision: nil, matching: ["*.safetensors", "*.json"], useLatest: false
                ) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        if self?.downloading[repo] != nil { self?.downloading[repo] = fraction }
                    }
                }
                chosen.insert(repo)
            } catch {
                if !Task.isCancelled {
                    errorMessage = "Couldn't download \(model.name): \(describeDownloadError(error))"
                }
            }
            #else
            errorMessage = "MLX isn't available in this build."
            #endif
            downloadTasks[repo] = nil
            downloading[repo] = nil
            refreshDownloaded()
        }
    }

    func cancelDownload(_ model: BenchModel) {
        downloadTasks[model.repo]?.cancel()
    }

    func delete(_ model: BenchModel) {
        cancelDownload(model)
        #if canImport(MLXLLM)
        URLSessionHubDownloader.removeSnapshot(for: model.repo)
        #endif
        refreshDownloaded()
    }

    private func refreshDownloaded() {
        var sizes: [String: Int64] = [:]
        #if canImport(MLXLLM)
        for model in allModels where URLSessionHubDownloader.hasUsableSnapshot(for: model.repo) {
            sizes[model.repo] = Self.sizeOnDisk(model.repo)
        }
        #endif
        downloaded = sizes
    }

    /// The same folder the downloader writes to.
    private static func sizeOnDisk(_ repo: String) -> Int64 {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil,
                                                      create: false),
              let files = FileManager.default.enumerator(
                at: base.appendingPathComponent("huggingface/models/\(repo)", isDirectory: true),
                includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Running

    /// Run the text through every chosen, downloaded model, one after another. The results from
    /// the last run make way for these.
    func run() {
        let models = runnable
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard runTask == nil, !models.isEmpty, !source.isEmpty else { return }
        let preset = PromptPreset(name: "Bench", systemPrompt: systemPrompt, template: instruction,
                                  temperature: temperature, maxTokens: maxTokens)
        var prompt = preset.render(with: source)
        if noThink { prompt += "\n\n/no_think" }
        results = []
        UIApplication.shared.isIdleTimerDisabled = true
        runTask = Task {
            for model in models {
                if Task.isCancelled { break }
                await run(model, prompt: prompt, preset: preset)
            }
            runningRepo = nil
            runTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
            save()
        }
    }

    func stop() {
        runTask?.cancel()
    }

    private func run(_ model: BenchModel, prompt: String, preset: PromptPreset) async {
        results.append(BenchResult(repo: model.repo, name: model.name))
        let index = results.count - 1
        runningRepo = model.repo
        #if canImport(MLXLLM)
        do {
            let loadStart = Date()
            // Loaded fresh for each run and let go at the end of it, so only one model is ever in
            // memory. Offline, the downloader falls back to the weights already on disk.
            let container = try await LLMModelFactory.shared.loadContainer(
                from: URLSessionHubDownloader.shared,
                using: #huggingFaceTokenizerLoader(),
                configuration: ModelConfiguration(id: model.repo),
                progressHandler: { _ in }
            )
            results[index].loadSeconds = Date().timeIntervalSince(loadStart)

            let session = ChatSession(container,
                                      instructions: preset.systemPrompt,
                                      generateParameters: GenerateParameters(
                                        maxTokens: preset.maxTokens,
                                        temperature: Float(preset.temperature)))
            var filter = StopSequenceFilter(stops: Self.turnEnds)
            // Every model gets the splitter: one that doesn't reason passes straight through.
            var splitter = ThinkSplitter(enabled: true)
            func route(_ text: String) {
                guard !text.isEmpty else { return }
                let parts = splitter.consume(text)
                results[index].reasoning += parts.reasoning
                results[index].answer += parts.answer
            }
            let generateStart = Date()
            for try await chunk in session.streamResponse(to: prompt) {
                if Task.isCancelled { break }
                results[index].chunks += 1
                results[index].generateSeconds = Date().timeIntervalSince(generateStart)
                route(filter.consume(chunk))
                if filter.isStopped { break }
            }
            route(filter.flush())
            let rest = splitter.flush()
            results[index].reasoning += rest.reasoning
            results[index].answer += rest.answer
            results[index].generateSeconds = Date().timeIntervalSince(generateStart)
            results[index].answer = results[index].answer.trimmingCharacters(in: .whitespacesAndNewlines)
            results[index].reasoning = results[index].reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            if Task.isCancelled { results[index].error = "Stopped." }
        } catch {
            results[index].error = describeDownloadError(error)
        }
        #else
        results[index].error = "MLX isn't available in this build."
        #endif
        results[index].finished = true
    }

    // MARK: Saving

    private struct Saved: Codable {
        var text: String
        var instruction: String
        var systemPrompt: String
        var temperature: Double
        var maxTokens: Int
        var noThink: Bool
        var custom: [BenchModel]
        var chosen: [String]
        var results: [BenchResult]
    }

    private static let savedKey = "modelBench.saved"

    private static func loadSaved() -> Saved? {
        UserDefaults.standard.data(forKey: savedKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    private func save() {
        guard !loading else { return }
        let saved = Saved(text: text, instruction: instruction, systemPrompt: systemPrompt,
                          temperature: temperature, maxTokens: maxTokens, noThink: noThink,
                          custom: custom, chosen: Array(chosen), results: results)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        }
    }
}

// MARK: - The screen

struct BenchView: View {
    @EnvironmentObject private var bench: Bench
    @State private var newRepo = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Form {
                textSection
                instructionSection
                modelsSection
                runSection
                if !bench.results.isEmpty { resultsSection }
            }
            .navigationTitle("Model Bench")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
            .alert("Model Bench", isPresented: Binding(get: { bench.errorMessage != nil },
                                                       set: { if !$0 { bench.errorMessage = nil } })) {
                Button("OK", role: .cancel) { bench.errorMessage = nil }
            } message: {
                Text(bench.errorMessage ?? "")
            }
        }
    }

    private var textSection: some View {
        Section {
            TextEditor(text: $bench.text)
                .frame(minHeight: 140)
                .focused($typing)
            HStack {
                Button("Paste") {
                    if let pasted = UIPasteboard.general.string, !pasted.isEmpty { bench.text = pasted }
                }
                Spacer()
                Button("Sample") { bench.text = Bench.sampleText }
            }
            .buttonStyle(.borderless)
            .disabled(bench.isRunning)
        } header: {
            Text("Text")
        }
    }

    private var instructionSection: some View {
        Section {
            Menu("Start from one of the app's transforms") {
                ForEach(Bench.presets) { preset in
                    Button(preset.name) {
                        bench.instruction = preset.template
                        bench.temperature = preset.temperature
                    }
                }
            }
            TextEditor(text: $bench.instruction)
                .frame(minHeight: 120)
                .focused($typing)
            DisclosureGroup("System prompt") {
                TextEditor(text: $bench.systemPrompt)
                    .frame(minHeight: 80)
                    .focused($typing)
            }
            Stepper(value: $bench.temperature, in: 0...1.5, step: 0.1) {
                Text("Temperature \(bench.temperature, specifier: "%.1f")")
            }
            Stepper(value: $bench.maxTokens, in: 128...4096, step: 128) {
                Text("Up to \(bench.maxTokens) tokens")
            }
            Toggle("Ask Qwen3 not to reason (/no_think)", isOn: $bench.noThink)
        } header: {
            Text("Instruction")
        } footer: {
            Text("\(PromptPreset.transcriptToken) marks where the text goes; without it, the text follows the instruction.")
        }
        .disabled(bench.isRunning)
    }

    private var modelsSection: some View {
        Section {
            ForEach(bench.allModels) { model in
                modelRow(model)
            }
            HStack {
                TextField("Add a repo: owner/name", text: $newRepo)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($typing)
                    .onSubmit(addRepo)
                Button("Add", action: addRepo)
                    .buttonStyle(.borderless)
                    .disabled(newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Tick the downloaded models to compare. Weights download once, over Wi-Fi ideally, and run offline after. Swipe a row to delete its weights. Any MLX text model on Hugging Face can be added.")
        }
    }

    private func modelRow(_ model: BenchModel) -> some View {
        let isDownloaded = bench.downloaded[model.repo] != nil
        let isChosen = bench.chosen.contains(model.repo) && isDownloaded
        return HStack(spacing: 12) {
            Button {
                bench.toggle(model)
            } label: {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isDownloaded ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.borderless)
            .disabled(!isDownloaded || bench.isRunning)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.repo)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)

            if let fraction = bench.downloading[model.repo] {
                ProgressView(value: fraction)
                    .frame(width: 56)
                Button {
                    bench.cancelDownload(model)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            } else if let bytes = bench.downloaded[model.repo] {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Get") { bench.download(model) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .swipeActions {
            if bench.isCustom(model) {
                Button("Remove", role: .destructive) { bench.remove(model) }
            } else if isDownloaded {
                Button("Delete", role: .destructive) { bench.delete(model) }
            }
        }
        .disabled(bench.runningRepo == model.repo)
    }

    private var runSection: some View {
        Section {
            if bench.isRunning {
                Button("Stop", role: .destructive) { bench.stop() }
            } else {
                let count = bench.runnable.count
                Button(count == 1 ? "Run 1 model" : "Run \(count) models") {
                    typing = false
                    bench.run()
                }
                .disabled(count == 0 || bench.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } footer: {
            Text("Each model is loaded, run and let go in turn — the load time is shown apart from the time spent writing.")
        }
    }

    private var resultsSection: some View {
        Section {
            ForEach(bench.results) { result in
                resultRow(result)
            }
        } header: {
            HStack {
                Text("Results")
                Spacer()
                Button("Clear") { bench.results = [] }
                    .font(.caption)
                    .disabled(bench.isRunning)
            }
        }
    }

    private func resultRow(_ result: BenchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(result.name).font(.headline)
                Spacer()
                if !result.finished { ProgressView().controlSize(.small) }
            }
            Text(stats(result))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let error = result.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !result.reasoning.isEmpty {
                DisclosureGroup("Reasoning") {
                    Text(result.reasoning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
            Text(result.answer.isEmpty ? (result.finished ? "(no answer)" : "…") : result.answer)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Answer", systemImage: "doc.on.doc") { UIPasteboard.general.string = result.answer }
        }
    }

    private func stats(_ result: BenchResult) -> String {
        var parts: [String] = []
        if result.loadSeconds > 0 { parts.append(String(format: "load %.1fs", result.loadSeconds)) }
        if result.generateSeconds > 0 { parts.append(String(format: "write %.1fs", result.generateSeconds)) }
        if let rate = result.tokensPerSecond { parts.append(String(format: "~%.0f tok/s", rate)) }
        parts.append("\(result.answer.split(whereSeparator: \.isWhitespace).count) words")
        return parts.joined(separator: " · ")
    }

    private func addRepo() {
        bench.addModel(newRepo)
        newRepo = ""
    }
}
