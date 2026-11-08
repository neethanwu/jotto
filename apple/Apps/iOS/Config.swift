import Foundation
import Observation
import Security

/// Where the backend lives and how to authenticate. The token is a secret,
/// so it lives in the Keychain; the URL is plain UserDefaults.
@MainActor @Observable
final class AppConfig {
    static let shared = AppConfig()

    private static let urlKey = "serverURL"
    private static let tokenAccount = "api-token"

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
    }
    var token: String {
        didSet { Keychain.set(token, account: Self.tokenAccount) }
    }

    var baseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    var isReady: Bool { baseURL != nil && !token.isEmpty }

    /// Transcribe and clean up on this iPhone instead of the server.
    /// Defaults to on when no server is set up.
    var processesLocally: Bool {
        didSet { UserDefaults.standard.set(processesLocally, forKey: Self.localKey) }
    }
    private static let localKey = "processesLocally"

    private init() {
        serverURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        token = Keychain.get(account: Self.tokenAccount) ?? ""
        processesLocally = UserDefaults.standard.object(forKey: Self.localKey) as? Bool
            ?? (UserDefaults.standard.string(forKey: Self.urlKey) ?? "").isEmpty
        #if DEBUG
        // Simulator runs: `SIMCTL_CHILD_JOTTO_SERVER_URL=… xcrun simctl launch …`
        let env = ProcessInfo.processInfo.environment
        // didSet doesn't run in init, so persist explicitly.
        if let url = env["JOTTO_SERVER_URL"] {
            serverURL = url
            UserDefaults.standard.set(url, forKey: Self.urlKey)
        }
        if let token = env["JOTTO_TOKEN"] {
            self.token = token
            Keychain.set(token, account: Self.tokenAccount)
        }
        #endif
    }
}

enum Keychain {
    private static let service = "com.neethanwu.jotto"

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        // Background uploads run while the phone is locked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
