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
    public let attachments: [ChatImageAttachment]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        attachments: [ChatImageAttachment] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.createdAt = createdAt
    }
}

public struct ChatImageAttachment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let mimeType: String
    public let base64Data: String

    public init(id: UUID = UUID(), mimeType: String, base64Data: String) {
        self.id = id
        self.mimeType = mimeType
        self.base64Data = base64Data
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

        guard let latestUserMessage = messages.last(where: { $0.role == .user }),
              !latestUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !latestUserMessage.attachments.isEmpty
        else {
            throw ConsultantError.emptyUserInput
        }

        let payload = APIRequest(
            model: configuration.model,
            messages: messages.map {
                .init(
                    role: $0.role.rawValue,
                    content: APIMessage.Content(from: $0)
                )
            }
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
    let content: Content

    enum Content: Codable {
        case text(String)
        case multimodal([Part])

        init(from message: ChatMessage) {
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.attachments.isEmpty {
                self = .text(trimmed)
                return
            }

            var parts: [Part] = []
            if !trimmed.isEmpty {
                parts.append(.text(trimmed))
            }

            parts.append(
                contentsOf: message.attachments.map {
                    .imageURL("data:\($0.mimeType);base64,\($0.base64Data)")
                }
            )
            self = .multimodal(parts)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
                return
            }
            self = .multimodal(try container.decode([Part].self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value):
                try container.encode(value)
            case .multimodal(let parts):
                try container.encode(parts)
            }
        }
    }

    struct Part: Codable {
        struct ImageURLPayload: Codable {
            let url: String
        }

        let type: String
        let text: String?
        let imageURL: ImageURLPayload?

        static func text(_ value: String) -> Part {
            Part(type: "text", text: value, imageURL: nil)
        }

        static func imageURL(_ dataURL: String) -> Part {
            Part(type: "image_url", text: nil, imageURL: .init(url: dataURL))
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }
    }
}

private struct APIResponse: Decodable {
    let reply: String

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let directReply = try? keyed.decode(String.self, forKey: .reply) {
            reply = directReply
            return
        }

        let keyed = try decoder.container(keyedBy: OpenAICodingKeys.self)
        let choices = try keyed.decode([OpenAIChoice].self, forKey: .choices)
        guard let first = choices.first else {
            throw ConsultantError.invalidResponse
        }
        reply = first.message.textContent
    }

    private enum CodingKeys: String, CodingKey {
        case reply
    }

    private enum OpenAICodingKeys: String, CodingKey {
        case choices
    }

    private struct OpenAIChoice: Decodable {
        let message: OpenAIMessage
    }

    private struct OpenAIMessage: Decodable {
        let content: OpenAIContent

        var textContent: String {
            switch content {
            case .text(let value):
                return value
            case .parts(let parts):
                return parts
                    .compactMap { part in
                        switch part {
                        case .text(let value):
                            return value
                        case .other:
                            return nil
                        }
                    }
                    .joined(separator: "\n")
            }
        }
    }

    private enum OpenAIContent: Decodable {
        case text(String)
        case parts([OpenAIContentPart])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
                return
            }
            self = .parts(try container.decode([OpenAIContentPart].self))
        }
    }

    private enum OpenAIContentPart: Decodable {
        case text(String)
        case other

        private enum CodingKeys: String, CodingKey {
            case type
            case text
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            if type == "text" {
                self = .text(try container.decode(String.self, forKey: .text))
            } else {
                self = .other
            }
        }
    }
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

public struct LearnedMemory: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var summary: String
    public var keywords: [String]
    public var strength: Double
    public var reinforcementCount: Int
    public var recallCount: Int
    public var lastUpdatedAt: Date

    public init(
        id: UUID = UUID(),
        summary: String,
        keywords: [String],
        strength: Double = 0.5,
        reinforcementCount: Int = 1,
        recallCount: Int = 0,
        lastUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.summary = summary
        self.keywords = keywords
        self.strength = max(0, min(1, strength))
        self.reinforcementCount = max(1, reinforcementCount)
        self.recallCount = max(0, recallCount)
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public struct LearningProfile: Codable, Equatable, Sendable {
    public var topicFrequency: [String: Int]
    public var userGoals: [String]

    public init(topicFrequency: [String: Int] = [:], userGoals: [String] = []) {
        self.topicFrequency = topicFrequency
        self.userGoals = userGoals
    }

    public var topTopics: [String] {
        topicFrequency
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(5)
            .map(\ .key)
    }
}

public struct LearningState: Codable, Equatable, Sendable {
    public var memories: [LearnedMemory]
    public var profile: LearningProfile

    public init(memories: [LearnedMemory] = [], profile: LearningProfile = .init()) {
        self.memories = memories
        self.profile = profile
    }
}

public protocol LearningStore: Sendable {
    func load() async throws -> LearningState
    func save(_ state: LearningState) async throws
    func clear() async throws
}

public actor InMemoryLearningStore: LearningStore {
    private var state: LearningState

    public init(state: LearningState = .init()) {
        self.state = state
    }

    public func load() async throws -> LearningState {
        state
    }

    public func save(_ state: LearningState) async throws {
        self.state = state
    }

    public func clear() async throws {
        state = .init()
    }
}

public actor FileLearningStore: LearningStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted]
    }

    public func load() async throws -> LearningState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .init()
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(LearningState.self, from: data)
    }

    public func save(_ state: LearningState) async throws {
        let data = try encoder.encode(state)
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

public actor LearningEngine {
    private let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "how", "i", "in", "is", "it",
        "of", "on", "or", "that", "the", "this", "to", "we", "with", "you", "your"
    ]

    public init() {}

    public func learn(from userText: String, existing: [LearnedMemory], profile: LearningProfile) -> LearningState {
        let tokens = keywords(from: userText)
        guard !tokens.isEmpty else {
            return LearningState(memories: existing, profile: profile)
        }

        var updatedMemories = existing
        var updatedProfile = profile
        trackTopics(tokens, profile: &updatedProfile)
        trackGoal(in: userText, profile: &updatedProfile)

        if let matchIndex = bestMatchIndex(for: tokens, in: updatedMemories) {
            var memory = updatedMemories[matchIndex]
            memory.reinforcementCount += 1
            memory.strength = min(1, memory.strength + 0.08)
            memory.lastUpdatedAt = Date()
            memory.summary = mergedSummary(existing: memory.summary, incoming: userText)
            memory.keywords = Array(Set(memory.keywords + tokens)).sorted().prefix(12).map { $0 }
            updatedMemories[matchIndex] = memory
        } else {
            let memory = LearnedMemory(
                summary: summarized(userText),
                keywords: tokens,
                strength: 0.55,
                reinforcementCount: 1,
                recallCount: 0,
                lastUpdatedAt: Date()
            )
            updatedMemories.append(memory)
        }

        return LearningState(memories: cappedMemories(updatedMemories), profile: updatedProfile)
    }

    public func recall(for query: String, memories: [LearnedMemory], limit: Int = 3) -> [LearnedMemory] {
        let queryTokens = Set(keywords(from: query))
        guard !queryTokens.isEmpty else {
            return []
        }

        let scored = memories.compactMap { memory -> (LearnedMemory, Double)? in
            let overlap = overlapScore(queryTokens, Set(memory.keywords))
            guard overlap > 0 else { return nil }
            let recency = recencyScore(memory.lastUpdatedAt)
            let score = overlap * 0.65 + memory.strength * 0.25 + recency * 0.10
            return (memory, score)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\ .0)
    }

    public func markRecalled(_ memory: LearnedMemory, in memories: [LearnedMemory]) -> [LearnedMemory] {
        memories.map { current in
            guard current.id == memory.id else { return current }
            var updated = current
            updated.recallCount += 1
            updated.strength = min(1, updated.strength + 0.03)
            updated.lastUpdatedAt = Date()
            return updated
        }
    }

    private func keywords(from text: String) -> [String] {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }

        var frequency: [String: Int] = [:]
        for token in tokens {
            frequency[token, default: 0] += 1
        }

        return frequency
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(8)
            .map(\ .key)
    }

    private func trackTopics(_ tokens: [String], profile: inout LearningProfile) {
        for token in tokens.prefix(3) {
            profile.topicFrequency[token, default: 0] += 1
        }
    }

    private func trackGoal(in text: String, profile: inout LearningProfile) {
        let lowered = text.lowercased()
        let markers = ["i need", "i want", "goal", "my objective", "help me"]

        guard markers.contains(where: lowered.contains) else {
            return
        }

        let snippet = summarized(text)
        guard !profile.userGoals.contains(snippet) else {
            return
        }

        profile.userGoals.append(snippet)
        if profile.userGoals.count > 10 {
            profile.userGoals.removeFirst(profile.userGoals.count - 10)
        }
    }

    private func bestMatchIndex(for tokens: [String], in memories: [LearnedMemory]) -> Int? {
        let tokenSet = Set(tokens)
        let scored = memories.enumerated().map { index, memory in
            (index, overlapScore(tokenSet, Set(memory.keywords)))
        }

        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.25 else {
            return nil
        }

        return best.0
    }

    private func overlapScore(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func recencyScore(_ date: Date) -> Double {
        let hours = Date().timeIntervalSince(date) / 3600
        switch hours {
        case ..<24: return 1
        case ..<168: return 0.7
        case ..<720: return 0.4
        default: return 0.2
        }
    }

    private func summarized(_ text: String) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        guard !cleaned.isEmpty else { return "" }

        let words = cleaned.split(separator: " ")
        if words.count <= 18 {
            return cleaned
        }

        return words.prefix(18).joined(separator: " ") + "…"
    }

    private func mergedSummary(existing: String, incoming: String) -> String {
        let incomingSummary = summarized(incoming)
        guard existing.caseInsensitiveCompare(incomingSummary) != .orderedSame else {
            return existing
        }
        return summarized(existing + " / " + incomingSummary)
    }

    private func cappedMemories(_ memories: [LearnedMemory]) -> [LearnedMemory] {
        let sorted = memories.sorted { lhs, rhs in
            if lhs.strength == rhs.strength {
                return lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
            return lhs.strength > rhs.strength
        }

        return Array(sorted.prefix(60))
    }
}

private struct CompanyKnowledgeBaseEntry: Sendable {
    let name: String
    let aliases: [String]
    let overview: String
    let products: [String]
    let useCases: [String]
    let considerations: [String]

    func matches(_ text: String) -> Bool {
        aliases.contains { alias in
            let pattern = #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: alias) + #"(?!\w)"#
            return text.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

private enum CompanyKnowledgeBaseCatalog {
    static let entries: [CompanyKnowledgeBaseEntry] = [
        CompanyKnowledgeBaseEntry(
            name: "TikTok",
            aliases: ["tiktok", "tik tok"],
            overview: "Short-form video and commerce platform focused on discovery, creator-led campaigns, live selling, and performance marketing.",
            products: [
                "TikTok For Business ad formats for awareness, acquisition, and retargeting",
                "TikTok Shop for in-app product discovery, checkout, affiliates, and creator commerce",
                "Creator partnerships, Spark Ads, and user-generated content amplification"
            ],
            useCases: [
                "Driving consumer demand with creator-first campaigns and short-form storytelling",
                "Launching social commerce motions that connect content, creators, and conversion",
                "Testing rapid content iteration with performance signals from paid and organic channels"
            ],
            considerations: [
                "Creative velocity and authenticity usually matter more than polished brand production",
                "Measurement plans should separate awareness, engagement, and commerce outcomes",
                "Operational readiness is needed for creator management, moderation, and fulfillment"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "Lark",
            aliases: ["lark"],
            overview: "ByteDance workplace collaboration suite that combines messaging, docs, meetings, calendar, approvals, knowledge sharing, and workflow automation.",
            products: [
                "Messenger, Meetings, Calendar, Email, and collaborative Docs, Sheets, and Wiki",
                "Base and approval workflows for lightweight no-code operations and data management",
                "Open platform integrations, bots, and automation for enterprise process orchestration"
            ],
            useCases: [
                "Replacing fragmented workplace tools with a more unified collaboration stack",
                "Standardizing internal operations, approvals, onboarding, and knowledge management",
                "Improving cross-functional execution with shared documents, meetings, and workflows"
            ],
            considerations: [
                "Adoption plans should cover governance, workspace structure, permissions, and templates",
                "Migration planning is important for documents, chat norms, and admin controls",
                "Value realization often depends on connecting collaboration habits to business workflows"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "Wix",
            aliases: ["wix"],
            overview: "Website creation and digital business platform for SMBs, creators, and brands with commerce, scheduling, marketing, and app extensibility.",
            products: [
                "Website builder, CMS, SEO, analytics, and branded design tooling",
                "Wix Stores, bookings, events, memberships, and payments for online business operations",
                "Velo developer platform and app marketplace for custom experiences and integrations"
            ],
            useCases: [
                "Helping small businesses launch and manage web presence without heavy engineering",
                "Combining site publishing with commerce, appointments, and lead generation",
                "Extending packaged site workflows with custom logic, apps, and integrations"
            ],
            considerations: [
                "Template, CMS, and app choices should align with content model and scale expectations",
                "Commerce and scheduling flows need attention to payments, fulfillment, and customer lifecycle",
                "Custom extensibility is available, but platform constraints should be mapped early"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "ByteDance",
            aliases: ["bytedance", "byte dance"],
            overview: "Global technology company known for recommendation systems, creator ecosystems, collaboration software, and large-scale consumer platforms.",
            products: [
                "Consumer products including TikTok and other content discovery platforms",
                "Enterprise collaboration offerings such as Lark for productivity and workflow management",
                "Advertising, creator monetization, and ecosystem services built on recommendation infrastructure"
            ],
            useCases: [
                "Studying product strategy centered on discovery engines, engagement loops, and ecosystem growth",
                "Connecting consumer attention platforms with enterprise and monetization opportunities",
                "Benchmarking large-scale operations across content, creators, ads, and collaboration tools"
            ],
            considerations: [
                "Strategies should distinguish consumer platform priorities from enterprise software priorities",
                "Regulatory, trust, safety, and data governance topics often shape deployment decisions",
                "Cross-product narratives work best when grounded in measurable business outcomes"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "Shopify",
            aliases: ["shopify"],
            overview: "Commerce operating system for merchants spanning storefronts, checkout, payments, back-office workflows, apps, and omnichannel selling.",
            products: [
                "Online Store, Shop app, checkout, and headless commerce options",
                "Shopify Payments, Shop Pay, POS, fulfillment tooling, and order operations",
                "App ecosystem, B2B capabilities, internationalization, and marketing integrations"
            ],
            useCases: [
                "Launching and scaling direct-to-consumer and omnichannel commerce programs",
                "Unifying storefront, conversion, and order operations on a shared merchant platform",
                "Extending commerce workflows through apps, APIs, and partner integrations"
            ],
            considerations: [
                "Architecture choices should weigh theme-based, headless, and B2B requirements",
                "Checkout, payments, taxes, and fulfillment constraints affect implementation scope",
                "Growth plans should connect merchandising, conversion, retention, and operational efficiency"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "Amazon",
            aliases: ["amazon", "aws"],
            overview: "Broad commerce and cloud ecosystem spanning marketplace operations, retail media, fulfillment, and AWS infrastructure services.",
            products: [
                "Amazon marketplace, seller tools, fulfillment, and retail media opportunities",
                "AWS compute, storage, data, AI, security, and developer platform services",
                "Customer engagement surfaces including Prime, advertising, and operational logistics"
            ],
            useCases: [
                "Designing marketplace or seller strategies that balance catalog growth and operational control",
                "Planning cloud architecture, modernization, and AI initiatives on AWS",
                "Coordinating commerce, advertising, logistics, and infrastructure decisions across Amazon channels"
            ],
            considerations: [
                "Marketplace, retail, and AWS conversations should be scoped clearly because buying motions differ",
                "Cost, security, compliance, and operating model decisions are central for AWS recommendations",
                "Fulfillment, inventory, and advertising dependencies often drive commercial outcomes"
            ]
        )
    ]

    static func relevantEntries(for text: String) -> [CompanyKnowledgeBaseEntry] {
        let normalized = text.lowercased()
        return entries.filter { $0.matches(normalized) }
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
    public private(set) var memories: [LearnedMemory] = []
    public private(set) var learningProfile: LearningProfile = .init()

    private let provider: AIProvider
    private let store: ConversationStore
    private let learningStore: LearningStore
    private let learningEngine: LearningEngine

    public init(
        provider: AIProvider,
        store: ConversationStore,
        learningStore: LearningStore = InMemoryLearningStore(),
        learningEngine: LearningEngine = LearningEngine()
    ) {
        self.provider = provider
        self.store = store
        self.learningStore = learningStore
        self.learningEngine = learningEngine
    }

    public func bootstrap() async {
        do {
            messages = try await store.load()
            let learningState = try await learningStore.load()
            memories = learningState.memories
            learningProfile = learningState.profile
            status = .idle
        } catch {
            status = .error("Failed to load history")
        }
    }

    public func clear() async {
        do {
            try await store.clear()
            try await learningStore.clear()
            messages = []
            memories = []
            learningProfile = .init()
            status = .idle
        } catch {
            status = .error("Failed to clear history")
        }
    }

    public func send(_ text: String) async {
        await send(text, imageAttachments: [])
    }

    public func send(_ text: String, imageAttachments: [ChatImageAttachment]) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imageAttachments.isEmpty else {
            status = .error("Message cannot be empty")
            return
        }

        status = .loading
        let userMessage = ChatMessage(role: .user, content: trimmed, attachments: imageAttachments)
        messages.append(userMessage)

        do {
            try await store.save(messages)

            var providerMessages = messages

            if !trimmed.isEmpty {
                let updatedState = await learningEngine.learn(from: trimmed, existing: memories, profile: learningProfile)
                memories = updatedState.memories
                learningProfile = updatedState.profile

                let recalledMemories = await learningEngine.recall(for: trimmed, memories: memories, limit: 3)
                if let memoryContext = memoryContextMessage(recalledMemories) {
                    providerMessages.insert(memoryContext, at: 0)
                    for recalled in recalledMemories {
                        memories = await learningEngine.markRecalled(recalled, in: memories)
                    }
                }

                if let profileContext = profileContextMessage() {
                    providerMessages.insert(profileContext, at: 0)
                }
            }

            if let knowledgeBaseContext = knowledgeBaseContextMessage(for: trimmed) {
                providerMessages.insert(knowledgeBaseContext, at: 0)
            }

            let reply = try await provider.response(for: providerMessages)
            messages.append(ChatMessage(role: .assistant, content: reply))

            try await store.save(messages)
            try await learningStore.save(LearningState(memories: memories, profile: learningProfile))
            status = .idle
        } catch {
            status = .error("Unable to get consultant response")
        }
    }

    private func memoryContextMessage(_ recalledMemories: [LearnedMemory]) -> ChatMessage? {
        guard !recalledMemories.isEmpty else { return nil }

        let payload = recalledMemories
            .prefix(3)
            .enumerated()
            .map { index, memory in
                "\(index + 1). \(memory.summary) | keywords: \(memory.keywords.joined(separator: ", "))"
            }
            .joined(separator: "\n")

        return ChatMessage(
            role: .system,
            content: "Use these learned user memories to personalize the response:\n\(payload)"
        )
    }

    private func profileContextMessage() -> ChatMessage? {
        guard !learningProfile.topTopics.isEmpty || !learningProfile.userGoals.isEmpty else {
            return nil
        }

        let topics = learningProfile.topTopics.joined(separator: ", ")
        let goals = learningProfile.userGoals.suffix(3).joined(separator: " | ")
        return ChatMessage(
            role: .system,
            content: "User profile context - top topics: [\(topics)] ; recent goals: [\(goals)]"
        )
    }

    private func knowledgeBaseContextMessage(for text: String) -> ChatMessage? {
        let entries = CompanyKnowledgeBaseCatalog.relevantEntries(for: text)
        guard !entries.isEmpty else {
            return nil
        }

        let payload = entries.map { entry in
            """
            Company: \(entry.name)
            Overview: \(entry.overview)
            Core products: \(entry.products.joined(separator: " | "))
            Common use cases: \(entry.useCases.joined(separator: " | "))
            Key considerations: \(entry.considerations.joined(separator: " | "))
            """
        }
        .joined(separator: "\n\n")

        return ChatMessage(
            role: .system,
            content: "Use this company knowledge base context when it improves the response:\n\(payload)"
        )
    }
}
