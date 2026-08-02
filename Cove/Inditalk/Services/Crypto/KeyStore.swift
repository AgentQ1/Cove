//
//  KeyStore.swift
//  Inditalk
//
//  Persists private key material in the iOS Keychain. Identity/session keys never
//  leave the device and are stored with `AfterFirstUnlockThisDeviceOnly` so they are
//  available for background message decryption but are excluded from iCloud/iTunes
//  backups and other devices. See docs/PHASE5_ENCRYPTION.md for the full key model.
//

import Foundation
import Security

struct KeyStore {
    static let shared = KeyStore()
    private let service = "chat.cove.keys"

    enum KeyStoreError: Error { case unexpectedStatus(OSStatus) }

    /// Store (or replace) a secret blob for `account`.
    func save(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // idempotent replace

        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.unexpectedStatus(status) }
    }

    /// Load a previously stored secret, if present.
    func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
