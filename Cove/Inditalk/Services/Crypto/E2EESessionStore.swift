//
//  E2EESessionStore.swift
//  Inditalk
//
//  Holds the established Double Ratchet session for each conversation and exposes
//  encrypt/decrypt over the wire format. Backend-free (CryptoKit only) so it stays
//  verifiable; session establishment (prekey fetch) is done by PrekeyService, which
//  installs the ratchet here.
//
//  NOTE: sessions are currently in-memory. Persisting ratchet state across launches
//  (serializing keys + chain state to the Keychain) is the remaining hardening step;
//  see docs/PHASE5_ENCRYPTION.md.
//

import Foundation

@MainActor
final class E2EESessionStore {
    static let shared = E2EESessionStore()

    private var sessions: [UUID: DoubleRatchet] = [:]

    func hasSession(_ chatID: UUID) -> Bool { sessions[chatID] != nil }
    func install(_ ratchet: DoubleRatchet, for chatID: UUID) { sessions[chatID] = ratchet }
    func clear(_ chatID: UUID) { sessions[chatID] = nil }

    /// Drop every established session (used by account deletion).
    func clearAll() { sessions.removeAll() }

    /// Encrypt through the session. Returns nil when no session exists so callers can
    /// fall back to the interim/local path.
    func sessionEncrypt(_ text: String, chatID: UUID) throws -> String? {
        guard let ratchet = sessions[chatID] else { return nil }
        return try E2EESession.encryptToWire(text, using: ratchet, chatID: chatID)
    }

    /// Decrypt through the session. Returns nil when no session exists.
    func sessionDecrypt(_ wire: String, chatID: UUID) throws -> String? {
        guard let ratchet = sessions[chatID] else { return nil }
        return try E2EESession.decryptFromWire(wire, using: ratchet, chatID: chatID)
    }
}
