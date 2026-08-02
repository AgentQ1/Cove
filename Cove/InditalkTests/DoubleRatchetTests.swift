//
//  DoubleRatchetTests.swift
//  InditalkTests
//
//  Proves the X3DH + Double Ratchet session: two independent parties derive matching
//  keys, exchange messages across a DH ratchet, and recover out-of-order messages.
//

import XCTest
import CryptoKit
@testable import Inditalk

final class DoubleRatchetTests: XCTestCase {

    /// Build an Alice/Bob session pair from fresh key material.
    private func makeSession() throws -> (alice: DoubleRatchet, bob: DoubleRatchet, chat: UUID) {
        let bobIdentity = Curve25519.KeyAgreement.PrivateKey()
        let bobSPK = Curve25519.KeyAgreement.PrivateKey()
        let aliceIdentity = Curve25519.KeyAgreement.PrivateKey()
        let aliceEph = Curve25519.KeyAgreement.PrivateKey()

        let alice = try E2EESession.establishAsInitiator(
            myIdentity: aliceIdentity, myEphemeral: aliceEph,
            peerIdentity: bobIdentity.publicKey, peerSignedPreKey: bobSPK.publicKey)
        let bob = try E2EESession.establishAsResponder(
            myIdentity: bobIdentity, mySignedPreKey: bobSPK,
            peerIdentity: aliceIdentity.publicKey, peerEphemeral: aliceEph.publicKey)
        return (alice, bob, UUID())
    }

    func testFirstMessageDecrypts() throws {
        let (alice, bob, chat) = try makeSession()
        let wire = try E2EESession.encryptToWire("hello", using: alice, chatID: chat)
        XCTAssertEqual(try E2EESession.decryptFromWire(wire, using: bob, chatID: chat), "hello")
    }

    func testBidirectionalWithDHRatchet() throws {
        let (alice, bob, chat) = try makeSession()
        let a1 = try E2EESession.encryptToWire("from alice", using: alice, chatID: chat)
        XCTAssertEqual(try E2EESession.decryptFromWire(a1, using: bob, chatID: chat), "from alice")
        let b1 = try E2EESession.encryptToWire("from bob", using: bob, chatID: chat)
        XCTAssertEqual(try E2EESession.decryptFromWire(b1, using: alice, chatID: chat), "from bob")
        let a2 = try E2EESession.encryptToWire("alice again", using: alice, chatID: chat)
        XCTAssertEqual(try E2EESession.decryptFromWire(a2, using: bob, chatID: chat), "alice again")
    }

    func testOutOfOrderDelivery() throws {
        let (alice, bob, chat) = try makeSession()
        let w1 = try E2EESession.encryptToWire("one", using: alice, chatID: chat)
        let w2 = try E2EESession.encryptToWire("two", using: alice, chatID: chat)
        let w3 = try E2EESession.encryptToWire("three", using: alice, chatID: chat)
        // Deliver 3, 1, 2 — skipped message keys must recover the gaps.
        XCTAssertEqual(try E2EESession.decryptFromWire(w3, using: bob, chatID: chat), "three")
        XCTAssertEqual(try E2EESession.decryptFromWire(w1, using: bob, chatID: chat), "one")
        XCTAssertEqual(try E2EESession.decryptFromWire(w2, using: bob, chatID: chat), "two")
    }

    func testWireIsNotPlaintextAndUnique() throws {
        let (alice, _, chat) = try makeSession()
        let w1 = try E2EESession.encryptToWire("secret message", using: alice, chatID: chat)
        let w2 = try E2EESession.encryptToWire("secret message", using: alice, chatID: chat)
        XCTAssertFalse(w1.contains("secret"))
        XCTAssertNotEqual(w1, w2, "same plaintext must not produce identical ciphertext")
    }

    func testWrongChatAADFails() throws {
        let (alice, bob, chat) = try makeSession()
        let wire = try E2EESession.encryptToWire("bound to chat", using: alice, chatID: chat)
        // Decrypting under a different chat id → AEAD associated-data mismatch → throws.
        XCTAssertThrowsError(try E2EESession.decryptFromWire(wire, using: bob, chatID: UUID()))
    }
}
