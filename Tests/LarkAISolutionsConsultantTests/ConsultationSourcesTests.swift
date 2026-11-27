import Foundation
import Testing
@testable import LarkAISolutionsConsultant

struct ConsultationSourcesTests {
    let note = ReferenceMemory(id: "test", title: "Example review", source: "Test fixture",
                               date: "2026-01-01", text: "Historical example only.", keywords: ["Lark"])

    @Test func citesOnlyReferencesSuppliedForThisQuestion() async throws {
        let base = CapturingProvider()
        let provider = ReferenceAwareProvider(base: base, archive: ReferenceArchive(entries: [note]))
        let question = ChatMessage(role: .user, content: "What can a Lark admin check?")
        let result = try await provider.response(for: [question])
        let prompt = await base.lastMessages()
        #expect(prompt.last == question)
        #expect(prompt.first?.content.contains(note.text) == true)
        #expect(prompt.first?.content.contains(PlatformGuide.all[0].summary) == true)
        #expect(result.contains(PlatformGuide.all[0].url.absoluteString))
        #expect(result.contains("Test fixture · 2026-01-01"))
        #expect(!result.contains("TikTok"))
        let next = ChatMessage(role: .user, content: "Write a song about a meadow")
        let nextReply = try await provider.response(for: [question, next])
        #expect(nextReply == "Captured response")
    }

    @Test func recognisesPlatformNamesAtWordBoundaries() {
        #expect(PlatformGuide.matching("larkspur and skylarks").isEmpty)
        #expect(PlatformGuide.matching("Lark and Tik Tok?").count == 3)
        #expect(PlatformGuide.matching("TikTok!").count == 2)
    }

    @Test func importPersistsCorrectionsAndPreservesArchiveAfterInvalidFile() throws {
        let files = FileManager.default
        let dir = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: dir) }
        let source = dir.appendingPathComponent("selected.json")
        let target = dir.appendingPathComponent("private/archive.json")
        try JSONEncoder().encode([note]).write(to: source)
        try ReferenceArchive.importFile(source, into: target)
        let correction = ReferenceMemory(id: note.id, title: note.title, source: note.source,
                                         date: "2026-02-01", text: "Revised example.", keywords: note.keywords)
        try JSONEncoder().encode([correction]).write(to: source)
        try ReferenceArchive.importFile(source, into: target)
        try JSONEncoder().encode([note, note]).write(to: source)
        #expect(throws: (any Error).self) { try ReferenceArchive.importFile(source, into: target) }
        let reopened = ReferenceArchive(importedFile: target)
        #expect(reopened.warning == nil)
        #expect(reopened.entries.count == 1)
        #expect(reopened.relevant(to: "Lark").first?.text == correction.text)
    }
}
