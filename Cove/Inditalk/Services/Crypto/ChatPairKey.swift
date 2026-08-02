//
//  ChatPairKey.swift
//  Inditalk
//
//  Deterministic per-chat key AGREEMENT for direct chats — the replacement for
//  MessageCrypto's interim random per-device key (which could never decrypt across
//  devices, because each device invented its own).
//
//  Both parties derive the identical key from a static X25519 ECDH between their
//  identity keys:   ECDH(myIdentityPriv, peerIdentityPub) == ECDH(peerIdentityPriv, myIdentityPub)
//  then HKDF-bind it to the chat id. The private key never leaves the Keychain
//  (IdentityKeyManager); the peer's public key comes from their published prekey
//  bundle (users/{uid}/keys/bundle) and is cached locally so decryption works offline.
//
//  Scope: pairwise (direct) chats. Groups need sender-key distribution and still use
//  the interim local key. Forward secrecy comes later with the Double Ratchet
//  (docs/PHASE5_ENCRYPTION.md); this fixes cross-device decryption correctly first.
//

import Foundation
import CryptoKit

@MainActor
final class ChatPairKey {
    static let shared = ChatPairKey()

    private var memo: [UUID: SymmetricKey] = [:]

    enum PairKeyError: Error { case peerIdentityUnavailable }

    /// The agreed symmetric key for a direct chat with `peerUID`. Fetches (and caches)
    /// the peer's identity key on first use; afterwards works fully offline.
    func key(chatID: UUID, peerUID: String) async throws -> SymmetricKey {
        if let cached = memo[chatID] { return cached }
        let peerPublic = try await peerIdentity(uid: peerUID)
        let key = Self.derive(myPrivate: IdentityKeyManager.shared.identityAgreementKey(),
                              peerPublic: peerPublic,
                              chatID: chatID)
        memo[chatID] = key
        return key
    }

    /// Drop cached material (account deletion / sign-out).
    func clearAll() { memo.removeAll() }

    // MARK: Derivation (pure — unit-tested in ChatPairKeyTests)

    /// HKDF(ECDH(a, B)) bound to the chat id. Symmetric in the pair: A deriving with
    /// B's public key equals B deriving with A's public key.
    static func derive(myPrivate: Curve25519.KeyAgreement.PrivateKey,
                       peerPublic: Curve25519.KeyAgreement.PublicKey,
                       chatID: UUID) -> SymmetricKey {
        let shared = try! myPrivate.sharedSecretFromKeyAgreement(with: peerPublic)
        let ikm = shared.withUnsafeBytes { Data($0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data("cove.pairkey.v1".utf8),
            info: Data("chat.\(chatID.uuidString)".utf8),
            outputByteCount: 32)
    }

    // MARK: Peer identity (Keychain-cached, fetched once from the prekey bundle)

    private func peerIdentity(uid: String) async throws -> Curve25519.KeyAgreement.PublicKey {
        let account = "cove.peer.identity.\(uid)"
        if let data = KeyStore.shared.load(account: account),
           let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data) {
            return key
        }
        guard AppConfig.usesFirebase else { throw PairKeyError.peerIdentityUnavailable }
        do {
            let bundle = try await PrekeyService.shared.fetchBundle(uid: uid)
            try? KeyStore.shared.save(bundle.identity.rawRepresentation, account: account)
            print("[Inditalk crypto] cached identity key for peer \(uid)")
            return bundle.identity
        } catch {
            print("[Inditalk crypto] failed to fetch identity bundle for peer \(uid): \(error)")
            throw PairKeyError.peerIdentityUnavailable
        }
    }
}
