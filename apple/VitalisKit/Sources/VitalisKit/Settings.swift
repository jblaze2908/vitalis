import Foundation
import Security

public struct ServerSettings: Sendable {
    public let baseURL: URL
    public init(_ text: String) throws {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil, let url = components.url else {
            throw SettingsError.invalidURL
        }
        baseURL = url
    }
    public enum SettingsError: LocalizedError {
        case invalidURL
        public var errorDescription: String? { "Enter an http(s) server URL without credentials, query, or fragment." }
    }
}

public enum TokenStore {
    public struct KeychainError: LocalizedError {
        let status: OSStatus
        public var errorDescription: String? { "Keychain error \(status). Unlock the phone and try again." }
    }
    private static var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Vitalis.API", kSecAttrAccount as String: "write-token"]
    }
    public static func read() throws -> String? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(key as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = key
            for (name, value) in attributes { item[name] = value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
}

@MainActor
public enum SettingsStore {
    public static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "serverBaseURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serverBaseURL") }
    }
    public static var installID: String {
        if let existing = UserDefaults.standard.string(forKey: "installID") { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "installID")
        return id
    }
}
