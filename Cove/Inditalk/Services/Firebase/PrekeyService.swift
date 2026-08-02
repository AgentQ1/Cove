//
//  PrekeyService.swift
//  Inditalk
//
//  Publishes this device's public prekey bundle to Firestore and fetches peers'
//  bundles so a session can be established asynchronously (the peer may be offline).
//  Establishing the initiator session runs X3DH + starts the Double Ratchet.
//
//  Firestore: users/{uid}/keys/bundle  (public keys only — private keys never leave
//  the device; they live in the Keychain via IdentityKeyManager).
//
//  REQUIRES the FirebaseFirestore SPM package.
//
//  ⚠️ INTEGRATION POINT (responder side): the initiator's first message must also
//  carry the initiator's identity + ephemeral public keys so the responder can run
//  X3DH and build the mirrored ratchet. That envelope extension + one-time-prekey
//  consumption is the remaining work; see docs/PHASE5_ENCRYPTION.md.
//

import Foundation
import CryptoKit
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class PrekeyService {
    static let shared = PrekeyService()
    private let db = Firestore.firestore()
    private var uid: String? { Auth.auth().currentUser?.uid }

    struct PeerBundle {
        let identity: Curve25519.KeyAgreement.PublicKey
        let signedPreKey: Curve25519.KeyAgreement.PublicKey
    }

    enum PrekeyError: Error { case missingBundle }

    /// Upload this device's public prekey bundle. Call once after sign-in.
    func publishLocalBundle() async throws {
        guard let uid else { return }
        let b = IdentityKeyManager.shared.publicBundle()
        try await db.collection("users").document(uid).collection("keys").document("bundle").setData([
            "identityKey": b.identityKey,
            "identitySigningKey": b.identitySigningKey,
            "signedPreKey": b.signedPreKey,
            "signedPreKeySignature": b.signedPreKeySignature,
        ])
    }

    func fetchBundle(uid peerUID: String) async throws -> PeerBundle {
        let doc = try await db.collection("users").document(peerUID)
            .collection("keys").document("bundle").getDocument()
        guard let data = doc.data(),
              let idB64 = data["identityKey"] as? String, let idData = Data(base64Encoded: idB64),
              let spkB64 = data["signedPreKey"] as? String, let spkData = Data(base64Encoded: spkB64),
              let identity = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: idData),
              let spk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: spkData) else {
            throw PrekeyError.missingBundle
        }
        // Production: verify signedPreKeySignature against identitySigningKey before use.
        return PeerBundle(identity: identity, signedPreKey: spk)
    }

    /// Establish the initiator session for a chat: fetch the peer bundle, run X3DH,
    /// start the ratchet, and install it in the session store.
    func establishInitiatorSession(chatID: UUID, peerUID: String) async throws {
        let bundle = try await fetchBundle(uid: peerUID)
        let ratchet = try E2EESession.establishAsInitiator(
            myIdentity: IdentityKeyManager.shared.identityAgreementKey(),
            myEphemeral: Curve25519.KeyAgreement.PrivateKey(),
            peerIdentity: bundle.identity,
            peerSignedPreKey: bundle.signedPreKey)
        E2EESessionStore.shared.install(ratchet, for: chatID)
    }
}
