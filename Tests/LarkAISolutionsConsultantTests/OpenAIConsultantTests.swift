import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LarkAISolutionsConsultant

@Test func openAIRequestUsesFixedDestinationAndSelectedContext() throws {
    let history = (0..<10).map { ChatMessage(role: .assistant, content: "old turn \($0)") }
    let messages = [ChatMessage(role: .system, content: "a dated note")] + history +
        [ChatMessage(role: .user, content: "current question")]
    let request = try OpenAIConsultant.request(for: messages, key: "test-only-value")
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-value")
    let body = try #require(request.httpBody)
    #expect(!String(decoding: body, as: UTF8.self).contains("test-only-value"))
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["store"] as? Bool == false)
    let input = try #require(json["input"] as? [[String: String]])
    #expect(input.first?["content"]?.contains("a dated note") == true)
    #expect(input.first?["role"] == "user")
    #expect(input.count == 8)
    #expect(input.last?["content"] == "current question")
}

@Test func openAIDecodesAssistantTextAndSurfacesErrors() throws {
    let data = Data(#"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"hello"}]}]}"#.utf8)
    #expect(try OpenAIConsultant.reply(from: data, status: 200) == "hello")
    #expect(throws: OpenAIConsultantError.rateLimited) {
        try OpenAIConsultant.reply(from: Data(), status: 429)
    }
    #expect(throws: OpenAIConsultantError.invalidReply) {
        try OpenAIConsultant.reply(from: Data(), status: 200)
    }
}
