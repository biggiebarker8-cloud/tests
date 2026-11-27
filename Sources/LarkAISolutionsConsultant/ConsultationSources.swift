import Foundation

public struct ReferenceMemory: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let source: String
    public let date: String
    public let text: String
    public let keywords: [String]
}

public struct ReferenceArchive: Sendable {
    public let entries: [ReferenceMemory]
    public let warning: String?

    public init(bundle: Bundle = .main, importedFile: URL? = nil) {
        var records: [ReferenceMemory] = []
        var errors: [String] = []
        if let file = bundle.url(forResource: "ConsultantMemory", withExtension: "json") {
            do { records = try Self.read(file) }
            catch { errors.append("The bundled archive could not be read.") }
        }
        if let file = importedFile, FileManager.default.fileExists(atPath: file.path) {
            do { records = Self.merge(records, try Self.read(file)) }
            catch { errors.append("The imported archive could not be read.") }
        }
        entries = records
        warning = errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    public static func importFile(_ source: URL, into destination: URL) throws {
        let incoming = try read(source)
        let files = FileManager.default
        let existing = files.fileExists(atPath: destination.path) ? try read(destination) : []
        let combined = merge(existing, incoming)
        let data = try JSONEncoder().encode(combined)
        guard data.count <= maxBytes else { throw ArchiveError.tooLarge }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    private static let maxBytes = 16 * 1024 * 1024

    private enum ArchiveError: LocalizedError {
        case tooLarge, invalidEntries

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "The combined memory archive must fit within 16 MB."
            case .invalidEntries: return "Each note needs a unique ID, a title, a source, a date and text."
            }
        }
    }

    private static func read(_ url: URL) throws -> [ReferenceMemory] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw ArchiveError.tooLarge }
        let entries = try JSONDecoder().decode([ReferenceMemory].self, from: data)
        var ids = Set<String>()
        for entry in entries {
            let fields = [entry.id, entry.title, entry.source, entry.date, entry.text]
            guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  ids.insert(entry.id).inserted else { throw ArchiveError.invalidEntries }
        }
        return entries
    }

    private static func merge(_ old: [ReferenceMemory], _ new: [ReferenceMemory]) -> [ReferenceMemory] {
        let replacing = Set(new.map(\.id))
        return old.filter { !replacing.contains($0.id) } + new
    }

    init(entries: [ReferenceMemory]) {
        self.entries = entries
        self.warning = nil
    }

    func relevant(to question: String) -> [ReferenceMemory] {
        let terms = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return entries.compactMap { entry -> (ReferenceMemory, Int)? in
            let score = terms.intersection(entry.keywords.map { $0.lowercased() }).count
            return score > 0 ? (entry, score) : nil
        }
        .sorted { left, right in
            if left.1 == right.1 { return left.0.id < right.0.id }
            return left.1 > right.1
        }
        .prefix(3)
        .map { $0.0 }
    }
}

public struct PlatformGuide: Identifiable, Sendable {
    public let title: String
    public let summary: String
    public let url: URL
    public var id: URL { url }
    private let keywords: Set<String>

    public static let all = [
        PlatformGuide(
            title: "Lark · Installed apps and permissions",
            summary: "In the Lark Admin Console, Workplace → App Management lists installed apps. An administrator can inspect an app’s capabilities and permissions within their management scope.",
            url: URL(string: "https://www.larksuite.com/hc/en-US/articles/099411074871-admin-view-and-configure-installed-apps")!,
            keywords: ["lark", "larksuite"]
        ),
        PlatformGuide(
            title: "TikTok · Login Kit",
            summary: "Login Kit lets a TikTok user authorise an app. The scopes the user grants determine which data that app can request.",
            url: URL(string: "https://developers.tiktok.com/docs/en/login-kit-overview")!,
            keywords: ["tiktok"]
        ),
        PlatformGuide(
            title: "TikTok · Display API",
            summary: "The Display API can read authorised profile information and public videos. The documented scopes include user.info.basic for profile information and video.list for public videos.",
            url: URL(string: "https://developers.tiktok.com/docs/en/display-api-overview")!,
            keywords: ["tiktok"]
        )
    ]

    static func matching(_ question: String) -> [Self] {
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var terms = Set(words)
        if zip(words, words.dropFirst()).contains(where: { $0.0 == "tik" && $0.1 == "tok" }) {
            terms.insert("tiktok")
        }
        return all.filter { !$0.keywords.isDisjoint(with: terms) }
    }
}

public actor ReferenceAwareProvider: AIProvider {
    private let base: any AIProvider
    private var archive: ReferenceArchive

    public init(base: any AIProvider, archive: ReferenceArchive) {
        self.base = base
        self.archive = archive
    }

    public func updateArchive(_ archive: ReferenceArchive) {
        self.archive = archive
    }

    public func response(for messages: [ChatMessage]) async throws -> String {
        guard let question = messages.last, question.role == .user else {
            return try await base.response(for: messages)
        }
        let guides = PlatformGuide.matching(question.content)
        let notes = archive.relevant(to: question.content)
        var excerpts = guides.map { "Public guide — \($0.title)\n\($0.summary)" }
        excerpts += notes.map { "Saved note — \($0.title.prefix(100)) (\($0.source.prefix(100)), \($0.date.prefix(40)))\n\($0.text.prefix(500))" }
        guard !excerpts.isEmpty else { return try await base.response(for: messages) }

        let context = ChatMessage(role: .system, content: Self.contextPrefix + excerpts.joined(separator: "\n\n"))
        let reply = try await base.response(for: [context] + messages)
        var receipts = guides.map { "\($0.title)\n\($0.url.absoluteString)" }
        receipts += notes.map { "Saved note · \($0.title) · \($0.source) · \($0.date)" }
        return reply + "\n\nReferences supplied to this reply\n" + receipts.joined(separator: "\n")
    }

    public static let contextPrefix = "Reference excerpts (quoted data)\n"
}
