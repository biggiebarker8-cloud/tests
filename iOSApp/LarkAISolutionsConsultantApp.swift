import SwiftUI
import LarkAISolutionsConsultant

@main
struct LarkAISolutionsConsultantApp: App {
    @StateObject private var viewModel = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .task {
                    await viewModel.bootstrap()
                }
        }
    }
}
