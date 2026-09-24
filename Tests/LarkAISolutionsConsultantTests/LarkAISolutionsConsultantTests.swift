import Foundation
import Testing
@testable import LarkAISolutionsConsultant

actor CapturingProvider: AIProvider {
    private(set) var capturedMessages: [[ChatMessage]] = []

    func response(for messages: [ChatMessage]) async throws -> String {
        capturedMessages.append(messages)
        return "Captured response"
    }

    func lastMessages() -> [ChatMessage] {
        capturedMessages.last ?? []
    }
}

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

    @Test
    func learningEngineCapturesTopicsAndGoals() async throws {
        let engine = LearningEngine()
        let result = await engine.learn(
            from: "I need a rollout plan for enterprise onboarding and security governance",
            existing: [],
            profile: .init()
        )
        let learnedTopics = Set(result.profile.topTopics)
        let expectedTopics: Set<String> = ["rollout", "security", "governance"]
        let overlap = learnedTopics.intersection(expectedTopics)

        #expect(result.memories.count == 1)
        #expect(!overlap.isEmpty)
        #expect(!result.profile.userGoals.isEmpty)
    }

    @Test
    func learningEngineReinforcesSimilarMemories() async throws {
        let engine = LearningEngine()
        let first = await engine.learn(
            from: "Help me with iOS architecture migration",
            existing: [],
            profile: .init()
        )

        let second = await engine.learn(
            from: "Need support for iOS architecture rollout",
            existing: first.memories,
            profile: first.profile
        )

        #expect(second.memories.count == 1)
        #expect(second.memories[0].reinforcementCount > 1)
    }

    @Test
    func controllerInjectsMemoryContextIntoProviderPrompt() async throws {
        let provider = CapturingProvider()
        let controller = ChatSessionController(
            provider: provider,
            store: InMemoryConversationStore(),
            learningStore: InMemoryLearningStore()
        )

        await controller.send("I need a deployment strategy for B2B users")
        await controller.send("Can you refine that deployment strategy for B2B rollout?")

        let captured = await provider.lastMessages()
        #expect(captured.contains(where: { $0.role == .system && $0.content.contains("learned user memories") }))
        #expect(captured.contains(where: { $0.role == .system && $0.content.contains("User profile context") }))
        #expect(!controller.memories.isEmpty)
    }
}
