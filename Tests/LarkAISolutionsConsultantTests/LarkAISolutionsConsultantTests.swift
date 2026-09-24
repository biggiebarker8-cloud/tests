import Foundation
import Testing
@testable import LarkAISolutionsConsultant

@MainActor
struct LarkAISolutionsConsultantTests {
    @Test
    func bootstrapLoadsStoredMessages() async throws {
        let seed = [ChatMessage(role: .assistant, content: "Welcome")]
        let store = InMemoryConversationStore(messages: seed)
        let controller = ChatSessionController(provider: MockAIProvider(), store: store)

        await controller.bootstrap()

        #expect(controller.messages == seed)
        #expect(controller.status == .idle)
    }

    @Test
    func sendAddsUserAndAssistantMessages() async throws {
        let store = InMemoryConversationStore()
        let controller = ChatSessionController(provider: MockAIProvider(), store: store)

        await controller.send("Help me improve adoption")

        #expect(controller.messages.count == 2)
        #expect(controller.messages[0].role == .user)
        #expect(controller.messages[1].role == .assistant)
        #expect(controller.status == .idle)
    }

    @Test
    func emptyMessageReturnsError() async throws {
        let store = InMemoryConversationStore()
        let controller = ChatSessionController(provider: MockAIProvider(), store: store)

        await controller.send("   ")

        #expect(controller.messages.isEmpty)
        if case .error(let message) = controller.status {
            #expect(message.contains("empty"))
        } else {
            Issue.record("Expected empty-message error")
        }
    }

    @Test
    func fileStoreRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let fileURL = root.appendingPathComponent("conversation.json")

        let store = FileConversationStore(fileURL: fileURL)
        let original = [
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi")
        ]

        try await store.save(original)
        let loaded = try await store.load()

        #expect(loaded == original)
    }
}
