import SwiftUI
import UniformTypeIdentifiers

// MARK: - Supported file types

let supportedUTTypes: [UTType] = [
    .plainText, .rtf,
    UTType(filenameExtension: "docx") ?? .data,
    UTType(filenameExtension: "doc")  ?? .data,
    UTType(filenameExtension: "xlsx") ?? .data,
    UTType(filenameExtension: "xls")  ?? .data,
    .commaSeparatedText,
    UTType(filenameExtension: "tsv")  ?? .data,
    UTType(filenameExtension: "md")   ?? .plainText,
]

// MARK: - Root view

struct ContentView: View {
    @StateObject private var vm = RedactionViewModel()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(vm: vm)
                .frame(minWidth: 240, maxWidth: 320)
        } detail: {
            TextPreviewView(vm: vm)
        }
        .onDrop(of: supportedUTTypes, isTargeted: nil) { providers in
            vm.handleDrop(providers)
            return true
        }
        .alert("Fejl", isPresented: $vm.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Åbn fil…") { vm.openFilePicker() }
                    .keyboardShortcut("o")
                if vm.redactedText != nil {
                    Button("Gem censureret tekst…") { vm.saveRedactedText() }
                        .keyboardShortcut("s")
                }
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var vm: RedactionViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            if vm.originalText == nil {
                dropPrompt
            } else {
                entitySection
                Divider()
                actionButtons
            }
        }
    }

    var headerRow: some View {
        HStack {
            Label("Censurmac", systemImage: "eye.slash.fill")
                .font(.headline)
            Spacer()
            if vm.isProcessing { ProgressView().scaleEffect(0.65) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    var dropPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Træk fil hertil")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(".txt · .docx · .xlsx · .rtf · .csv · .md")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Vælg fil…") { vm.openFilePicker() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    var entitySection: some View {
        Group {
            if vm.entities.isEmpty && !vm.isProcessing {
                VStack {
                    Spacer()
                    Label("Ingen GDPR-data fundet", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Fundet GDPR-data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(vm.allSelected ? "Fravælg alle" : "Vælg alle") {
                            vm.toggleAll()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.accentColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                    List(vm.entities) { entity in
                        EntityRow(entity: entity,
                                  selected: vm.selectedOriginals.contains(entity.originalText)) {
                            vm.toggleEntity(entity.originalText)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
        }
    }

    var actionButtons: some View {
        VStack(spacing: 8) {
            Button("Analysér") { vm.analyze() }
                .buttonStyle(.bordered)
                .disabled(vm.isProcessing)
                .frame(maxWidth: .infinity)

            Button("Censurér (\(vm.selectedOriginals.count) valgt)") { vm.redact() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedOriginals.isEmpty || vm.isProcessing)
                .frame(maxWidth: .infinity)

            if vm.redactedText != nil {
                Button("Gem som .txt…") { vm.saveRedactedText() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
    }
}

// MARK: - Entity row

struct EntityRow: View {
    let entity: EntityGroup
    let selected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entity.originalText)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("×\(entity.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Label(entity.type.label, systemImage: entity.type.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("→ \(entity.replacement)")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

// MARK: - Text preview

struct TextPreviewView: View {
    @ObservedObject var vm: RedactionViewModel

    var displayText: String {
        (vm.showRedacted ? vm.redactedText : vm.originalText) ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.redactedText != nil {
                Picker("", selection: $vm.showRedacted) {
                    Text("Original").tag(false)
                    Text("Censureret").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(8)
                .background(.bar)
            }

            if vm.originalText == nil {
                emptyState
            } else {
                ScrollView {
                    Text(displayText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Åbn en fil for at starte")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
