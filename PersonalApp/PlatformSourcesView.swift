import SwiftUI
import LarkAISolutionsConsultant

struct PlatformSourcesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("This build") {
                    LabeledContent("Chat model", value: "Apple · on device")
                    LabeledContent("Lark account", value: "Disconnected")
                    LabeledContent("TikTok account", value: "Disconnected")
                }
                Section {
                    ForEach(PlatformGuide.all) { guide in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(guide.title).font(.headline)
                            Text(guide.summary)
                            Link("Open official guide", destination: guide.url)
                                .accessibilityLabel("Open official guide for \(guide.title)")
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Public guides · saved 27 Nov 2026")
                } footer: {
                    Text("These summaries are available offline. Opening a guide takes you to the publisher’s website.")
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
