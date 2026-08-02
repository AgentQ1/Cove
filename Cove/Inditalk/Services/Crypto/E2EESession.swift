//
//  E2EESession.swift
//  Inditalk
//
//  Ties X3DH key agreement (CryptoService) to the Double Ratchet: establishes a
//  session from published key material and hands back a ratchet that both devices
//  drive identically. This is the real replacement for MessageCrypto's interim
//  per-chat key — with a session, two devices genuinely derive the same message keys.
//
//  Wire format for a message body stored in Firestore: base64( JSON(RatchetMessage) ).
//

import Foundation
import CryptoKit

enum E2EESession {

    // MARK: Establishment

    /// Initiator side (the party who starts the conversation). Runs X3DH against the
    /// peer's published bundle, then starts the ratchet using the peer's signed prekey
    /// as the initial ratchet key.
    static func establishAsInitiator(
        myIdentity: Curve25519.KeyAgreement.PrivateKey,
        myEphemeral: Curve25519.KeyAgreement.PrivateKey,
        peerIdentity: Curve25519.KeyAgreement.PublicKey,
        peerSignedPreKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> DoubleRatchet {
        let root = try CryptoService.shared.initiatorRootKey(
            identity: myIdentity, ephemeral: myEphemeral,
            theirIdentity: peerIdentity, theirSignedPreKey: peerSignedPreKey)
        return DoubleRatchet(initiatorSharedKey: root, peerRatchetPublic: peerSignedPreKey)
    }

    /// Responder side. Runs X3DH with its own private keys, then starts the ratchet
    /// with its signed-prekey pair as the initial ratchet key.
    static func establishAsResponder(
        myIdentity: Curve25519.KeyAgreement.PrivateKey,
        mySignedPreKey: Curve25519.KeyAgreement.PrivateKey,
        peerIdentity: Curve25519.KeyAgreement.PublicKey,
        peerEphemeral: Curve25519.KeyAgreement.PublicKey
    ) throws -> DoubleRatchet {
        let root = try CryptoService.shared.responderRootKey(
            identity: myIdentity, signedPreKey: mySignedPreKey,
            theirIdentity: peerIdentity, theirEphemeral: peerEphemeral)
        return DoubleRatchet(responderSharedKey: root, ratchetKeyPair: mySignedPreKey)
    }

    // MARK: Wire encoding

    /// Encrypt plaintext through a session and encode it for transport/storage.
    static func encryptToWire(_ text: String, using ratchet: DoubleRatchet, chatID: UUID) throws -> String {
        let message = try ratchet.encrypt(Data(text.utf8), associatedData: aad(chatID))
        return try JSONEncoder().encode(message).base64EncodedString()
    }

    /// Decode a wire string and decrypt it through a session.
    static func decryptFromWire(_ wire: String, using ratchet: DoubleRatchet, chatID: UUID) throws -> String {
        guard let data = Data(base64Encoded: wire) else { throw RatchetError.badKey }
        let message = try JSONDecoder().decode(RatchetMessage.self, from: data)
        let plaintext = try ratchet.decrypt(message, associatedData: aad(chatID))
        return String(decoding: plaintext, as: UTF8.self)
    }

    private static func aad(_ chatID: UUID) -> Data { Data("cove.msg.\(chatID.uuidString)".utf8) }
}
