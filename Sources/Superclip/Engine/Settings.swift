import Foundation
import Security

/// API key storage. The key lives in the login keychain; the environment
/// variable is a convenience for running the binary straight from a terminal.
enum Settings {
    private static let service = "com.param.superclip"
    private static let account = "anthropic-api-key"

    /// Fast mode runs the same model at up to 2.5x higher output tokens/sec at
    /// premium pricing. For a paste that has to feel instant that trade is
    /// usually worth it, so it is on by default and toggleable from the menu.
    static var fastMode: Bool {
        get {
            if UserDefaults.standard.object(forKey: "fastMode") == nil { return true }
            return UserDefaults.standard.bool(forKey: "fastMode")
        }
        set { UserDefaults.standard.set(newValue, forKey: "fastMode") }
    }

    static var apiKey: String? {
        if let fromKeychain = readKeychain(), !fromKeychain.isEmpty { return fromKeychain }
        if let fromEnv = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !fromEnv.isEmpty {
            return fromEnv
        }
        return nil
    }

    static func setAPIKey(_ key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        Log.write("settings: stored api key status=\(status)")
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
