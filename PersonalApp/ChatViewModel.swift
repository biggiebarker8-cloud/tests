import SwiftUI
import LarkAISolutionsConsultant

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var memories: [LearnedMemory] = []
    @Published var topTopics: [String] = []
    @Published var userGoals: [String] = []
    @Published var input: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var setupGuidance: String?
    @Published private(set) var usesOpenAI = UserDefaults.standard.bool(forKey: PersonalOpenAIKey.selection)
    var providerName: String { usesOpenAI ? "OpenAI · " + OpenAIConsultant.model : "Apple · on device" }

    func selectOpenAI(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PersonalOpenAIKey.selection)
        usesOpenAI = enabled
        errorMessage = nil
        refreshAvailability()
    }

    func refreshAvailability() {
        setupGuidance = usesOpenAI ? nil : OnDeviceConsultant.availabilityMessage
    }

    @Published private(set) var referenceArchive: ReferenceArchive
    private let importedFile: URL
    private let provider: ReferenceAwareProvider
    private let controller: ChatSessionController
    private var didBootstrap = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LarkAISolutionsConsultant", isDirectory: true)
        let importedFile = support.appendingPathComponent("imported-notes.json")
        let archive = ReferenceArchive(importedFile: importedFile)
        let provider = ReferenceAwareProvider(base: PersonalChatProvider(), archive: archive)
        self.importedFile = importedFile
        self.referenceArchive = archive
        self.provider = provider
        let historyURL = support.appendingPathComponent("conversation.json")
        let learningURL = support.appendingPathComponent("learning.json")

        self.controller = ChatSessionController(
            provider: provider,
            store: FileConversationStore(fileURL: historyURL),
            learningStore: FileLearningStore(fileURL: learningURL)
        )
        refreshAvailability()
    }

    func bootstrap() async {
        refreshAvailability()
        guard !didBootstrap else { return }
        didBootstrap = true
        isLoading = true
        await controller.bootstrap()
        sync()
    }

    func send() async {
        refreshAvailability()
        guard setupGuidance == nil, !isLoading else { return }
        isLoading = true
        let currentInput = input
        input = ""
        await controller.send(currentInput)
        sync()
    }

    func clear() async {
        guard !isLoading else { return }
        isLoading = true
        await controller.clear()
        sync()
    }

    func importArchive(from file: URL) async throws {
        let accessing = file.startAccessingSecurityScopedResource()
        defer { if accessing { file.stopAccessingSecurityScopedResource() } }
        try ReferenceArchive.importFile(file, into: importedFile)
        let archive = ReferenceArchive(importedFile: importedFile)
        await provider.updateArchive(archive)
        referenceArchive = archive
    }

    private func sync() {
        messages = controller.messages
        memories = controller.memories
            .sorted(by: { $0.strength > $1.strength })
            .prefix(5)
            .map { $0 }
        topTopics = controller.learningProfile.topTopics
        userGoals = Array(controller.learningProfile.userGoals.suffix(3))

        switch controller.status {
        case .loading:
            isLoading = true
            errorMessage = nil
        case .idle:
            isLoading = false
            errorMessage = nil
        case .error(let message):
            isLoading = false
            errorMessage = message
        }
    }
}
