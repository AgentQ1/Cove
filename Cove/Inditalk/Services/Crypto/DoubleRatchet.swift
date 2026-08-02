//
//  DoubleRatchet.swift
//  Inditalk
//
//  A working Signal-style Double Ratchet built on Apple CryptoKit. Given a shared
//  root key established by X3DH (CryptoService), two devices derive an identical
//  sequence of per-message keys — providing forward secrecy (symmetric-key ratchet)
//  and post-compromise security (DH ratchet), and tolerating out-of-order delivery
//  (skipped message keys).
//
//  This is the real algorithm, exercised by DoubleRatchetTests + a runnable harness.
//  ⚠️ Still a REFERENCE implementation: it is not constant-time-audited, has no
//  replay/one-time-prekey server enforcement, and its session state is not yet
//  persisted across launches. NOT production-secure until independently audited.
//
//  Reference: Signal's Double Ratchet specification (the algorithm is a public
//  standard; this is an original Swift/CryptoKit implementation, no copied code).
//

import Foundation
import CryptoKit

/// Per-message header sent alongside the ciphertext.
struct RatchetHeader: Codable, Equatable {
    let dhPub: Data      // sender's current ratchet public key (X25519, 32 bytes)
    let pn: Int          // # of messages in the previous sending chain
    let n: Int           // message number in the current sending chain
}

/// The transportable encrypted message (base64-serialized into Firestore's ciphertext).
struct RatchetMessage: Codable, Equatable {
    let header: RatchetHeader
    let ciphertext: Data
}

enum RatchetError: Error { case tooManySkipped, badKey, notInitialized }

final class DoubleRatchet {

    private static let maxSkip = 1000
    private static let info = Data("cove.doubleratchet.v1".utf8)

    // Ratchet state.
    private var dhs: Curve25519.KeyAgreement.PrivateKey        // our current ratchet key pair
    private var dhr: Curve25519.KeyAgreement.PublicKey?        // their current ratchet public key
    private var rk: SymmetricKey                               // root key
    private var cks: SymmetricKey?                             // sending chain key
    private var ckr: SymmetricKey?                             // receiving chain key
    private var ns = 0, nr = 0, pn = 0
    private var skipped: [SkippedKey: SymmetricKey] = [:]

    private struct SkippedKey: Hashable { let dh: Data; let n: Int }

    // MARK: Initialization (post-X3DH)

    /// Initiator (Alice): she has the shared root key and uses the responder's signed
    /// prekey as the initial remote ratchet key.
    init(initiatorSharedKey sk: SymmetricKey, peerRatchetPublic: Curve25519.KeyAgreement.PublicKey) {
        dhs = Curve25519.KeyAgreement.PrivateKey()
        dhr = peerRatchetPublic
        rk = sk
        let dhOut = try! dhs.sharedSecretFromKeyAgreement(with: peerRatchetPublic)
        let (newRK, newCK) = Self.kdfRK(rk: sk, dhOut: dhOut)
        rk = newRK
        cks = newCK
        ckr = nil
    }

    /// Responder (Bob): his signed-prekey key pair IS the initial ratchet key that the
    /// initiator agreed against, so he starts with only the root key.
    init(responderSharedKey sk: SymmetricKey, ratchetKeyPair: Curve25519.KeyAgreement.PrivateKey) {
        dhs = ratchetKeyPair
        dhr = nil
        rk = sk
        cks = nil
        ckr = nil
    }

    // MARK: Encrypt / Decrypt

    func encrypt(_ plaintext: Data, associatedData: Data = Data()) throws -> RatchetMessage {
        guard let sendChain = cks else { throw RatchetError.notInitialized }
        let (nextCK, mk) = Self.kdfCK(sendChain)
        cks = nextCK
        let header = RatchetHeader(dhPub: dhs.publicKey.rawRepresentation, pn: pn, n: ns)
        ns += 1
        let aad = associatedData + Self.headerBytes(header)
        let ct = try ChaChaPoly.seal(plaintext, using: mk, authenticating: aad).combined
        return RatchetMessage(header: header, ciphertext: ct)
    }

    func decrypt(_ message: RatchetMessage, associatedData: Data = Data()) throws -> Data {
        if let pt = try trySkipped(message, ad: associatedData) { return pt }

        let headerPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.header.dhPub)
        if dhr == nil || headerPub.rawRepresentation != dhr!.rawRepresentation {
            try skipMessageKeys(until: message.header.pn)   // finish the old receiving chain
            try dhRatchet(headerPub: headerPub)
        }
        try skipMessageKeys(until: message.header.n)

        guard let recvChain = ckr else { throw RatchetError.notInitialized }
        let (nextCK, mk) = Self.kdfCK(recvChain)
        ckr = nextCK
        nr += 1
        return try open(message, mk: mk, ad: associatedData)
    }

    // MARK: DH ratchet step

    private func dhRatchet(headerPub: Curve25519.KeyAgreement.PublicKey) throws {
        pn = ns
        ns = 0
        nr = 0
        dhr = headerPub
        // Derive the receiving chain from our current DHs and the new remote key…
        let recvDH = try dhs.sharedSecretFromKeyAgreement(with: headerPub)
        let (rk1, ckr1) = Self.kdfRK(rk: rk, dhOut: recvDH)
        rk = rk1; ckr = ckr1
        // …then rotate our own DH key and derive the new sending chain.
        dhs = Curve25519.KeyAgreement.PrivateKey()
        let sendDH = try dhs.sharedSecretFromKeyAgreement(with: headerPub)
        let (rk2, cks1) = Self.kdfRK(rk: rk, dhOut: sendDH)
        rk = rk2; cks = cks1
    }

    // MARK: Skipped-message-key handling (out-of-order delivery)

    private func skipMessageKeys(until: Int) throws {
        guard let chain = ckr, let remote = dhr else { return }
        if nr + Self.maxSkip < until { throw RatchetError.tooManySkipped }
        var cur = chain
        while nr < until {
            let (nextCK, mk) = Self.kdfCK(cur)
            skipped[SkippedKey(dh: remote.rawRepresentation, n: nr)] = mk
            cur = nextCK
            nr += 1
        }
        ckr = cur
    }

    private func trySkipped(_ message: RatchetMessage, ad: Data) throws -> Data? {
        let key = SkippedKey(dh: message.header.dhPub, n: message.header.n)
        guard let mk = skipped[key] else { return nil }
        skipped.removeValue(forKey: key)
        return try open(message, mk: mk, ad: ad)
    }

    private func open(_ message: RatchetMessage, mk: SymmetricKey, ad: Data) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: message.ciphertext)
        return try ChaChaPoly.open(box, using: mk, authenticating: ad + Self.headerBytes(message.header))
    }

    // MARK: KDFs

    /// Root KDF: (RK, dh) -> (RK', CK) via HKDF with the old root key as salt.
    private static func kdfRK(rk: SymmetricKey, dhOut: SharedSecret) -> (SymmetricKey, SymmetricKey) {
        let ikm = dhOut.withUnsafeBytes { Data($0) }
        let salt = rk.withUnsafeBytes { Data($0) }
        let out = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                         salt: salt, info: info, outputByteCount: 64)
        let bytes = out.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }

    /// Chain KDF: CK -> (CK', message key) via two HMACs.
    private static func kdfCK(_ ck: SymmetricKey) -> (SymmetricKey, SymmetricKey) {
        let mk = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: ck)
        let next = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: ck)
        return (SymmetricKey(data: Data(next)), SymmetricKey(data: Data(mk)))
    }

    /// Deterministic header serialization for AEAD associated data.
    private static func headerBytes(_ h: RatchetHeader) -> Data {
        var d = Data(h.dhPub)
        var pn = UInt64(bitPattern: Int64(h.pn)).bigEndian
        var n = UInt64(bitPattern: Int64(h.n)).bigEndian
        withUnsafeBytes(of: &pn) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        return d
    }
}
