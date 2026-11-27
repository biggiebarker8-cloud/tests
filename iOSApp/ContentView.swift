import SwiftUI
import LarkAISolutionsConsultant

struct ContentView: View {
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var voiceController = VoiceInteractionController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingMemories = false
    @State private var showingSources = false
    @State private var showingOpenAI = false

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
                        description: Text("Chat provider: \(viewModel.providerName). Open Memories to read your saved notes.")
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
                        viewModel.refreshAvailability()
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
                    TextField("Ask your consultant", text: $viewModel.input)
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
                if newPhase == .active { viewModel.refreshAvailability() }
            }
            .sheet(isPresented: $showingMemories) {
                ReferenceMemoriesView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingOpenAI) { OpenAISettings(viewModel: viewModel) }
            .sheet(isPresented: $showingSources) {
                PlatformSourcesView(providerName: viewModel.providerName)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("OpenAI") { showingOpenAI = true }.disabled(viewModel.isLoading)
                    Button("Sources") { showingSources = true }
                    Button("Memories") { showingMemories = true }
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
