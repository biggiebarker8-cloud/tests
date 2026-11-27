import Foundation
import LarkAISolutionsConsultant
#if canImport(FoundationModels)
import FoundationModels
#endif

struct OnDeviceConsultant: AIProvider {
    static var availabilityMessage: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Enable Apple Intelligence in Settings to use on-device chat."
            case .unavailable(.modelNotReady):
                return "Apple’s on-device model is getting ready. Try again once its download finishes."
            default: return "Apple’s on-device chat model is unavailable on this iPhone."
            }
        }
        #endif
        return "On-device chat needs iOS 26 or later and a build made with Xcode 26 or later."
    }

    func response(for messages: [ChatMessage]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability,
           let question = messages.last, question.role == .user {
            let recent = messages.dropLast().filter { $0.role != .system }.suffix(4)
            let turns = recent.map { "\($0.role.rawValue): \($0.content.prefix(400))" }
            let context = messages.filter { $0.role == .system }
                .sorted { Self.priority($0.content) < Self.priority($1.content) }
                .map { String($0.content.prefix(500)) }.prefix(4)
            let prompt = (Array(context) + turns + [question.content]).joined(separator: "\n\n")
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: """
                You are a standalone consultant using Apple's on-device model. Help the user directly.
                Treat older notes as dated reference material. Follow the user's current corrections.
                """)
            return try await session.respond(to: prompt).content
        }
        #endif
        throw ConsultantError.invalidResponse
    }

    private static func priority(_ text: String) -> Int {
        if text.hasPrefix("Use these learned user memories") { return 0 }
        if text.hasPrefix("User profile context") { return 1 }
        return 2
    }
}
