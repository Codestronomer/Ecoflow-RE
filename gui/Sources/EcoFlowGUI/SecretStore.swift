// Secret storage — a 0600 file under Application Support.
//
// The Keychain version prompted on every rebuild: the app is ad-hoc signed,
// each build gets a new CDHash, and the Keychain ACL re-prompts (twice —
// once for the read at startup, once for the write after sign-in). For an
// ad-hoc RE tool we trade that friction away: the secret lives in a
// user-readable-only file (0600). A one-time migration imports any
// existing Keychain item and deletes it.

import Foundation

enum SecretStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("EcoFlowGUI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("auth-secret")
    }

    static func load() -> String? {
        // one-time migration from the old Keychain item
        if let legacy = KeychainStore.load() {
            save(legacy)
            KeychainStore.delete()
            return legacy
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: fileURL.path)
        return String(data: data, encoding: .utf8)
    }

    static func save(_ secret: String) {
        let data = Data(secret.utf8)
        try? data.write(to: fileURL, options: [.atomic])
        // owner read/write only
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: fileURL.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// Legacy Keychain access — kept only for the one-time migration above.
import Security

enum KeychainStore {
    private static let service = "com.ecoflow.gui"
    private static let account = "auth-secret"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
