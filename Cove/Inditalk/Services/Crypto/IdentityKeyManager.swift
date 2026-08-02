//
//  IdentityKeyManager.swift
//  Inditalk
//
//  Owns the device's long-term key material for E2EE: the identity key (X25519 for
//  agreement + Ed25519 for signing prekeys) and the current signed prekey. Private
//  keys are generated once and stored in the Keychain (never leave the device); the
//  public halves form the prekey bundle published to the server.
//

import Foundation
import CryptoKit

@MainActor
final class IdentityKeyManager {
    static let shared = IdentityKeyManager()
    private let ks = KeyStore.shared

    private let identityAgreeAccount = "cove.identity.agreement"
    private let identitySignAccount  = "cove.identity.signing"
    private let signedPreKeyAccount  = "cove.signedPreKey"

    // MARK: Identity (X25519 agreement)

    func identityAgreementKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let data = ks.load(account: identityAgreeAccount),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try? ks.save(key.rawRepresentation, account: identityAgreeAccount)
        return key
    }

    // MARK: Identity (Ed25519 signing — to sign prekeys)

    func identitySigningKey() -> Curve25519.Signing.PrivateKey {
        if let data = ks.load(account: identitySignAccount),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try? ks.save(key.rawRepresentation, account: identitySignAccount)
        return key
    }

    // MARK: Signed prekey (rotated periodically in production)

    func signedPreKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let data = ks.load(account: signedPreKeyAccount),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try? ks.save(key.rawRepresentation, account: signedPreKeyAccount)
        return key
    }

    // MARK: Published bundle

    /// The public prekey bundle uploaded to the server (base64). `signedPreKeySignature`
    /// lets peers verify the signed prekey really came from this identity.
    struct PublicBundle: Codable {
        let identityKey: String        // b64 X25519 agreement public
        let identitySigningKey: String // b64 Ed25519 public
        let signedPreKey: String       // b64 X25519 agreement public
        let signedPreKeySignature: String // b64 Ed25519 signature over signedPreKey
    }

    func publicBundle() -> PublicBundle {
        let spkPub = signedPreKey().publicKey.rawRepresentation
        let signature = (try? identitySigningKey().signature(for: spkPub)) ?? Data()
        return PublicBundle(
            identityKey: identityAgreementKey().publicKey.rawRepresentation.base64EncodedString(),
            identitySigningKey: identitySigningKey().publicKey.rawRepresentation.base64EncodedString(),
            signedPreKey: spkPub.base64EncodedString(),
            signedPreKeySignature: signature.base64EncodedString())
    }

    /// Delete this device's long-term identity + signed-prekey material from the
    /// Keychain. Used by account deletion so no key survives the account being removed.
    func deleteIdentity() {
        ks.delete(account: identityAgreeAccount)
        ks.delete(account: identitySignAccount)
        ks.delete(account: signedPreKeyAccount)
    }

    /// The 60-digit safety number between us and a peer identity (see SafetyNumberView).
    func safetyNumber(with peerIdentityKey: Data) -> String {
        CryptoService.shared.safetyNumber(
            myIdentity: identityAgreementKey().publicKey.rawRepresentation,
            theirIdentity: peerIdentityKey)
    }
}
