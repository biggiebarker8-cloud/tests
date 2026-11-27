import SwiftUI
import LarkAISolutionsConsultant

@main
struct PocketConsultantApp: App {
    @StateObject private var viewModel = ChatViewModel()

    var body: some Scene {
        Window("Pocket Consultant", id: "consultant") {
            MacChatView(viewModel: viewModel)
                .frame(minWidth: 600, minHeight: 420)
                .task { await viewModel.bootstrap() }
        }
        .defaultSize(width: 780, height: 600)
    }
}

private struct MacChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var showingMemories = false
    @State private var showingSources = false
    @State private var confirmingClear = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.messages.isEmpty {
                ContentUnavailableView(
                    "Start a conversation", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Chat on this Mac, or open Memories to read your saved notes.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(viewModel.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.role == .user ? "You" : "Pocket Consultant")
                                .font(.caption.bold()).foregroundStyle(.secondary)
                            Text(message.content).textSelection(.enabled)
                        }
                        .padding(.vertical, 5)
                        .id(message.id)
                    }
                    .onChange(of: viewModel.messages.last?.id, initial: true) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let guidance = viewModel.setupGuidance {
                    HStack {
                        Text(guidance).font(.callout)
                        Button("Check again") { viewModel.setupGuidance = OnDeviceConsultant.availabilityMessage }
                    }
                }
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red) }
                HStack {
                    TextField("Ask your on-device consultant", text: $viewModel.input)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.setupGuidance != nil)
                        .onSubmit { if canSend { Task { await viewModel.send() } } }
                    if viewModel.isLoading { ProgressView().controlSize(.small) }
                    Button("Send") { Task { await viewModel.send() } }
                        .disabled(!canSend)
                }
            }
            .padding()
        }
        .toolbar {
            Button("Memories", systemImage: "books.vertical") { showingMemories = true }
            Button("Sources", systemImage: "doc.text.magnifyingglass") { showingSources = true }
            Button("Clear chat", systemImage: "trash") { confirmingClear = true }
                .disabled(viewModel.isLoading || viewModel.messages.isEmpty)
        }
        .confirmationDialog("Clear chat and learned history on this Mac?", isPresented: $confirmingClear) {
            Button("Clear chat", role: .destructive) { Task { await viewModel.clear() } }
        } message: { Text("Your source archive stays available.") }
        .sheet(isPresented: $showingMemories) {
            ReferenceMemoriesView(viewModel: viewModel).frame(minWidth: 560, minHeight: 400)
        }
        .sheet(isPresented: $showingSources) {
            PlatformSourcesView().frame(minWidth: 560, minHeight: 400)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.setupGuidance = OnDeviceConsultant.availabilityMessage }
        }
    }

    private var canSend: Bool {
        viewModel.setupGuidance == nil && !viewModel.isLoading &&
            !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
