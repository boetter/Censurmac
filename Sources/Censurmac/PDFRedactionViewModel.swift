import SwiftUI
import UniformTypeIdentifiers

@MainActor
class RedactionViewModel: ObservableObject {

    @Published var originalText: String?
    @Published var redactedText: String?
    @Published var entities: [EntityGroup] = []
    @Published var selectedOriginals: Set<String> = []
    @Published var isProcessing = false
    @Published var showRedacted = false
    @Published var showError = false
    @Published var errorMessage = ""

    /// Viser hvilken analyse-motor der bruges ("LLM: llama3.2:3b" eller "Heuristik")
    @Published var engineLabel: String = "Tjekker Ollama…"

    var allSelected: Bool { selectedOriginals.count == entities.count }

    private let extractor = TextExtractor()
    private let redactor = GDPRRedactor()
    private var substitutions: [Substitution] = []

    init() {
        Task { await refreshOllamaStatus() }
    }

    // MARK: - Ollama-status

    func refreshOllamaStatus() async {
        await OllamaExtractor.shared.checkAvailability()
        let ollama = OllamaExtractor.shared
        if await ollama.isAvailable, let model = await ollama.modelName {
            engineLabel = "LLM: \(model)"
        } else {
            engineLabel = "Heuristik (Ollama ikke fundet)"
        }
    }

    // MARK: - File loading

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = supportedUTTypes
        panel.message = "Vælg en fil at censurere"
        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url: url)
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        let types = supportedUTTypes.map(\.identifier)
        for typeID in types {
            if provider.hasItemConformingToTypeIdentifier(typeID) {
                provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, _ in
                    guard let url else { return }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.copyItem(at: url, to: dest)
                    Task { @MainActor [weak self] in self?.loadFile(url: dest) }
                }
                return
            }
        }
    }

    private func loadFile(url: URL) {
        Task {
            isProcessing = true
            do {
                let text = try extractor.extract(from: url)
                originalText = text
                redactedText = nil
                showRedacted = false
                await runAnalysis(on: text)
            } catch {
                showError(error.localizedDescription)
            }
            isProcessing = false
        }
    }

    // MARK: - Analysis

    func analyze() {
        guard let text = originalText else { return }
        Task { await runAnalysis(on: text) }
    }

    private func runAnalysis(on text: String) async {
        isProcessing = true
        // findSubstitutions er nu async og kalder Ollama direkte
        let subs = await redactor.findSubstitutions(in: text)
        let groups = redactor.groupEntities(from: subs)
        substitutions = subs
        entities = groups
        selectedOriginals = Set(groups.map(\.originalText))
        isProcessing = false
    }

    // MARK: - Redaction

    func toggleEntity(_ original: String) {
        if selectedOriginals.contains(original) { selectedOriginals.remove(original) }
        else { selectedOriginals.insert(original) }
    }

    func toggleAll() {
        if allSelected { selectedOriginals = [] }
        else { selectedOriginals = Set(entities.map(\.originalText)) }
    }

    func redact() {
        guard let text = originalText, !substitutions.isEmpty else { return }
        let selected = selectedOriginals
        Task {
            isProcessing = true
            let result = await Task.detached(priority: .userInitiated) { [redactor, substitutions] in
                redactor.apply(substitutions, selectedOriginals: selected, to: text)
            }.value
            redactedText = result
            showRedacted = true
            isProcessing = false
        }
    }

    // MARK: - Export

    func saveRedactedText() {
        guard let text = redactedText else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "censureret.txt"
        panel.message = "Gem den censurerede tekst"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
