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

    let referenceArchive: ReferenceArchive
    private let controller: ChatSessionController?

    init() {
        let archive = ReferenceArchive()
        self.referenceArchive = archive
        self.setupGuidance = OnDeviceConsultant.availabilityMessage
        let provider = OnDeviceConsultant()

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let historyURL = appSupport
            .appendingPathComponent("LarkAISolutionsConsultant", isDirectory: true)
            .appendingPathComponent("conversation.json")
        let learningURL = appSupport
            .appendingPathComponent("LarkAISolutionsConsultant", isDirectory: true)
            .appendingPathComponent("learning.json")

        self.controller = ChatSessionController(
            provider: ReferenceAwareProvider(base: provider, archive: archive),
            store: FileConversationStore(fileURL: historyURL),
            learningStore: FileLearningStore(fileURL: learningURL)
        )
    }

    func bootstrap() async {
        setupGuidance = OnDeviceConsultant.availabilityMessage
        guard let controller else { return }
        await controller.bootstrap()
        sync()
    }

    func send() async {
        setupGuidance = OnDeviceConsultant.availabilityMessage
        guard setupGuidance == nil, let controller, !isLoading else { return }
        isLoading = true
        let currentInput = input
        input = ""
        await controller.send(currentInput)
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


}

struct ContentView: View {
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var voiceController = VoiceInteractionController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingMemories = false

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
                        description: Text("Chat uses Apple’s on-device model. Open Memories to read your saved notes.")
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

                if let guidance = viewModel.setupGuidance {
                    Text(guidance).font(.footnote).padding(.horizontal)
                    Button("Check on-device model") {
                        viewModel.setupGuidance = OnDeviceConsultant.availabilityMessage
                    }
                }
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                HStack {
                    TextField("Ask your on-device consultant", text: $viewModel.input)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.setupGuidance != nil)
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
                        || viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

                if viewModel.isLoading {
                    ProgressView("Consulting…")
                        .padding(.bottom)
                }
            }
            .navigationTitle("Pocket Consultant")
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { viewModel.setupGuidance = OnDeviceConsultant.availabilityMessage }
            }
            .sheet(isPresented: $showingMemories) {
                ReferenceMemoriesView(archive: viewModel.referenceArchive)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !viewModel.referenceArchive.entries.isEmpty || viewModel.referenceArchive.warning != nil {
                        Button("Memories") { showingMemories = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        Task { await viewModel.clear() }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .onDisappear {
                voiceController.stopListening()
                voiceController.stopSpeaking()
            }
        }
    }

}
