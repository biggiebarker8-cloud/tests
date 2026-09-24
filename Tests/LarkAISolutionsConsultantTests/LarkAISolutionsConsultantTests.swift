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
    func imageOnlyMessageIsAccepted() async throws {
        let store = InMemoryConversationStore()
        let controller = ChatSessionController(provider: MockAIProvider(), store: store)
        let attachment = ChatImageAttachment(
            mimeType: "image/png",
            base64Data: Data([0x01, 0x02, 0x03]).base64EncodedString()
        )

        await controller.send("", imageAttachments: [attachment])

        #expect(controller.messages.count == 2)
        #expect(controller.messages[0].attachments.count == 1)
        #expect(controller.status == .idle)
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

    @Test
    func controllerInjectsCompanyKnowledgeBaseContext() async throws {
        let provider = CapturingProvider()
        let controller = ChatSessionController(
            provider: provider,
            store: InMemoryConversationStore(),
            learningStore: InMemoryLearningStore()
        )

        await controller.send("Create a TikTok Shop and Shopify rollout plan for our commerce team")

        let captured = await provider.lastMessages()
        let knowledgeMessage = captured.first(where: { $0.role == .system && $0.content.contains("company knowledge base context") })

        #expect(knowledgeMessage?.content.contains("Company: TikTok") == true)
        #expect(knowledgeMessage?.content.contains("Company: Shopify") == true)
        #expect(knowledgeMessage?.content.contains("Recommended plug-ins:") == true)
        #expect(knowledgeMessage?.content.contains("Cross-platform plug-in ideas:") == true)
    }

    @Test
    func controllerSkipsKnowledgeBaseContextForUnmatchedPrompt() async throws {
        let provider = CapturingProvider()
        let controller = ChatSessionController(
            provider: provider,
            store: InMemoryConversationStore(),
            learningStore: InMemoryLearningStore()
        )

        await controller.send("Help me write a launch retrospective")

        let captured = await provider.lastMessages()
        #expect(!captured.contains(where: { $0.role == .system && $0.content.contains("company knowledge base context") }))
    }

    @Test
    func controllerInjectsExpandedPluginCoverage() async throws {
        let provider = CapturingProvider()
        let controller = ChatSessionController(
            provider: provider,
            store: InMemoryConversationStore(),
            learningStore: InMemoryLearningStore()
        )

        await controller.send("Add plugins for Facebook, Instagram, Claude AI, Munus, and Lark")

        let captured = await provider.lastMessages()
        let knowledgeMessage = captured.first(where: { $0.role == .system && $0.content.contains("company knowledge base context") })

        #expect(knowledgeMessage?.content.contains("Company: Facebook") == true)
        #expect(knowledgeMessage?.content.contains("Company: Instagram") == true)
        #expect(knowledgeMessage?.content.contains("Company: Claude AI") == true)
        #expect(knowledgeMessage?.content.contains("Company: Munus") == true)
        #expect(knowledgeMessage?.content.contains("Company: Lark") == true)
    }

    @Test
    func controllerInjectsCreativeSkillContext() async throws {
        let provider = CapturingProvider()
        let controller = ChatSessionController(
            provider: provider,
            store: InMemoryConversationStore(),
            learningStore: InMemoryLearningStore()
        )

        await controller.send("Add comic creation, picture design, and short videos capabilities")

        let captured = await provider.lastMessages()
        let skillMessage = captured.first(where: { $0.role == .system && $0.content.contains("skill context") })

        #expect(skillMessage?.content.contains("Skill: Comic Book Creation") == true)
        #expect(skillMessage?.content.contains("Skill: Picture Design") == true)
        #expect(skillMessage?.content.contains("Skill: Short Video Creation") == true)
        #expect(skillMessage?.content.contains("Recommended plug-ins:") == true)
        #expect(skillMessage?.content.contains("Auto-selected skills:") == true)
        #expect(skillMessage?.content.contains("Auto-selected plug-ins:") == true)
    }

    @Test
    func controllerInjectsAnyCrossCanvaAndByteDanceKnowledgeContext() async throws {
        let provider = CapturingProvider()
        let controller = ChatSessionController(
            provider: provider,
            store: InMemoryConversationStore(),
            learningStore: InMemoryLearningStore()
        )

        await controller.send("Add AnyCross, Canva, and ByteDance video and picture generating features with plugin support")

        let captured = await provider.lastMessages()
        let knowledgeMessage = captured.first(where: { $0.role == .system && $0.content.contains("company knowledge base context") })

        #expect(knowledgeMessage?.content.contains("Company: AnyCross") == true)
        #expect(knowledgeMessage?.content.contains("Company: Canva") == true)
        #expect(knowledgeMessage?.content.contains("Company: ByteDance") == true)
        #expect(knowledgeMessage?.content.contains("Cross-platform plug-in ideas:") == true)
    }

    @Test
    func controllerMatchesPictureDesignAliasToImageCreationSkill() async throws {
        let provider = CapturingProvider()
        let controller = ChatSessionController(
            provider: provider,
            store: InMemoryConversationStore(),
            learningStore: InMemoryLearningStore()
        )

        await controller.send("Need picture design capabilities for our social team")

        let captured = await provider.lastMessages()
        let skillMessage = captured.first(where: { $0.role == .system && $0.content.contains("skill context") })

        #expect(skillMessage?.content.contains("Skill: Image Creation") == true)
        #expect(skillMessage?.content.contains("Skill: Picture Design") == true)
    }

    @Test
    func controllerAutoAddsImageAndLearningSkills() async throws {
        let provider = CapturingProvider()
        let controller = ChatSessionController(
            provider: provider,
            store: InMemoryConversationStore(),
            learningStore: InMemoryLearningStore()
        )
        let attachment = ChatImageAttachment(
            mimeType: "image/png",
            base64Data: Data([0xAA, 0xBB, 0xCC]).base64EncodedString()
        )

        await controller.send(
            "Enable maximum self learning and auto add plug-ins and skills",
            imageAttachments: [attachment]
        )

        let captured = await provider.lastMessages()
        let skillMessage = captured.first(where: { $0.role == .system && $0.content.contains("skill context") })

        #expect(skillMessage?.content.contains("Skill: Image Editing") == true)
        #expect(skillMessage?.content.contains("Skill: Adaptive Self Learning") == true)
        #expect(skillMessage?.content.contains("Skill: Plug-in and Skill Automation") == true)
        #expect(skillMessage?.content.contains("Multimodal Image Input") == true)
    }
}
