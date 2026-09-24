import SwiftUI
import LarkAISolutionsConsultant

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let controller: ChatSessionController

    init() {
        let config = AppConfig.fromEnvironment()
        let provider: AIProvider = config.endpoint == nil ? MockAIProvider() : HTTPAIProvider(configuration: config)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let historyURL = appSupport
            .appendingPathComponent("LarkAISolutionsConsultant", isDirectory: true)
            .appendingPathComponent("conversation.json")

        self.controller = ChatSessionController(
            provider: provider,
            store: FileConversationStore(fileURL: historyURL)
        )
    }

    func bootstrap() async {
        await controller.bootstrap()
        sync()
    }

    func send() async {
        let currentInput = input
        input = ""
        await controller.send(currentInput)
        sync()
    }

    func clear() async {
        await controller.clear()
        sync()
    }

    private func sync() {
        messages = controller.messages

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

    var body: some View {
        NavigationStack {
            VStack {
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
                    Button("Send") {
                        Task { await viewModel.send() }
                    }
                    .disabled(viewModel.isLoading)
                }
                .padding()

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
        }
    }
}
