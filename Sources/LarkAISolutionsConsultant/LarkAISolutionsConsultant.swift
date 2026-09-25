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
        )
    ]

    static func relevantEntries(for text: String) -> [CompanyKnowledgeBaseEntry] {
        let normalized = text.lowercased()
        return entries.filter { $0.matches(normalized) }
    }

    static func shouldIncludeCrossPlatformPlugins(for text: String, matchedEntries: [CompanyKnowledgeBaseEntry]) -> Bool {
        matchedEntries.count > 1
    }

    static func standaloneProjectGuidance(for text: String, matchedEntries: [CompanyKnowledgeBaseEntry]) -> String? {
        let normalized = text.lowercased()
        let standaloneSignals = [
            "standalone",
            "separate",
            "only microsoft",
            "microsoft only",
            "not connected",
            "single microsoft project",
            "one separate microsoft project",
            "strictly to do with microsoft",
            "nothing except microsoft"
        ]
        let names = Set(matchedEntries.map(\.name))
        guard names == ["Microsoft"], standaloneSignals.contains(where: normalized.contains) else {
            return nil
        }

        return "Project scope: Treat this as a standalone Microsoft-only project with no dependencies on unrelated platforms or other projects.\nSolution boundary: Keep recommendations inside the Microsoft ecosystem and avoid assuming cross-project integrations."
    }

    static func crossPlatformPlugins(for entries: [CompanyKnowledgeBaseEntry]) -> [String] {
        var suggestions: [String] = []

        let names = Set(entries.map(\.name))
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
            name: "Core Memory Vault",
            aliases: ["core memory", "memory core", "store knowledge", "store memories", "memory continuity", "memory continuality", "daily memory backup", "memory backup"],
            overview: "Builds persistent memory plans for references, preferences, and reusable knowledge with continuity and backup discipline.",
            workflows: [
                "Capture durable references from prompts and image-driven creative sessions for future reuse",
                "Organize memory into preference, project, and worldbuilding layers with continuity checkpoints",
                "Define daily backup and restore routines for memory resilience and long-term context reliability"
            ],
            outputs: [
                "Core memory schemas for references, insights, and reusable design decisions",
                "Daily memory backup guidance with continuity checkpoints and recovery notes",
                "Knowledge-capture plans that support continual learning from user feedback and accepted outputs"
            ],
            plugins: [
                "Memory vault plug-ins for persistent context capture, indexing, and retrieval",
                "Backup automation connectors for scheduled snapshots and restore workflows",
                "Knowledge graph integrations for cross-project memory linking and continuity tracking"
            ],
            autoActivateOnImageInput: true
        ),
        SkillKnowledgeBaseEntry(
            name: "Story Universe Continuity",
            aliases: ["story lines", "storyline", "story continuity", "characters", "character backstory", "lore", "ip", "universe develop", "worldbuilding"],
            overview: "Manages story universes with recurring characters, lore systems, timeline continuity, and new character/design creation.",
            workflows: [
                "Track storyline arcs, character goals, and backstory dependencies across multi-part narratives",
                "Create new characters, factions, and visual designs that align with established universe rules",
                "Maintain lore canon, IP tone guides, and continuity checks during expansion of each universe"
            ],
            outputs: [
                "Storyline memory maps with arc status, unresolved threads, and continuity anchors",
                "Character dossiers with traits, backstory, relationships, and visual design references",
                "Lore and universe bibles covering world rules, timeline chronology, and IP consistency"
            ],
            plugins: [
                "Character database plug-ins for searchable cast profiles and relationship graphs",
                "Lore management connectors for canon tracking, timeline validation, and revision history",
                "Creative ideation plug-ins for generating new character concepts and universe expansions"
            ],
            autoActivateOnImageInput: true
        ),
        SkillKnowledgeBaseEntry(
            name: "Assistant Personality Styling",
            aliases: ["assistant personality", "blunt and honest", "not mean", "sassy", "sarcastic", "helpful creating ideas", "idea creation"],
            overview: "Shapes response tone to be blunt, honest, sassy, and lightly sarcastic while still constructive, respectful, and idea-focused.",
            workflows: [
                "Set tone guidelines that keep direct feedback clear without becoming rude or dismissive",
                "Blend playful sarcasm with practical steps and actionable idea-development support",
                "Refine brainstorming style to challenge weak ideas and improve stronger concepts quickly"
            ],
            outputs: [
                "Tone profile settings for blunt/honest but not-mean assistant behavior",
                "Idea-generation structures that include critique, alternatives, and next-step recommendations",
                "Style guardrails that preserve respectful language while keeping responses sharp and confident"
            ],
            plugins: [
                "Personality-tuning plug-ins for tone presets, guardrails, and response style controls",
                "Brainstorming connectors for idea scoring, variant generation, and concept iteration",
                "Conversation QA integrations that track helpfulness, clarity, and tone consistency"
            ],
            autoActivateOnImageInput: false
        ),
        SkillKnowledgeBaseEntry(
            name: "Voice and Hearing Interaction",
            aliases: ["voice abilities", "hearing abilities", "voice", "hearing", "speech to text", "text to speech", "audio input", "audio output"],
            overview: "Supports voice-first interaction planning with hearing (speech input), speaking (audio output), and conversational turn management.",
            workflows: [
                "Capture spoken user requests and convert them into structured prompt-ready text",
                "Generate spoken responses with tone control, pacing guidance, and readability checks",
                "Coordinate multimodal sessions that combine voice, text, and visual-reference workflows"
            ],
            outputs: [
                "Voice interaction flows for speech recognition, clarification prompts, and transcript handoff",
                "Audio response guidelines for concise delivery, emphasis, and user-friendly cadence",
                "Accessibility-oriented recommendations for captioning, transcript storage, and replay controls"
            ],
            plugins: [
                "Speech-to-text plug-ins for hearing user input and preserving conversation transcripts",
                "Text-to-speech connectors for natural voice output and persona-aligned delivery",
                "Audio session integrations for microphone handling, playback routing, and transcription logs"
            ],
            autoActivateOnImageInput: false
        ),
        SkillKnowledgeBaseEntry(
            name: "Adaptive Self Learning",
            aliases: ["self learning", "self-learning", "maximum self learning", "adaptive learning", "learn automatically", "learn what you like", "how you like it", "analyze everything"],
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

private struct DomainTemplateEntry: Sendable {
    let name: String
    let aliases: [String]
    let overview: String
    let focusAreas: [String]
    let deliverables: [String]

    func matches(_ text: String) -> Bool {
        containsAlias(in: text, aliases: aliases)
    }
}

private enum DomainTemplateCatalog {
    static let entries: [DomainTemplateEntry] = [
        DomainTemplateEntry(
            name: "Rollout Planning",
            aliases: ["rollout plan", "rollout", "launch plan", "go live", "deployment strategy"],
            overview: "Organize recommendations into a staged rollout plan with readiness checks, ownership, and measurable outcomes.",
            focusAreas: [
                "Define scope, target users, risks, dependencies, and launch sequencing",
                "Break work into phases such as pilot, enablement, launch, and post-launch optimization",
                "Call out stakeholder communication, training, support, and success metrics"
            ],
            deliverables: [
                "Phased rollout plan",
                "Readiness checklist",
                "Risk mitigation actions"
            ]
        ),
        DomainTemplateEntry(
            name: "Architecture Guidance",
            aliases: ["architecture", "technical design", "system design", "solution design"],
            overview: "Frame recommendations as architecture guidance that balances system boundaries, extensibility, and operational tradeoffs.",
            focusAreas: [
                "Identify core components, responsibilities, data flows, and integration points",
                "Explain tradeoffs around scalability, maintainability, observability, and failure handling",
                "Highlight constraints, assumptions, and future extension paths"
            ],
            deliverables: [
                "Component breakdown",
                "Tradeoff summary",
                "Recommended next design decisions"
            ]
        ),
        DomainTemplateEntry(
            name: "Security Governance",
            aliases: ["security governance", "security review", "access control", "compliance", "governance"],
            overview: "Shape recommendations around governance controls, access boundaries, operational safeguards, and auditability.",
            focusAreas: [
                "Cover identity, permissions, data handling, logging, and review workflows",
                "Flag policy, compliance, incident response, and exception-management considerations",
                "Separate preventive controls from monitoring and remediation steps"
            ],
            deliverables: [
                "Control checklist",
                "Governance responsibilities",
                "Monitoring and audit considerations"
            ]
        )
    ]

    static func relevantEntries(for text: String) -> [DomainTemplateEntry] {
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

            let matchedCompanies = CompanyKnowledgeBaseCatalog.relevantEntries(for: trimmed)

            if let skillContext = skillContextMessage(
                for: trimmed,
                imageAttachments: imageAttachments,
                matchedCompanies: matchedCompanies
            ) {
                providerMessages.insert(skillContext, at: 0)
            }

            if let domainTemplateContext = domainTemplateContextMessage(for: trimmed) {
                providerMessages.insert(domainTemplateContext, at: 0)
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

        let standaloneGuidance = CompanyKnowledgeBaseCatalog.standaloneProjectGuidance(for: text, matchedEntries: entries)
            .map { "\n\n\($0)" } ?? ""

        return ChatMessage(
            role: .system,
            content: "Use this company knowledge base context when it improves the response:\n\(payload)\(crossPluginPayload)\(standaloneGuidance)"
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

    private func domainTemplateContextMessage(for text: String) -> ChatMessage? {
        let entries = DomainTemplateCatalog.relevantEntries(for: text)
        guard !entries.isEmpty else {
            return nil
        }

        let payload = entries.map { entry in
            """
            Template: \(entry.name)
            Overview: \(entry.overview)
            Focus areas: \(entry.focusAreas.joined(separator: " | "))
            Suggested deliverables: \(entry.deliverables.joined(separator: " | "))
            """
        }
        .joined(separator: "\n\n")

        return ChatMessage(
            role: .system,
            content: "Use this structured domain template context when it improves the response:\n\(payload)"
        )
    }
}
