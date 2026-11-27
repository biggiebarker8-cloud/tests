import Foundation
import LarkAISolutionsConsultant
import SwiftUI

struct ReferenceMemory: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let source: String
    let date: String
    let text: String
    let keywords: [String]
}

struct ReferenceArchive: Sendable {
    let entries: [ReferenceMemory]
    let warning: String?

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "ConsultantMemory", withExtension: "json") else {
            entries = []
            warning = nil
            return
        }
        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([ReferenceMemory].self, from: data)
            warning = nil
        } catch {
            entries = []
            warning = "The bundled memory file could not be read."
        }
    }

    func relevant(to question: String) -> [ReferenceMemory] {
        let terms = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return entries.compactMap { entry -> (ReferenceMemory, Int)? in
            let score = terms.intersection(entry.keywords).count
            return score > 0 ? (entry, score) : nil
        }
        .sorted { left, right in
            if left.1 == right.1 { return left.0.id < right.0.id }
            return left.1 > right.1
        }
        .prefix(3)
        .map { $0.0 }
    }
}

struct ReferenceAwareProvider: AIProvider {
    let base: any AIProvider
    let archive: ReferenceArchive

    func response(for messages: [ChatMessage]) async throws -> String {
        guard let index = messages.lastIndex(where: { $0.role == .user }) else {
            return try await base.response(for: messages)
        }
        let question = messages[index]
        let references = archive.relevant(to: question.content)
        guard !references.isEmpty else { return try await base.response(for: messages) }

        let excerpts = references.map { entry in
            "[\(entry.source), \(entry.date) — \(entry.title)]\n\(entry.text)"
        }.joined(separator: "\n\n")
        var augmented = messages
        augmented[index] = ChatMessage(
            id: question.id, role: .user,
            content: "Historical file excerpts for reference. Dates refer to the source.\n\n\(excerpts)\n\nCurrent question:\n\(question.content)",
            attachments: question.attachments, createdAt: question.createdAt
        )
        return try await base.response(for: augmented)
    }
}

struct ReferenceMemoriesView: View {
    let archive: ReferenceArchive
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
                else if visibleEntries.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, prompt: "Search saved memories")
            .navigationTitle("Saved memories")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
