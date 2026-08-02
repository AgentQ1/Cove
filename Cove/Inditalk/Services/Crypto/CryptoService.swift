//
//  CryptoService.swift
//  Inditalk
//
//  Real, working cryptographic primitives built on Apple CryptoKit. This is a
//  REFERENCE implementation of Inditalk's end-to-end encryption boundary — it performs
//  genuine X25519 key agreement, HKDF key derivation, and AEAD encryption, and it
//  derives verifiable safety numbers.
//
//  ⚠️ LIMITATIONS (read docs/PHASE5_ENCRYPTION.md):
//  • This wrapper implements the *building blocks* and an X3DH-style handshake, but a
//    full Double Ratchet (per-message forward secrecy + post-compromise security),
//    prekey server infrastructure, and group sender-keys are specified in the design
//    doc and only partially realized here.
//  • CryptoKit intentionally hides raw scalar/nonce handling; a production ratchet
//    needs careful nonce management and a vetted implementation.
//  • NOT PRODUCTION-SECURE. Do not ship until the whole stack is independently audited.
//

import Foundation
import CryptoKit

/// The encryption boundary the app depends on. UI/sync code talks to this protocol,
/// never to CryptoKit directly, so the implementation can be hardened/audited in place.
protocol CryptoProviding {
    /// Generate this device's long-term identity key pair.
    func generateIdentityKey() -> IdentityKeyPair
    /// X3DH-style agreement from the INITIATOR's side (the party who starts the chat).
    func initiatorRootKey(identity: Curve25519.KeyAgreement.PrivateKey,
                          ephemeral: Curve25519.KeyAgreement.PrivateKey,
                          theirIdentity: Curve25519.KeyAgreement.PublicKey,
                          theirSignedPreKey: Curve25519.KeyAgreement.PublicKey) throws -> SymmetricKey
    /// X3DH-style agreement from the RESPONDER's side. Derives the SAME root key as
    /// the initiator — the DH pairs are role-swapped so both sides agree.
    func responderRootKey(identity: Curve25519.KeyAgreement.PrivateKey,
                          signedPreKey: Curve25519.KeyAgreement.PrivateKey,
                          theirIdentity: Curve25519.KeyAgreement.PublicKey,
                          theirEphemeral: Curve25519.KeyAgreement.PublicKey) throws -> SymmetricKey
    /// AEAD-encrypt a plaintext under a message key.
    func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data
    /// AEAD-decrypt.
    func open(_ ciphertext: Data, key: SymmetricKey, aad: Data) throws -> Data
    /// Human-verifiable safety number derived from two identity public keys.
    func safetyNumber(myIdentity: Data, theirIdentity: Data) -> String
}

/// A device identity key pair (X25519 for agreement + Ed25519 for signing prekeys).
struct IdentityKeyPair {
    let agreementPrivate: Curve25519.KeyAgreement.PrivateKey
    let signingPrivate: Curve25519.Signing.PrivateKey

    var agreementPublicData: Data { agreementPrivate.publicKey.rawRepresentation }
    var signingPublicData: Data { signingPrivate.publicKey.rawRepresentation }
}

enum CryptoError: Error { case badKeyMaterial, sealFailed, openFailed }

struct CryptoService: CryptoProviding {

    static let shared = CryptoService()

    // MARK: Identity

    func generateIdentityKey() -> IdentityKeyPair {
        IdentityKeyPair(
            agreementPrivate: Curve25519.KeyAgreement.PrivateKey(),
            signingPrivate: Curve25519.Signing.PrivateKey()
        )
    }

    // MARK: X3DH-style agreement
    //
    // Both sides derive Root = HKDF( DH1 || DH2 || DH3 ) over the SAME three DH values:
    //   DH1 = DH(IK_initiator, SPK_responder)
    //   DH2 = DH(EK_initiator, IK_responder)
    //   DH3 = DH(EK_initiator, SPK_responder)
    // The responder computes the identical set with role-swapped private/public keys.
    // (A production X3DH adds a one-time-prekey DH4; see docs/PHASE5_ENCRYPTION.md.)

    func initiatorRootKey(identity: Curve25519.KeyAgreement.PrivateKey,
                          ephemeral: Curve25519.KeyAgreement.PrivateKey,
                          theirIdentity: Curve25519.KeyAgreement.PublicKey,
                          theirSignedPreKey: Curve25519.KeyAgreement.PublicKey) throws -> SymmetricKey {
        let dh1 = try identity.sharedSecretFromKeyAgreement(with: theirSignedPreKey)
        let dh2 = try ephemeral.sharedSecretFromKeyAgreement(with: theirIdentity)
        let dh3 = try ephemeral.sharedSecretFromKeyAgreement(with: theirSignedPreKey)
        return Self.root(dh1, dh2, dh3)
    }

    func responderRootKey(identity: Curve25519.KeyAgreement.PrivateKey,
                          signedPreKey: Curve25519.KeyAgreement.PrivateKey,
                          theirIdentity: Curve25519.KeyAgreement.PublicKey,
                          theirEphemeral: Curve25519.KeyAgreement.PublicKey) throws -> SymmetricKey {
        // DH1 = DH(SPK_responder, IK_initiator) == DH(IK_initiator, SPK_responder)
        let dh1 = try signedPreKey.sharedSecretFromKeyAgreement(with: theirIdentity)
        // DH2 = DH(IK_responder, EK_initiator) == DH(EK_initiator, IK_responder)
        let dh2 = try identity.sharedSecretFromKeyAgreement(with: theirEphemeral)
        // DH3 = DH(SPK_responder, EK_initiator) == DH(EK_initiator, SPK_responder)
        let dh3 = try signedPreKey.sharedSecretFromKeyAgreement(with: theirEphemeral)
        return Self.root(dh1, dh2, dh3)
    }

    private static func root(_ dhs: SharedSecret...) -> SymmetricKey {
        var ikm = Data()
        for dh in dhs { dh.withUnsafeBytes { ikm.append(contentsOf: $0) } }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data("cove.x3dh.v1".utf8),
            info: Data("root-key".utf8),
            outputByteCount: 32
        )
    }

    // MARK: AEAD (ChaCha20-Poly1305)

    func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad)
        return box.combined
    }

    func open(_ ciphertext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: ciphertext)
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }

    // MARK: Safety number
    //
    // Deterministic, symmetric fingerprint over both identity public keys, rendered
    // as 12 groups of 5 digits (60 digits total) — the same value on both devices.
    func safetyNumber(myIdentity: Data, theirIdentity: Data) -> String {
        let ordered = [myIdentity, theirIdentity].sorted { $0.lexicographicallyPrecedes($1) }
        var hasher = SHA256()
        hasher.update(data: Data("cove.safety.v1".utf8))
        ordered.forEach { hasher.update(data: $0) }
        let digest = Array(hasher.finalize())

        // Map 30 bytes -> 60 decimal digits in blocks of 5.
        var digits = ""
        for byte in digest.prefix(30) {
            digits += String(format: "%02d", Int(byte) % 100)
        }
        return stride(from: 0, to: digits.count, by: 5).map {
            let start = digits.index(digits.startIndex, offsetBy: $0)
            let end = digits.index(start, offsetBy: 5, limitedBy: digits.endIndex) ?? digits.endIndex
            return String(digits[start..<end])
        }.joined(separator: " ")
    }
}

private extension Data {
    func lexicographicallyPrecedes(_ other: Data) -> Bool {
        for (a, b) in zip(self, other) where a != b { return a < b }
        return count < other.count
    }
}
