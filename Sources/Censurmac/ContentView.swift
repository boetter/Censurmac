import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = PDFRedactionViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm)
                .frame(minWidth: 260, maxWidth: 340)
        } detail: {
            DetailView(vm: vm)
        }
        .onDrop(of: [UTType.pdf], isTargeted: nil) { providers in
            vm.handleDrop(providers)
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Åbn PDF") { vm.openFilePicker() }
                    .keyboardShortcut("o")

                if vm.redactedDocument != nil {
                    Button("Gem redigeret") { vm.saveRedactedPDF() }
                        .keyboardShortcut("s")
                }
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var vm: PDFRedactionViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.originalDocument == nil {
                dropPrompt
            } else {
                entityList
                Divider()
                actionButtons
            }
        }
    }

    var header: some View {
        HStack {
            Text("Censurmac")
                .font(.headline)
            Spacer()
            if vm.isProcessing {
                ProgressView().scaleEffect(0.65)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    var dropPrompt: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Træk en PDF hertil")
                .foregroundStyle(.secondary)
            Button("Vælg fil…") { vm.openFilePicker() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    var entityList: some View {
        Group {
            if vm.entities.isEmpty && !vm.isProcessing {
                VStack {
                    Spacer()
                    Text("Ingen GDPR-data fundet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(vm.entities) { entity in
                    EntityRow(entity: entity, selected: vm.selectedIds.contains(entity.id)) {
                        vm.toggleEntity(entity.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    var actionButtons: some View {
        VStack(spacing: 8) {
            Button("Analysér for GDPR-data") { vm.analyze() }
                .buttonStyle(.bordered)
                .disabled(vm.originalDocument == nil || vm.isProcessing)
                .frame(maxWidth: .infinity)

            Button("Redigér markerede (\(vm.selectedIds.count))") { vm.redact() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedIds.isEmpty || vm.isProcessing)
                .frame(maxWidth: .infinity)

            if vm.redactedDocument != nil {
                Button("Gem redigeret PDF…") { vm.saveRedactedPDF() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
    }
}

// MARK: - Entity Row

struct EntityRow: View {
    let entity: RedactionEntity
    let selected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.originalText)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Label(entity.type.label, systemImage: entity.type.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("→ \(entity.replacement)")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

// MARK: - Detail (PDF preview)

struct DetailView: View {
    @ObservedObject var vm: PDFRedactionViewModel

    var body: some View {
        if let doc = displayDocument {
            VStack(spacing: 0) {
                if vm.redactedDocument != nil {
                    Picker("", selection: $vm.showRedacted) {
                        Text("Original").tag(false)
                        Text("Redigeret").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(8)
                    .background(.bar)
                }
                PDFKitView(document: doc)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Åbn en PDF for at starte")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var displayDocument: PDFDocument? {
        vm.showRedacted ? vm.redactedDocument : vm.originalDocument
    }
}

// MARK: - PDFKit wrapper

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
        }
    }
}
