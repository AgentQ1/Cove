//
//  MessageCrypto.swift
//  Inditalk
//
//  The encryption boundary between the app and Firestore. Every message body is
//  sealed here (→ base64 ciphertext) before it is written to Firestore, and opened
//  here after it is read back. Firestore therefore never sees plaintext.
//
//  ⚠️ INTERIM KEY MANAGEMENT: this uses a per-chat symmetric key stored locally in the
//  Keychain. That keeps bodies unreadable to the server, but it is NOT full E2EE on
//  its own — for two devices to interoperate, that per-chat key must be AGREED between
//  them via the X3DH handshake + ratchet in docs/PHASE5_ENCRYPTION.md, not generated
//  independently. `chatKey(_:)` is the single seam to replace with the ratchet's
//  message key. Do not treat this as audited/production E2EE.
//

import Foundation
import CryptoKit

struct MessageCrypto {
    static let shared = MessageCrypto()

    private let crypto = CryptoService.shared

    enum CryptoBoundaryError: Error { case badBase64 }

    /// What a ciphertext is FOR. It is bound into the AAD, so a ciphertext minted for
    /// one purpose cannot be replayed by the server as another — e.g. a stored reaction
    /// swapped in as a message body. `.body` keeps the original AAD string, so every
    /// message encrypted before reactions existed still opens.
    enum Purpose: String {
        case body = "msg"
        case reaction = "reaction"
    }

    /// Seal plaintext for a chat → base64 ciphertext safe to store in Firestore.
    func encrypt(_ text: String, chatID: UUID, purpose: Purpose = .body) throws -> String {
        try encrypt(text, chatID: chatID, key: chatKey(chatID), purpose: purpose)
    }

    /// Open base64 ciphertext read from Firestore → plaintext.
    func decrypt(_ base64: String, chatID: UUID, purpose: Purpose = .body) throws -> String {
        try decrypt(base64, chatID: chatID, key: chatKey(chatID), purpose: purpose)
    }

    /// Seal with an explicitly agreed key (ChatPairKey / future ratchet message key)
    /// instead of the interim device-local one.
    func encrypt(_ text: String, chatID: UUID, key: SymmetricKey,
                 purpose: Purpose = .body) throws -> String {
        let sealed = try crypto.seal(Data(text.utf8), key: key, aad: aad(chatID, purpose))
        return sealed.base64EncodedString()
    }

    /// Open with an explicitly agreed key.
    func decrypt(_ base64: String, chatID: UUID, key: SymmetricKey,
                 purpose: Purpose = .body) throws -> String {
        guard let data = Data(base64Encoded: base64) else { throw CryptoBoundaryError.badBase64 }
        let opened = try crypto.open(data, key: key, aad: aad(chatID, purpose))
        return String(decoding: opened, as: UTF8.self)
    }

    // MARK: Key material

    /// Per-chat symmetric key, cached in the Keychain. REPLACE with the ratchet's
    /// per-message key for real cross-device E2EE (see file header).
    private func chatKey(_ chatID: UUID) -> SymmetricKey {
        let account = "cove.chatkey.\(chatID.uuidString)"
        if let existing = KeyStore.shared.load(account: account) {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try? KeyStore.shared.save(raw, account: account)
        return key
    }

    /// Additional authenticated data binds the ciphertext to its chat AND its purpose.
    private func aad(_ chatID: UUID, _ purpose: Purpose) -> Data {
        Data("cove.\(purpose.rawValue).\(chatID.uuidString)".utf8)
    }
}
