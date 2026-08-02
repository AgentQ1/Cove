//
//  CryptoServiceTests.swift
//  InditalkTests
//
//  Verifies the CryptoKit-backed encryption boundary: agreement is symmetric,
//  AEAD round-trips, tampering is detected, and safety numbers are deterministic.
//

import XCTest
import CryptoKit
@testable import Inditalk

final class CryptoServiceTests: XCTestCase {
    let crypto = CryptoService.shared

    func testX3DHAgreementProducesMatchingKeysBothSides() throws {
        // Alice initiates; Bob responds. Bob published an identity key and a signed
        // pre-key; Alice uses her identity key + a fresh ephemeral for the handshake.
        let aliceID = Curve25519.KeyAgreement.PrivateKey()
        let aliceEph = Curve25519.KeyAgreement.PrivateKey()
        let bobID = Curve25519.KeyAgreement.PrivateKey()
        let bobSPK = Curve25519.KeyAgreement.PrivateKey()

        // Alice (initiator) derives using Bob's published public keys.
        let aliceRoot = try crypto.initiatorRootKey(
            identity: aliceID, ephemeral: aliceEph,
            theirIdentity: bobID.publicKey, theirSignedPreKey: bobSPK.publicKey)

        // Bob (responder) derives using Alice's identity + ephemeral public keys.
        let bobRoot = try crypto.responderRootKey(
            identity: bobID, signedPreKey: bobSPK,
            theirIdentity: aliceID.publicKey, theirEphemeral: aliceEph.publicKey)

        // Both sides must land on the identical root key.
        XCTAssertEqual(aliceRoot, bobRoot)
    }

    func testSealOpenRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Meet at the transit center at 11:20".utf8)
        let aad = Data("chat-42".utf8)
        let ct = try crypto.seal(plaintext, key: key, aad: aad)
        let pt = try crypto.open(ct, key: key, aad: aad)
        XCTAssertEqual(pt, plaintext)
        XCTAssertNotEqual(ct, plaintext)
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let key = SymmetricKey(size: .bits256)
        var ct = try crypto.seal(Data("secret".utf8), key: key, aad: Data())
        ct[ct.count - 1] ^= 0xFF   // flip a byte
        XCTAssertThrowsError(try crypto.open(ct, key: key, aad: Data()))
    }

    func testWrongAADFails() throws {
        let key = SymmetricKey(size: .bits256)
        let ct = try crypto.seal(Data("secret".utf8), key: key, aad: Data("a".utf8))
        XCTAssertThrowsError(try crypto.open(ct, key: key, aad: Data("b".utf8)))
    }

    func testSafetyNumberIsSymmetricAndDeterministic() {
        let a = Data("alice-identity".utf8)
        let b = Data("bob-identity".utf8)
        let n1 = crypto.safetyNumber(myIdentity: a, theirIdentity: b)
        let n2 = crypto.safetyNumber(myIdentity: b, theirIdentity: a)   // order swapped
        XCTAssertEqual(n1, n2, "Both participants must see the same safety number")
        XCTAssertEqual(n1, crypto.safetyNumber(myIdentity: a, theirIdentity: b))
        XCTAssertEqual(n1.filter(\.isNumber).count, 60)
    }

    func testSafetyNumberDiffersForDifferentPeers() {
        let me = Data("me".utf8)
        XCTAssertNotEqual(
            crypto.safetyNumber(myIdentity: me, theirIdentity: Data("x".utf8)),
            crypto.safetyNumber(myIdentity: me, theirIdentity: Data("y".utf8)))
    }
}
