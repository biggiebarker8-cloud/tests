import Foundation

public enum ConsultantError: Error, Equatable {
    case emptyUserInput
    case missingEndpoint
    case invalidResponse
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let content: String
    public let createdAt: Date

    public init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct AppConfig: Sendable {
    public let endpoint: URL?
    public let apiKey: String?
    public let model: String
    public let maxRetryCount: Int

    public init(endpoint: URL?, apiKey: String?, model: String = "lark-consultant-v1", maxRetryCount: Int = 2) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.maxRetryCount = maxRetryCount
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConfig {
        let endpoint = environment["LARK_AI_ENDPOINT"].flatMap(URL.init(string:))
        let apiKey = environment["LARK_AI_API_KEY"]
        let model = environment["LARK_AI_MODEL"] ?? "lark-consultant-v1"
        let retries = Int(environment["LARK_AI_MAX_RETRIES"] ?? "2") ?? 2

        return AppConfig(endpoint: endpoint, apiKey: apiKey, model: model, maxRetryCount: max(0, retries))
    }
}

public protocol AIProvider: Sendable {
    func response(for messages: [ChatMessage]) async throws -> String
}

public struct RetryPolicy: Sendable {
    public let attempts: Int
    public let delayNanoseconds: UInt64

    public init(attempts: Int = 3, delayNanoseconds: UInt64 = 250_000_000) {
        self.attempts = max(1, attempts)
        self.delayNanoseconds = delayNanoseconds
    }
}

public func executeWithRetry<T>(policy: RetryPolicy, operation: @escaping () async throws -> T) async throws -> T {
    var attempt = 0
    var lastError: Error?

    while attempt < policy.attempts {
        do {
            return try await operation()
        } catch {
            lastError = error
            attempt += 1
            if attempt < policy.attempts {
                try await Task.sleep(nanoseconds: policy.delayNanoseconds)
            }
        }
    }

    throw lastError ?? ConsultantError.invalidResponse
}

public struct MockAIProvider: AIProvider {
    public init() {}

    public func response(for messages: [ChatMessage]) async throws -> String {
        let latest = messages.last(where: { $0.role == .user })?.content ?? ""
        return "Consultant response: \(latest)"
    }
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPAIProvider: AIProvider {
    private let configuration: AppConfig
    private let session: URLSession

    public init(configuration: AppConfig, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func response(for messages: [ChatMessage]) async throws -> String {
        guard let endpoint = configuration.endpoint else {
            throw ConsultantError.missingEndpoint
        }

        guard let latestUserMessage = messages.last(where: { $0.role == .user })?.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !latestUserMessage.isEmpty
        else {
            throw ConsultantError.emptyUserInput
        }

        let payload = APIRequest(
            model: configuration.model,
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) }
        )

        let requestOperation = {
            () async throws -> String in
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key = configuration.apiKey, !key.isEmpty {
                request.setValue("******", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  200..<300 ~= httpResponse.statusCode
            else {
                throw ConsultantError.invalidResponse
            }

            let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
            let text = decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw ConsultantError.invalidResponse
            }
            return text
        }

        return try await executeWithRetry(
            policy: RetryPolicy(attempts: max(1, configuration.maxRetryCount + 1)),
            operation: requestOperation
        )
    }
}

private struct APIRequest: Codable {
    let model: String
    let messages: [APIMessage]
}

private struct APIMessage: Codable {
    let role: String
    let content: String
}

private struct APIResponse: Codable {
    let reply: String
}

public protocol ConversationStore: Sendable {
    func load() async throws -> [ChatMessage]
    func save(_ messages: [ChatMessage]) async throws
    func clear() async throws
}

public actor FileConversationStore: ConversationStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted]
    }

    public func load() async throws -> [ChatMessage] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([ChatMessage].self, from: data)
    }

    public func save(_ messages: [ChatMessage]) async throws {
        let data = try encoder.encode(messages)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() async throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

public actor InMemoryConversationStore: ConversationStore {
    private var messages: [ChatMessage]

    public init(messages: [ChatMessage] = []) {
        self.messages = messages
    }

    public func load() async throws -> [ChatMessage] {
        messages
    }

    public func save(_ messages: [ChatMessage]) async throws {
        self.messages = messages
    }

    public func clear() async throws {
        messages = []
    }
}

@MainActor
public final class ChatSessionController {
    public enum Status: Equatable {
        case idle
        case loading
        case error(String)
    }

    public private(set) var messages: [ChatMessage] = []
    public private(set) var status: Status = .idle

    private let provider: AIProvider
    private let store: ConversationStore

    public init(provider: AIProvider, store: ConversationStore) {
        self.provider = provider
        self.store = store
    }

    public func bootstrap() async {
        do {
            messages = try await store.load()
            status = .idle
        } catch {
            status = .error("Failed to load history")
        }
    }

    public func clear() async {
        do {
            try await store.clear()
            messages = []
            status = .idle
        } catch {
            status = .error("Failed to clear history")
        }
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = .error("Message cannot be empty")
            return
        }

        status = .loading
        let userMessage = ChatMessage(role: .user, content: trimmed)
        messages.append(userMessage)

        do {
            try await store.save(messages)
            let reply = try await provider.response(for: messages)
            messages.append(ChatMessage(role: .assistant, content: reply))
            try await store.save(messages)
            status = .idle
        } catch {
            status = .error("Unable to get consultant response")
        }
    }
}
