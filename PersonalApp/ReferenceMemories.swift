import SwiftUI
import UniformTypeIdentifiers
import LarkAISolutionsConsultant

struct ReferenceMemoriesView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var importing = false
    @State private var importError: String?
    private var archive: ReferenceArchive { viewModel.referenceArchive }
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var visibleEntries: [ReferenceMemory] {
        guard !query.isEmpty else { return archive.entries }
        return archive.entries.filter {
            [$0.title, $0.text, $0.source].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List(visibleEntries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title).font(.headline)
                    Text(entry.text).textSelection(.enabled)
                    Text("\(entry.source) · \(entry.date)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if let warning = archive.warning { Text(warning).padding() }
                else if archive.entries.isEmpty {
                    ContentUnavailableView("No saved notes", systemImage: "doc", description: Text("Import a memory archive from your files."))
                } else if visibleEntries.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, prompt: "Search saved memories")
            .navigationTitle("Saved memories")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                Task {
                    do { try await viewModel.importArchive(from: result.get()) }
                    catch let error as CocoaError where error.code == .userCancelled { }
                    catch { importError = error.localizedDescription }
                }
            }
            .alert("Couldn’t import memories", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } }
            )) {
                Button("OK") { importError = nil }
            } message: { Text(importError ?? "") }
            .toolbar {
                ToolbarItem {
                    Button("Import JSON") { importing = true }
                        .help("Add notes or update existing notes with the same ID.")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
