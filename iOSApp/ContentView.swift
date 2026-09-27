import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
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
    @Published var pendingAttachments: [ChatImageAttachment] = []

    private let controller: ChatSessionController?
    private let configurationIssue: String?

    init() {
        let config = AppConfig.fromEnvironment()
        let endpointValue = ProcessInfo.processInfo.environment["LARK_AI_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let endpoint = config.endpoint else {
            if let endpointValue, !endpointValue.isEmpty {
                configurationIssue = "LARK_AI_ENDPOINT is invalid. Set a valid HTTPS backend URL."
            } else {
                configurationIssue = "Set LARK_AI_ENDPOINT to enable chat."
            }
            controller = nil
            return
        }

        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            configurationIssue = "Set LARK_AI_API_KEY to enable chat."
            controller = nil
            return
        }

        let provider: AIProvider = HTTPAIProvider(
            configuration: AppConfig(
                endpoint: endpoint,
                apiKey: apiKey,
                model: config.model,
                maxRetryCount: config.maxRetryCount
            )
        )

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let historyURL = appSupport
            .appendingPathComponent("AIConsultant", isDirectory: true)
            .appendingPathComponent("conversation.json")
        let learningURL = appSupport
            .appendingPathComponent("AIConsultant", isDirectory: true)
            .appendingPathComponent("learning.json")

        self.controller = ChatSessionController(
            provider: provider,
            store: FileConversationStore(fileURL: historyURL),
            learningStore: FileLearningStore(fileURL: learningURL)
        )
        self.configurationIssue = nil
    }

    func bootstrap() async {
        guard let controller else {
            isLoading = false
            errorMessage = configurationIssue
            return
        }
        await controller.bootstrap()
        sync()
    }

    func send() async {
        guard let controller else {
            errorMessage = configurationIssue
            return
        }
        let currentInput = input
        let currentAttachments = pendingAttachments
        input = ""
        pendingAttachments = []
        await controller.send(currentInput, imageAttachments: currentAttachments)
        sync()
    }

    func clear() async {
        guard let controller else {
            errorMessage = configurationIssue
            return
        }
        await controller.clear()
        sync()
    }

    private func sync() {
        guard let controller else {
            messages = []
            memories = []
            topTopics = []
            userGoals = []
            isLoading = false
            errorMessage = configurationIssue
            return
        }
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

    func addImageAttachment(data: Data, mimeType: String) {
        pendingAttachments.append(
            ChatImageAttachment(
                mimeType: mimeType,
                base64Data: data.base64EncodedString()
            )
        )
    }

    func clearPendingAttachments() {
        pendingAttachments = []
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            VStack {
                if !viewModel.topTopics.isEmpty || !viewModel.userGoals.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !viewModel.topTopics.isEmpty {
                            Text("Learned Topics: \(viewModel.topTopics.joined(separator: ", "))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if !viewModel.userGoals.isEmpty {
                            Text("Recent Goals: \(viewModel.userGoals.joined(separator: " • "))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                if viewModel.messages.isEmpty {
                    ContentUnavailableView(
                        "Start a consulting session",
                        systemImage: "message",
                        description: Text("Ask for implementation advice, architecture support, or rollout guidance.")
                    )
                } else {
                    List(viewModel.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(message.content)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                }

                if !viewModel.memories.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Memory Highlights")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(viewModel.memories) { memory in
                            Text("• \(memory.summary)")
                                .font(.footnote)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                HStack {
                    TextField("Describe your challenge", text: $viewModel.input)
                        .textFieldStyle(.roundedBorder)
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 6,
                        matching: .images
                    ) {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .disabled(viewModel.isLoading)
                    Button("Send") {
                        Task { await viewModel.send() }
                    }
                    .disabled(viewModel.isLoading || (viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingAttachments.isEmpty))
                }
                .padding()

                if !viewModel.pendingAttachments.isEmpty {
                    HStack(spacing: 12) {
                        Text("Attached images: \(viewModel.pendingAttachments.count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Remove") {
                            viewModel.clearPendingAttachments()
                        }
                        .font(.footnote)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                if viewModel.isLoading {
                    ProgressView("Consulting…")
                        .padding(.bottom)
                }
            }
            .navigationTitle("AI Consultant")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        Task { await viewModel.clear() }
                    }
                }
            }
            .onChange(of: selectedPhotoItems) { _, newItems in
                Task {
                    await loadSelectedPhotos(newItems)
                }
            }
        }
    }

}

private extension ContentView {
    func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }

        for item in items {
            guard let imageData = try? await item.loadTransferable(type: Data.self) else {
                continue
            }

            let mimeType = item.supportedContentTypes
                .first(where: { $0.conforms(to: .image) })?
                .preferredMIMEType ?? "image/jpeg"

            if mimeType.hasPrefix("image/") {
                viewModel.addImageAttachment(data: imageData, mimeType: mimeType)
            }
        }

        selectedPhotoItems = []
    }
}
