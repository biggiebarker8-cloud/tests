import SwiftUI
import Security
import LarkAISolutionsConsultant

enum PersonalOpenAIKey {
    static let selection = "usePersonalOpenAI"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "PocketConsultant") + ".openai",
         kSecAttrAccount as String: "personal-api-key"]
    }

    static func read() throws -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { throw OpenAIConsultantError.keyUnavailable }
        return key
    }

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let value = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw OpenAIConsultantError.keyUnavailable }
        var item = query.merging(value) { _, new in new }
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw OpenAIConsultantError.keyUnavailable
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAIConsultantError.keyUnavailable
        }
    }
}

struct PersonalChatProvider: AIProvider {
    func response(for messages: [ChatMessage]) async throws -> String {
        if UserDefaults.standard.bool(forKey: PersonalOpenAIKey.selection) {
            return try await OpenAIConsultant(readKey: PersonalOpenAIKey.read).response(for: messages)
        }
        return try await OnDeviceConsultant().response(for: messages)
    }
}

struct OpenAISettings: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var problem: String?
    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Current provider", value: viewModel.providerName)
                Section("Personal OpenAI API key") {
                    SecureField("Enter API key", text: $key)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    Text("Sending a message shares it, recent chat and relevant memory excerpts with OpenAI. Usage is billed to your API project. The key is saved in this device’s Keychain.")
                        .font(.footnote)
                    Button("Save key and use OpenAI") {
                        do {
                            try PersonalOpenAIKey.save(trimmed)
                            finish(useOpenAI: true)
                        } catch { problem = "Couldn’t save your key in Keychain." }
                    }.disabled(trimmed.isEmpty || !trimmed.utf8.allSatisfy { (33...126).contains($0) })
                    if viewModel.usesOpenAI {
                        Button("Remove key and use Apple on device", role: .destructive) {
                            do {
                                try PersonalOpenAIKey.remove()
                                finish(useOpenAI: false)
                            } catch { problem = "Couldn’t remove the key from Keychain." }
                        }
                    }
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("OpenAI settings")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 350)
        #endif
    }

    private func finish(useOpenAI: Bool) {
        key = ""
        viewModel.selectOpenAI(useOpenAI)
        dismiss()
    }
}
