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
    let plugins: [String]

    func matches(_ text: String) -> Bool {
        containsAlias(in: text, aliases: aliases)
    }
}

private func containsAlias(in text: String, aliases: [String]) -> Bool {
    aliases.contains { alias in
        let pattern = #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: alias) + #"(?!\w)"#
        return text.range(of: pattern, options: .regularExpression) != nil
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
            ],
            plugins: [
                "TikTok Shop catalog and order sync for social commerce operations",
                "TikTok Ads conversion tracking and campaign audience activation",
                "Creator workflow connectors for briefs, approvals, and content publishing"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "TikTok Agency",
            aliases: ["tiktok agency", "tik tok agency", "tiktok dashboard", "tiktok dashboards", "tt agency"],
            overview: "Agency-focused TikTok operating context for campaign execution, creator programs, storefront growth, and multi-account performance management.",
            products: [
                "TikTok Ads Manager dashboards for campaign, audience, creative, and performance analysis",
                "TikTok Business Center dashboards for account governance, permissions, and partner collaboration",
                "TikTok Shop Seller Center dashboards for product, order, affiliate, and conversion operations",
                "TikTok Creator Marketplace dashboards for creator sourcing, collaboration, and campaign reporting",
                "TikTok Analytics dashboards for content engagement, audience behavior, and retention trends"
            ],
            useCases: [
                "Operating full-funnel TikTok media programs for multiple clients with consistent reporting",
                "Coordinating paid, organic, creator, and commerce motions with shared agency playbooks",
                "Unifying dashboard insights across ads, creators, content, and shop performance"
            ],
            considerations: [
                "Agency workflows should define account ownership, approval chains, and client data boundaries",
                "Dashboard interpretations need consistent KPI definitions across campaign and commerce teams",
                "Performance operations improve when creative testing cadences are synchronized with reporting cycles"
            ],
            plugins: [
                "Agency reporting plug-ins that consolidate Ads Manager, Shop, and creator metrics",
                "Client dashboard connectors for automated exports, scheduled updates, and stakeholder digests",
                "Campaign operations plug-ins for approvals, creative routing, and publishing coordination"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "Microsoft",
            aliases: ["microsoft", "msft", "microsoft 365", "office 365", "m365", "azure", "dynamics", "power platform"],
            overview: "Enterprise ecosystem spanning productivity suites, cloud infrastructure, analytics, CRM/ERP, security, and workflow automation platforms.",
            products: [
                "Microsoft 365 apps including Teams, Outlook, SharePoint, OneDrive, and Office collaboration tools",
                "Azure services for compute, data, AI, identity, security, and integration architecture",
                "Dynamics 365 for CRM, ERP, customer service, sales, and operations management",
                "Power Platform including Power BI dashboards, Power Apps, and Power Automate workflows"
            ],
            useCases: [
                "Building secure enterprise collaboration and document workflows across distributed teams",
                "Running cloud-native data, analytics, and AI initiatives with governance controls",
                "Connecting business operations through CRM/ERP data and low-code automation pipelines"
            ],
            considerations: [
                "Recommendations should account for identity, tenant governance, compliance, and access controls",
                "Architecture choices should align workload requirements across Microsoft 365, Azure, and Dynamics",
                "Dashboard strategies should standardize KPI definitions and data lineage across Power BI and source systems"
            ],
            plugins: [
                "Teams and SharePoint plug-ins for collaboration workflows, approvals, and knowledge routing",
                "Azure integration connectors for event processing, identity-aware APIs, and data pipelines",
                "Power BI dashboard plug-ins for executive reporting, campaign visibility, and operational analytics"
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
            ],
            plugins: [
                "Bots and workflow plug-ins for approvals, notifications, and data routing",
                "Document and calendar integrations for operating cadence automation",
                "Knowledge and service-desk connectors for employee support workflows"
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
            ],
            plugins: [
                "Store, booking, and CRM plug-ins for packaged business operations",
                "Marketing automation connectors for forms, leads, and lifecycle messaging",
                "Custom Velo-based integrations for unique data and workflow requirements"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "Facebook",
            aliases: ["facebook", "meta ads", "facebook ads"],
            overview: "Meta’s social platform and advertising ecosystem used for audience targeting, community engagement, lead generation, and commerce promotion.",
            products: [
                "Facebook Pages, Groups, Shops, and lead generation surfaces",
                "Meta Ads Manager for audience, creative, conversion, and remarketing workflows",
                "Business portfolio, pixel, conversion API, and catalog management capabilities"
            ],
            useCases: [
                "Running paid acquisition, retargeting, and demand generation campaigns",
                "Building communities and lifecycle touchpoints around owned audiences",
                "Supporting social commerce flows through catalogs, ads, and landing experiences"
            ],
            considerations: [
                "Audience strategy, attribution quality, and creative testing strongly influence performance",
                "Catalog, pixel, and conversion API setup should be validated end-to-end",
                "Governance is important for ad accounts, assets, access, and compliance"
            ],
            plugins: [
                "Meta Pixel and Conversion API plug-ins for attribution and optimization",
                "Catalog feed connectors for Shops, dynamic ads, and remarketing",
                "Lead sync plug-ins that route Facebook forms into CRM and automation tools"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "Instagram",
            aliases: ["instagram", "insta"],
            overview: "Visual social platform used for brand storytelling, creator collaboration, engagement, discovery, and commerce activation inside the Meta ecosystem.",
            products: [
                "Feed, Stories, Reels, DMs, creator collaboration, and shopping surfaces",
                "Instagram professional tools connected to Meta ads and reporting workflows",
                "Catalog-driven product discovery and creator-led traffic generation"
            ],
            useCases: [
                "Growing engagement with visual storytelling and creator-led campaigns",
                "Connecting organic content and paid media through shared creative and audience loops",
                "Driving product discovery and social proof for commerce brands"
            ],
            considerations: [
                "Short-form creative testing and creator coordination are usually central to success",
                "Content, commerce, and attribution workflows should be coordinated with the wider Meta stack",
                "Operational planning is needed for moderation, response handling, and creator approvals"
            ],
            plugins: [
                "Product-tag and catalog plug-ins for shoppable content experiences",
                "Scheduling and approval connectors for content calendars and creators",
                "Inbox and social listening plug-ins for community management workflows"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "ByteDance",
            aliases: ["bytedance", "byte dance"],
            overview: "Global technology company known for recommendation systems, creator ecosystems, collaboration software, and large-scale consumer platforms.",
            products: [
                "Consumer products including TikTok and other content discovery platforms",
                "ByteDance creative tooling for short-video production, editing, and creator publishing",
                "AI-assisted video and image generation capabilities for campaign and content workflows",
                "Enterprise collaboration offerings such as Lark for productivity and workflow management",
                "Advertising, creator monetization, and ecosystem services built on recommendation infrastructure"
            ],
            useCases: [
                "Studying product strategy centered on discovery engines, engagement loops, and ecosystem growth",
                "Planning short-video content pipelines with creation, review, distribution, and optimization loops",
                "Designing image and visual asset generation workflows for rapid campaign iteration",
                "Connecting consumer attention platforms with enterprise and monetization opportunities",
                "Benchmarking large-scale operations across content, creators, ads, and collaboration tools"
            ],
            considerations: [
                "Strategies should distinguish consumer platform priorities from enterprise software priorities",
                "Regulatory, trust, safety, and data governance topics often shape deployment decisions",
                "Cross-product narratives work best when grounded in measurable business outcomes"
            ],
            plugins: [
                "Cross-ecosystem connectors that bridge collaboration, creator, and ad operations",
                "Analytics plug-ins that map engagement signals to operating metrics",
                "Video creation and publishing connectors for creator operations and campaign handoff",
                "Image generation and asset-management integrations for design-to-distribution workflows",
                "Workflow integrations for campaign coordination across ByteDance properties"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "Canva",
            aliases: ["canva"],
            overview: "Design platform for creating graphics, presentations, marketing assets, short videos, and collaborative brand content.",
            products: [
                "Templates, brand kits, and design collaboration features for marketing and creative teams",
                "AI-assisted image generation, editing, and copy support for faster content production",
                "Video and animation tooling for short-form social content and campaign assets"
            ],
            useCases: [
                "Producing consistent branded visuals across social, web, and sales collateral",
                "Scaling creative throughput using templates, collaborative review, and reusable brand systems",
                "Connecting image and short-video creation workflows with publishing and campaign operations"
            ],
            considerations: [
                "Brand governance should define template controls, approval checkpoints, and asset ownership",
                "Output formats and dimensions should be aligned to destination channels before production",
                "Cross-tool workflows work best when export, storage, and publishing automations are standardized"
            ],
            plugins: [
                "Brand-kit and template plug-ins for consistent visual identity across teams",
                "Publishing connectors for social scheduling, campaign distribution, and content calendars",
                "Asset storage and review plug-ins for approval routing and handoff workflows"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "AnyCross",
            aliases: ["anycross", "any cross"],
            overview: "Cross-platform automation context for coordinating creative assets, campaign operations, and multi-channel publishing.",
            products: [
                "Cross-platform workflow automation for creative, content, and commerce teams",
                "Connector orchestration for syncing assets, metadata, and campaign status between systems",
                "Operational routing for approvals, task updates, and publishing handoffs"
            ],
            useCases: [
                "Unifying image, comic, and short-video production workflows across multiple tools",
                "Automating asset and campaign synchronization between design, collaboration, and social platforms",
                "Reducing manual coordination with event-driven workflow and approval routing"
            ],
            considerations: [
                "Integration governance should define data ownership, sync precedence, and rollback plans",
                "Workflow reliability depends on clear retry, alerting, and exception-handling patterns",
                "Security controls should be consistent across all connected systems and plug-ins"
            ],
            plugins: [
                "Cross-platform sync plug-ins for creative assets, metadata, and campaign states",
                "Workflow orchestration connectors for approvals, assignments, and publishing pipelines",
                "Monitoring plug-ins for integration health, retries, and operational visibility"
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
            ],
            plugins: [
                "Sales-channel plug-ins for TikTok, Amazon, Facebook, and Instagram commerce sync",
                "Checkout, loyalty, subscriptions, and retention apps for conversion growth",
                "ERP, inventory, and fulfillment connectors for back-office operations"
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
            ],
            plugins: [
                "Marketplace catalog, inventory, and repricing connectors for seller operations",
                "Advertising and attribution plug-ins for retail media optimization",
                "AWS workflow integrations for data, AI, and operational automation"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "Claude AI",
            aliases: ["claude ai", "claude", "anthropic"],
            overview: "AI assistant platform used for drafting, analysis, summarization, support workflows, and agent-style automation.",
            products: [
                "Claude conversational models for writing, reasoning, and analysis tasks",
                "API-based integrations for internal tools, assistants, and workflow automation",
                "Safety-oriented AI deployment patterns for enterprise productivity use cases"
            ],
            useCases: [
                "Embedding AI into support, research, documentation, and operations workflows",
                "Accelerating drafting, summarization, and structured analysis use cases",
                "Powering agent-like assistants that coordinate across internal systems"
            ],
            considerations: [
                "Prompt design, data access boundaries, and evaluation plans should be explicit",
                "Human review and guardrails are important for high-impact or external-facing flows",
                "Adoption depends on connecting AI outputs to repeatable operational workflows"
            ],
            plugins: [
                "Knowledge-base and document retrieval plug-ins for grounded answers",
                "Workflow connectors that move Claude outputs into tickets, docs, and chat tools",
                "Evaluation and monitoring plug-ins for quality, safety, and prompt iteration"
            ]
        ),
        CompanyKnowledgeBaseEntry(
            name: "Munus",
            aliases: ["munus"],
            overview: "Operations-oriented platform context for coordinating service delivery, internal workflows, and business process execution.",
            products: [
                "Workflow, task, and operating process management capabilities",
                "Business operations coordination for service and delivery teams",
                "Integration points for routing updates between operational systems"
            ],
            useCases: [
                "Standardizing recurring operational processes across teams",
                "Coordinating delivery workflows with approvals, updates, and handoffs",
                "Connecting execution data to reporting and operational visibility"
            ],
            considerations: [
                "Process mapping and ownership should be defined before workflow automation expands",
                "Data quality and handoff rules matter when multiple systems are connected",
                "Value is strongest when workflows align to measurable service outcomes"
            ],
            plugins: [
                "Workflow-routing plug-ins for status updates, approvals, and escalations",
                "Reporting connectors that move operational data into dashboards",
                "Task and service integrations for cross-team execution visibility"
            ]
        )
    ]

    static func relevantEntries(for text: String) -> [CompanyKnowledgeBaseEntry] {
        let normalized = text.lowercased()
        return entries.filter { $0.matches(normalized) }
    }

    static func shouldIncludeCrossPlatformPlugins(for text: String, matchedEntries: [CompanyKnowledgeBaseEntry]) -> Bool {
        let normalized = text.lowercased()
        let pluginSignals = ["plugin", "plug-in", "plugins", "integration", "integrations", "connector", "connectors"]
        let crossSignals = ["cross", "cross-platform", "cross platform", "multi-platform", "multi platform"]
        return matchedEntries.count > 1
            || pluginSignals.contains(where: normalized.contains)
            || crossSignals.contains(where: normalized.contains)
    }

    static func crossPlatformPlugins(for entries: [CompanyKnowledgeBaseEntry]) -> [String] {
        var suggestions: [String] = []

        let names = Set(entries.map(\.name))
        if names.contains("TikTok") && names.contains("Shopify") {
            suggestions.append("TikTok Shop + Shopify product, catalog, and order synchronization")
        }
        if names.contains("Facebook") && names.contains("Instagram") {
            suggestions.append("Meta campaign, catalog, and inbox workflow plug-ins shared across Facebook and Instagram")
        }
        if names.contains("Amazon") && names.contains("Shopify") {
            suggestions.append("Amazon marketplace + Shopify inventory, fulfillment, and pricing coordination")
        }
        if names.contains("Lark") && names.contains("Claude AI") {
            suggestions.append("Lark + Claude AI workflow plug-ins for summarization, approvals, and knowledge assistance")
        }
        if names.contains("Wix") && names.contains("Instagram") {
            suggestions.append("Wix + Instagram lead capture and social commerce handoff automations")
        }
        if names.contains("Munus") && names.contains("Lark") {
            suggestions.append("Munus + Lark operational workflow routing for approvals, updates, and task visibility")
        }
        if names.contains("Canva") && names.contains("TikTok") {
            suggestions.append("Canva + TikTok short-video and image asset workflows with brand-safe publishing handoff")
        }
        if names.contains("AnyCross") && names.count > 1 {
            suggestions.append("AnyCross orchestration across matched platforms for asset sync, approval routing, and campaign automation")
        }
        if names.contains("Microsoft") && names.contains("TikTok Agency") {
            suggestions.append("Microsoft Power BI + TikTok Agency dashboards for unified client reporting, campaign insights, and operational scorecards")
        }
        if names.contains("Microsoft") && names.contains("TikTok") {
            suggestions.append("Microsoft collaboration and analytics plug-ins for TikTok campaign planning, execution, and performance reporting")
        }

        if suggestions.isEmpty, names.count > 1 {
            suggestions.append("Use API, event, and workflow plug-ins that keep data ownership clear across the matched platforms")
            suggestions.append("Prioritize cross-platform connectors for identity, content sync, conversion tracking, and operational handoffs")
        }

        return suggestions
    }
}

private struct SkillKnowledgeBaseEntry: Sendable {
    let name: String
    let aliases: [String]
    let overview: String
    let workflows: [String]
    let outputs: [String]
    let plugins: [String]
    let autoActivateOnImageInput: Bool

    func matches(_ text: String, hasImageAttachments: Bool) -> Bool {
        containsAlias(in: text, aliases: aliases) || (autoActivateOnImageInput && hasImageAttachments)
    }
}

private enum SkillKnowledgeBaseCatalog {
    static let entries: [SkillKnowledgeBaseEntry] = [
        SkillKnowledgeBaseEntry(
            name: "Image Creation",
            aliases: ["image creation", "create image", "generate image", "make image", "illustration", "picture design", "picture generation", "visual design"],
            overview: "Creates net-new visual concepts, marketing graphics, scenes, and styled artwork from prompts or briefs.",
            workflows: [
                "Turn product, campaign, or story briefs into structured visual directions",
                "Generate multiple creative routes with style, framing, and tone variations",
                "Prepare prompt iterations for ads, editorial art, or branded visuals"
            ],
            outputs: [
                "Concept art briefs, scene prompts, character prompts, and campaign image directions",
                "Variant suggestions for aspect ratio, tone, composition, and art style",
                "Production notes for review, revision, and approval workflows"
            ],
            plugins: [
                "Image generation plug-ins connected to campaign, content, and asset workflows",
                "Brand-kit plug-ins that preserve style, palette, and composition guidance",
                "Asset routing connectors for approvals, publishing, and DAM storage"
            ],
            autoActivateOnImageInput: false
        ),
        SkillKnowledgeBaseEntry(
            name: "Image Editing",
            aliases: ["image editing", "edit image", "retouch", "enhance image", "background removal"],
            overview: "Edits existing images for cleanup, recomposition, annotation, styling, resizing, and iterative refinement.",
            workflows: [
                "Use attached images as source material for revision, annotation, or transformation",
                "Plan edit passes for cleanup, crops, overlays, or style adjustments",
                "Translate feedback into concrete edit goals and approval-ready revisions"
            ],
            outputs: [
                "Edit instructions, revision goals, before/after checkpoints, and QA criteria",
                "Recommendations for crops, overlays, text placement, and visual hierarchy",
                "Iteration notes for asset handoff, approvals, and publishing"
            ],
            plugins: [
                "Image editing plug-ins for crops, retouching, inpainting, and annotation",
                "Review and approval connectors for creative feedback loops",
                "Asset versioning integrations for teams managing multiple revisions"
            ],
            autoActivateOnImageInput: true
        ),
        SkillKnowledgeBaseEntry(
            name: "Comic Book Creation",
            aliases: ["comic book", "comic", "comic creation", "graphic novel", "storyboard", "manga"],
            overview: "Builds comic-style narratives with panel planning, characters, scene continuity, and visual storytelling structure.",
            workflows: [
                "Break stories into pages, scenes, and panels with pacing guidance",
                "Define recurring characters, settings, style references, and dialogue intent",
                "Coordinate illustration, lettering, and revision loops across a full comic workflow"
            ],
            outputs: [
                "Page-by-page outlines, panel prompts, character sheets, and scene directions",
                "Tone, pacing, and continuity guidance for longer-form visual storytelling",
                "Production checklists for lettering, layouts, revisions, and export readiness"
            ],
            plugins: [
                "Storyboard and layout plug-ins for page planning and panel sequencing",
                "Character consistency connectors for recurring cast and world-building assets",
                "Publishing workflows for asset review, lettering, and export handoff"
            ],
            autoActivateOnImageInput: false
        ),
        SkillKnowledgeBaseEntry(
            name: "Picture Design",
            aliases: ["picture design", "photo design", "poster design", "graphic design", "flyer design", "social design"],
            overview: "Designs polished pictures for ads, social posts, campaign collateral, and brand storytelling across channels.",
            workflows: [
                "Translate briefs into picture concepts with layout, typography, color, and hierarchy direction",
                "Adapt visuals for multiple sizes, channels, and placements while preserving brand consistency",
                "Plan review and iteration loops for copy placement, CTA clarity, and conversion-focused design"
            ],
            outputs: [
                "Picture design concepts, style routes, and channel-specific layout recommendations",
                "Export checklists covering dimensions, formats, and accessibility-oriented readability",
                "Revision notes for design QA, stakeholder approvals, and publishing handoff"
            ],
            plugins: [
                "Picture design plug-ins for templates, typography systems, and brand-safe composition",
                "Channel-resize connectors for multi-platform output generation and packaging",
                "Creative review plug-ins for annotation, approvals, and version governance"
            ],
            autoActivateOnImageInput: false
        ),
        SkillKnowledgeBaseEntry(
            name: "Short Video Creation",
            aliases: ["short video", "short videos", "video creation", "video generation", "reels", "tiktok video", "clip creation"],
            overview: "Creates short-form videos with scripting, shot planning, editing direction, and publishing-ready recommendations.",
            workflows: [
                "Convert campaign goals into short-video concepts, hooks, and storyboard sequences",
                "Plan script beats, visual pacing, captions, and CTA placement for high-retention formats",
                "Coordinate edit, review, and publishing handoffs across creative and distribution teams"
            ],
            outputs: [
                "Short-video concepts, script drafts, shot lists, and pacing recommendations",
                "Editing guidance for transitions, overlays, captions, and soundtrack direction",
                "Publishing checklists for platform formats, metadata, and test-and-learn iteration loops"
            ],
            plugins: [
                "Short-video editing plug-ins for sequencing, captioning, and rapid iteration workflows",
                "Publishing connectors for social distribution, scheduling, and performance tracking",
                "Asset-sync plug-ins for linking scripts, footage, approvals, and final exports"
            ],
            autoActivateOnImageInput: false
        ),
        SkillKnowledgeBaseEntry(
            name: "Website Building",
            aliases: ["website building", "build website", "website builder", "web builder", "web design", "multiple website building capabilities"],
            overview: "Designs and organizes website-building workflows across landing pages, commerce pages, content hubs, and multi-page site structures.",
            workflows: [
                "Translate business goals into site architecture, navigation patterns, and conversion pathways",
                "Plan reusable templates and component systems for multiple websites or campaigns",
                "Coordinate build, QA, publishing, and iteration workflows across web and content teams"
            ],
            outputs: [
                "Website blueprints, page maps, section-level content briefs, and conversion-focused layout guidance",
                "Multi-site rollout checklists for branding, SEO readiness, and launch sequencing",
                "Builder-compatible implementation guidance for forms, CMS content, analytics tags, and integrations"
            ],
            plugins: [
                "Website builder plug-ins for CMS blocks, forms, SEO configuration, and template systems",
                "Publishing connectors for staged rollouts, content approvals, and release coordination",
                "Analytics and optimization integrations for funnel visibility and iteration planning"
            ],
            autoActivateOnImageInput: false
        ),
        SkillKnowledgeBaseEntry(
            name: "Website Permissions Management",
            aliases: ["website permissions", "all permissions", "permission management", "access control", "permissions except payments", "administrative charges"],
            overview: "Defines website-role permission bundles for content and operations while excluding payment and administrative charge privileges.",
            workflows: [
                "Set role-based access for editing, publishing, media, SEO, analytics, and integrations",
                "Grant broad website permissions with explicit restrictions on payment and billing authority",
                "Audit permission scope to keep collaboration fast while preserving sensitive financial controls"
            ],
            outputs: [
                "Permission matrix templates for editors, marketers, designers, analysts, and support teams",
                "Allowed permissions: page editing, media upload, content publishing, SEO settings, analytics viewing, integration configuration",
                "Excluded permissions: payment processing, refunds, payout controls, and administrative charges"
            ],
            plugins: [
                "Role-based access plug-ins for workflow approvals and publish controls",
                "Audit-log connectors for tracking permission changes and operational accountability",
                "Compliance integrations for least-privilege access and policy enforcement"
            ],
            autoActivateOnImageInput: false
        ),
        SkillKnowledgeBaseEntry(
            name: "Adaptive Self Learning",
            aliases: ["self learning", "self-learning", "maximum self learning", "adaptive learning", "learn automatically"],
            overview: "Strengthens personalization by reusing learned preferences, recurring goals, and prior context to improve future responses.",
            workflows: [
                "Reinforce repeated user themes and preferred solution patterns over time",
                "Adapt skill and plug-in suggestions using prior conversations and recent goals",
                "Promote durable knowledge that sharpens future recommendations"
            ],
            outputs: [
                "Persistent memory summaries, updated topic trends, and evolving user goals",
                "Recommendations that reflect prior workflows, priorities, and recurring requests",
                "Context carryover that improves follow-up prompts and multi-turn planning"
            ],
            plugins: [
                "Memory and retrieval plug-ins for durable recall across sessions",
                "Feedback connectors that reinforce accepted workflows and revisions",
                "Analytics integrations that expose learning trends and adoption patterns"
            ],
            autoActivateOnImageInput: false
        ),
        SkillKnowledgeBaseEntry(
            name: "Plug-in and Skill Automation",
            aliases: ["auto add plug-ins", "auto-add plug-ins", "auto add plugins", "auto-add plugins", "auto add skills", "auto-add skills", "skills automation"],
            overview: "Automatically recommends relevant plug-ins and skills based on prompt intent, matched platforms, and available image inputs.",
            workflows: [
                "Detect platform and creative intent to preselect useful plug-ins and skills",
                "Bundle image, workflow, and platform capabilities into one guided response",
                "Suggest cross-platform automations when multiple systems are involved"
            ],
            outputs: [
                "Auto-selected skill lists tailored to the request",
                "Auto-selected plug-in suggestions aligned to platforms and media workflows",
                "Guidance for orchestration between creative tools, collaboration tools, and commerce platforms"
            ],
            plugins: [
                "Intent-routing plug-ins that map prompts to the right capabilities",
                "Workflow orchestration connectors that chain skills across multiple steps",
                "Cross-platform automation plug-ins for syncing creative, content, and operational tasks"
            ],
            autoActivateOnImageInput: false
        )
    ]

    static func relevantEntries(for text: String, imageAttachments: [ChatImageAttachment]) -> [SkillKnowledgeBaseEntry] {
        let normalized = text.lowercased()
        let hasImageAttachments = !imageAttachments.isEmpty
        return entries.filter { $0.matches(normalized, hasImageAttachments: hasImageAttachments) }
    }

    static func autoSelectedSkillNames(for entries: [SkillKnowledgeBaseEntry], imageAttachments: [ChatImageAttachment]) -> [String] {
        var skills = entries.map(\.name)
        if !imageAttachments.isEmpty && !skills.contains("Multimodal Image Input") {
            skills.append("Multimodal Image Input")
        }
        return Array(NSOrderedSet(array: skills)) as? [String] ?? skills
    }

    static func autoSelectedPlugins(
        for skillEntries: [SkillKnowledgeBaseEntry],
        matchedCompanies: [CompanyKnowledgeBaseEntry]
    ) -> [String] {
        let plugins = skillEntries.flatMap(\.plugins) + matchedCompanies.flatMap(\.plugins)
        return Array(NSOrderedSet(array: plugins.prefix(8).map { $0 })) as? [String] ?? Array(plugins.prefix(8))
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

            let matchedCompanies = CompanyKnowledgeBaseCatalog.relevantEntries(for: trimmed)

            if let skillContext = skillContextMessage(
                for: trimmed,
                imageAttachments: imageAttachments,
                matchedCompanies: matchedCompanies
            ) {
                providerMessages.insert(skillContext, at: 0)
            }

            if let knowledgeBaseContext = knowledgeBaseContextMessage(for: trimmed, matchedEntries: matchedCompanies) {
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

    private func knowledgeBaseContextMessage(for text: String, matchedEntries: [CompanyKnowledgeBaseEntry]? = nil) -> ChatMessage? {
        let entries = matchedEntries ?? CompanyKnowledgeBaseCatalog.relevantEntries(for: text)
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
            Recommended plug-ins: \(entry.plugins.joined(separator: " | "))
            """
        }
        .joined(separator: "\n\n")

        let crossPluginPayload: String
        if CompanyKnowledgeBaseCatalog.shouldIncludeCrossPlatformPlugins(for: text, matchedEntries: entries) {
            let suggestions = CompanyKnowledgeBaseCatalog.crossPlatformPlugins(for: entries)
            crossPluginPayload = suggestions.isEmpty
                ? ""
                : "\n\nCross-platform plug-in ideas: \(suggestions.joined(separator: " | "))"
        } else {
            crossPluginPayload = ""
        }

        return ChatMessage(
            role: .system,
            content: "Use this company knowledge base context when it improves the response:\n\(payload)\(crossPluginPayload)"
        )
    }

    private func skillContextMessage(
        for text: String,
        imageAttachments: [ChatImageAttachment],
        matchedCompanies: [CompanyKnowledgeBaseEntry]
    ) -> ChatMessage? {
        let entries = SkillKnowledgeBaseCatalog.relevantEntries(for: text, imageAttachments: imageAttachments)
        guard !entries.isEmpty else {
            return nil
        }

        let payload = entries.map { entry in
            """
            Skill: \(entry.name)
            Overview: \(entry.overview)
            Common workflows: \(entry.workflows.joined(separator: " | "))
            Typical outputs: \(entry.outputs.joined(separator: " | "))
            Recommended plug-ins: \(entry.plugins.joined(separator: " | "))
            """
        }
        .joined(separator: "\n\n")

        let autoSkills = SkillKnowledgeBaseCatalog.autoSelectedSkillNames(for: entries, imageAttachments: imageAttachments)
        let autoPlugins = SkillKnowledgeBaseCatalog.autoSelectedPlugins(for: entries, matchedCompanies: matchedCompanies)

        var automationContext: [String] = []
        if !autoSkills.isEmpty {
            automationContext.append("Auto-selected skills: \(autoSkills.joined(separator: " | "))")
        }
        if !autoPlugins.isEmpty {
            automationContext.append("Auto-selected plug-ins: \(autoPlugins.joined(separator: " | "))")
        }

        let automationPayload = automationContext.isEmpty ? "" : "\n\n" + automationContext.joined(separator: "\n")

        return ChatMessage(
            role: .system,
            content: "Use this skill context when it improves the response:\n\(payload)\(automationPayload)"
        )
    }
}
