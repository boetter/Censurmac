import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor
class PDFRedactionViewModel: ObservableObject {

    @Published var originalDocument: PDFDocument?
    @Published var redactedDocument: PDFDocument?
    @Published var entities: [RedactionEntity] = []
    @Published var selectedIds: Set<UUID> = []
    @Published var isProcessing = false
    @Published var showRedacted = false

    private let redactor = GDPRRedactor()
    private let engine = PDFRedactionEngine()

    // MARK: - File loading

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Vælg en PDF-fil at censurere"
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { [weak self] url, _ in
            guard let url else { return }
            // Copy to temp dir because the sandbox URL may disappear
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: dest)
            Task { @MainActor [weak self] in
                self?.load(url: dest)
            }
        }
    }

    private func load(url: URL) {
        guard let doc = PDFDocument(url: url) else { return }
        originalDocument = doc
        redactedDocument = nil
        entities = []
        selectedIds = []
        showRedacted = false
        Task { await runAnalysis(on: doc) }
    }

    // MARK: - Analysis

    func analyze() {
        guard let doc = originalDocument else { return }
        Task { await runAnalysis(on: doc) }
    }

    private func runAnalysis(on document: PDFDocument) async {
        isProcessing = true
        let text = document.string ?? ""
        let found = await Task.detached(priority: .userInitiated) { [redactor] in
            redactor.findEntities(in: text)
        }.value
        entities = found
        selectedIds = Set(found.map(\.id))
        isProcessing = false
    }

    // MARK: - Redaction

    func toggleEntity(_ id: UUID) {
        if selectedIds.contains(id) { selectedIds.remove(id) }
        else { selectedIds.insert(id) }
    }

    func redact() {
        guard let original = originalDocument else { return }
        let toRedact = entities.filter { selectedIds.contains($0.id) }
        guard !toRedact.isEmpty else { return }

        Task {
            isProcessing = true
            let result = await Task.detached(priority: .userInitiated) { [engine] in
                engine.createRedactedPDF(from: original, entities: toRedact)
            }.value
            redactedDocument = result
            showRedacted = result != nil
            isProcessing = false
        }
    }

    // MARK: - Export

    func saveRedactedPDF() {
        guard let document = redactedDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "censureret.pdf"
        panel.message = "Gem den redigerede PDF"
        if panel.runModal() == .OK, let url = panel.url {
            document.write(to: url)
        }
    }
}
