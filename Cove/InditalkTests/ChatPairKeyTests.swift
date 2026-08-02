//
//  ChatPairKeyTests.swift
//  InditalkTests
//
//  Verifies the agreed per-chat key that fixed cross-device decryption: two devices
//  independently derive the SAME key from their identity pair, so a message sealed on
//  one opens on the other — the property the old random per-device chat key lacked
//  (its failure rendered every incoming message as "Unable to decrypt").
//

import XCTest
import CryptoKit
@testable import Inditalk

@MainActor
final class ChatPairKeyTests: XCTestCase {

    func testPairKeyIsSymmetricAcrossDevices() {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let chatID = UUID()

        let aliceKey = ChatPairKey.derive(myPrivate: alice, peerPublic: bob.publicKey, chatID: chatID)
        let bobKey = ChatPairKey.derive(myPrivate: bob, peerPublic: alice.publicKey, chatID: chatID)

        XCTAssertEqual(aliceKey, bobKey, "Both devices must derive the identical chat key")
    }

    func testPairKeyIsBoundToTheChat() {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()

        let chat1 = ChatPairKey.derive(myPrivate: alice, peerPublic: bob.publicKey, chatID: UUID())
        let chat2 = ChatPairKey.derive(myPrivate: alice, peerPublic: bob.publicKey, chatID: UUID())

        XCTAssertNotEqual(chat1, chat2, "Different chats must never share a key")
    }

    func testPairKeyDiffersPerPeer() {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let chatID = UUID()

        let withBob = ChatPairKey.derive(myPrivate: alice,
                                         peerPublic: Curve25519.KeyAgreement.PrivateKey().publicKey,
                                         chatID: chatID)
        let withCarol = ChatPairKey.derive(myPrivate: alice,
                                           peerPublic: Curve25519.KeyAgreement.PrivateKey().publicKey,
                                           chatID: chatID)

        XCTAssertNotEqual(withBob, withCarol)
    }

    /// The end-to-end property behind the bug fix: Alice seals with HER derived key,
    /// Bob opens with HIS — and reads the plaintext.
    func testCrossDeviceEncryptDecryptRoundTrip() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let chatID = UUID()

        let aliceKey = ChatPairKey.derive(myPrivate: alice, peerPublic: bob.publicKey, chatID: chatID)
        let bobKey = ChatPairKey.derive(myPrivate: bob, peerPublic: alice.publicKey, chatID: chatID)

        let wire = try MessageCrypto.shared.encrypt("See you at the cove 🌊", chatID: chatID, key: aliceKey)
        let opened = try MessageCrypto.shared.decrypt(wire, chatID: chatID, key: bobKey)

        XCTAssertEqual(opened, "See you at the cove 🌊")
    }

    /// A key agreed for one chat must not open another chat's ciphertext (the AAD and
    /// the HKDF info both bind the chat id).
    func testKeyFromDifferentChatFailsToDecrypt() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let chatA = UUID(), chatB = UUID()

        let keyA = ChatPairKey.derive(myPrivate: alice, peerPublic: bob.publicKey, chatID: chatA)
        let keyB = ChatPairKey.derive(myPrivate: bob, peerPublic: alice.publicKey, chatID: chatB)

        let wire = try MessageCrypto.shared.encrypt("secret", chatID: chatA, key: keyA)
        XCTAssertThrowsError(try MessageCrypto.shared.decrypt(wire, chatID: chatB, key: keyB))
    }

    /// A stranger (wrong private key) must not be able to derive the pair key.
    func testThirdPartyCannotDeriveTheKey() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let eve = Curve25519.KeyAgreement.PrivateKey()
        let chatID = UUID()

        let pairKey = ChatPairKey.derive(myPrivate: alice, peerPublic: bob.publicKey, chatID: chatID)
        let eveKey = ChatPairKey.derive(myPrivate: eve, peerPublic: bob.publicKey, chatID: chatID)

        XCTAssertNotEqual(pairKey, eveKey)
        let wire = try MessageCrypto.shared.encrypt("secret", chatID: chatID, key: pairKey)
        XCTAssertThrowsError(try MessageCrypto.shared.decrypt(wire, chatID: chatID, key: eveKey))
    }
}
