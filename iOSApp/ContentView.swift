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
    @Published var setupGuidance: String?

    private let controller: ChatSessionController?

    init() {
        let config = AppConfig.fromEnvironment()
        guard let endpoint = config.endpoint,
              let rawKey = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawKey.isEmpty
        else {
            self.controller = nil
            self.setupGuidance = "Live API is not configured. In Xcode, open the app scheme Run settings and set LARK_AI_ENDPOINT and LARK_AI_API_KEY."
            return
        }

        let provider: AIProvider = HTTPAIProvider(
            configuration: AppConfig(
                endpoint: endpoint,
                apiKey: rawKey,
                model: config.model,
                maxRetryCount: config.maxRetryCount
            )
        )

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let historyURL = appSupport
            .appendingPathComponent("LarkAISolutionsConsultant", isDirectory: true)
            .appendingPathComponent("conversation.json")
        let learningURL = appSupport
            .appendingPathComponent("LarkAISolutionsConsultant", isDirectory: true)
            .appendingPathComponent("learning.json")

        self.controller = ChatSessionController(
            provider: provider,
            store: FileConversationStore(fileURL: historyURL),
            learningStore: FileLearningStore(fileURL: learningURL)
        )
    }

    func bootstrap() async {
        guard let controller else { return }
        await controller.bootstrap()
        sync()
    }

    func send() async {
        guard let controller else { return }
        let currentInput = input
        let currentAttachments = pendingAttachments
        input = ""
        pendingAttachments = []
        await controller.send(currentInput, imageAttachments: currentAttachments)
        sync()
    }

    func clear() async {
        guard let controller else { return }
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
    @StateObject private var voiceController = VoiceInteractionController()
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
                            HStack {
                                Text(message.role.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if message.role == .assistant {
                                    Button {
                                        voiceController.speak(message.content)
                                    } label: {
                                        Image(systemName: "speaker.wave.2")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Read response aloud")
                                }
                            }
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
                    TextField("Ask about a photo or describe a challenge", text: $viewModel.input)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.setupGuidance != nil)
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 6,
                        matching: .images
                    ) {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .disabled(viewModel.isLoading || viewModel.setupGuidance != nil)
                    .accessibilityLabel("Add an image to ask about")
                    Button {
                        if voiceController.isListening {
                            voiceController.stopListening()
                        } else {
                            Task {
                                await voiceController.startListening { transcript in
                                    viewModel.input = transcript
                                }
                            }
                        }
                    } label: {
                        Image(systemName: voiceController.isListening ? "stop.circle.fill" : "mic")
                    }
                    .disabled(
                        viewModel.isLoading
                        || viewModel.setupGuidance != nil
                        || voiceController.isFinishingRecognition
                    )
                    .accessibilityLabel(voiceController.isListening ? "Stop voice input" : "Start voice input")
                    Button("Send") {
                        voiceController.stopListening()
                        Task { await viewModel.send() }
                    }
                    .disabled(
                        viewModel.isLoading
                        || viewModel.setupGuidance != nil
                        || voiceController.isFinishingRecognition
                        || (viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingAttachments.isEmpty)
                    )
                }
                .padding()

                if voiceController.isListening {
                    Label("Listening… spoken words appear in the text field", systemImage: "waveform")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if voiceController.isFinishingRecognition {
                    Label("Finishing transcription…", systemImage: "waveform")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if voiceController.isSpeaking {
                    Button("Stop speaking", systemImage: "stop.fill") {
                        voiceController.stopSpeaking()
                    }
                    .font(.footnote)
                }
                if let voiceError = voiceController.errorMessage {
                    Text(voiceError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

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
            .navigationTitle("Lark AI Consultant")
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
            .onDisappear {
                voiceController.stopListening()
                voiceController.stopSpeaking()
            }
        }
    }

}

private extension ContentView {
    @MainActor
    func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }

        for item in items {
            do {
                guard let imageData = try await item.loadTransferable(type: Data.self) else {
                    viewModel.errorMessage = "Couldn't load a selected image. Please try selecting it again."
                    continue
                }

                let mimeType = item.supportedContentTypes
                    .first(where: { $0.conforms(to: .image) })?
                    .preferredMIMEType ?? "image/jpeg"

                if mimeType.hasPrefix("image/") {
                    viewModel.addImageAttachment(data: imageData, mimeType: mimeType)
                }
            } catch {
                viewModel.errorMessage = "Couldn't load a selected image: \(error.localizedDescription)"
            }
        }

        selectedPhotoItems = []
    }
}
