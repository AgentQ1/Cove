//
//  LiveSyncTests.swift
//  InditalkTests
//
//  Covers the two store seams that make read receipts and reactions live across
//  devices: `markOutgoingRead` (driven by the chats/{chatId}/receipts listener) and
//  `ingest(remoteReactions:)` / `reactionSink` (driven by the reactions listener).
//
//  These are the backend-free halves of the sync path — FirebaseSyncCoordinator maps
//  Firestore snapshots onto exactly these calls, so pinning them here covers the merge
//  rules without touching the network.
//

import XCTest
import CryptoKit
@testable import Inditalk

@MainActor
final class LiveSyncTests: XCTestCase {

    /// A store wired the way the Firebase path wires it: the remote sink is present, so
    /// the local delivery *simulation* is skipped and message state is driven only by
    /// what the tests apply.
    private func syncingStore() -> DataStore {
        let store = DataStore.inMemory()
        store.remoteSink = { _ in }
        return store
    }

    private func emptyChat(_ store: DataStore) -> UUID {
        // A chat with no seeded history, so message ordering is entirely ours.
        let chat = store.visibleChats.first { store.messages(in: $0.id).isEmpty }
        return chat?.id ?? store.visibleChats[0].id
    }

    private func peer(_ store: DataStore) -> InditalkUser {
        store.users.values.first { $0.id != store.currentUser.id }!
    }

    // MARK: Read receipts

    func testReceiptMarksEverythingUpToAndIncludingTheReadMessage() {
        let store = syncingStore()
        let chatID = emptyChat(store)
        let first = store.send(text: "one", to: chatID, replyingTo: nil)
        let second = store.send(text: "two", to: chatID, replyingTo: nil)
        let third = store.send(text: "three", to: chatID, replyingTo: nil)

        store.markOutgoingRead(upTo: second.id, in: chatID)

        let states = Dictionary(uniqueKeysWithValues: store.messages(in: chatID).map { ($0.id, $0.state) })
        XCTAssertEqual(states[first.id], .read)
        XCTAssertEqual(states[second.id], .read)
        // The peer hasn't read the third one — claiming otherwise is the exact lie read
        // receipts exist to avoid.
        XCTAssertNotEqual(states[third.id], .read)
    }

    func testReceiptsNeverRegressAMessageThatWasAlreadyRead() {
        let store = syncingStore()
        let chatID = emptyChat(store)
        let first = store.send(text: "one", to: chatID, replyingTo: nil)
        let second = store.send(text: "two", to: chatID, replyingTo: nil)

        store.markOutgoingRead(upTo: second.id, in: chatID)
        // An older receipt arriving late (out-of-order snapshots are normal) must not
        // walk the second message back to delivered.
        store.markOutgoingRead(upTo: first.id, in: chatID)

        let states = Dictionary(uniqueKeysWithValues: store.messages(in: chatID).map { ($0.id, $0.state) })
        XCTAssertEqual(states[first.id], .read)
        XCTAssertEqual(states[second.id], .read)
    }

    func testReceiptsOnlyTouchOutgoingMessages() {
        let store = syncingStore()
        let chatID = emptyChat(store)
        let sender = peer(store)
        let inbound = Message(chatID: chatID, senderID: sender.id, text: "hello",
                              state: .sent, isOutgoing: false)
        store.ingest(remoteMessages: [inbound], in: chatID)
        let outgoing = store.send(text: "hi back", to: chatID, replyingTo: nil)

        store.markOutgoingRead(upTo: outgoing.id, in: chatID)

        let inboundState = store.messages(in: chatID).first { $0.id == inbound.id }?.state
        // "They read your message" says nothing about messages THEY sent — those carry
        // our own read state, not theirs.
        XCTAssertEqual(inboundState, .sent)
    }

    func testReceiptForAnUnknownMessageIsIgnored() {
        let store = syncingStore()
        let chatID = emptyChat(store)
        let sent = store.send(text: "one", to: chatID, replyingTo: nil)

        // A receipt can reference a message this device hasn't ingested yet; it must not
        // be treated as "everything is read".
        store.markOutgoingRead(upTo: UUID(), in: chatID)

        XCTAssertNotEqual(store.messages(in: chatID).first { $0.id == sent.id }?.state, .read)
    }

    // MARK: Reactions — outgoing (reactionSink)

    func testReactionSinkPublishesAddChangeAndRemoval() {
        let store = syncingStore()
        let chatID = emptyChat(store)
        let message = store.send(text: "look", to: chatID, replyingTo: nil)

        var published: [(UUID, UUID, String?)] = []
        store.reactionSink = { messageID, chat, emoji in published.append((messageID, chat, emoji)) }

        store.addReaction("❤️", to: message.id, in: chatID)      // add
        store.addReaction("😂", to: message.id, in: chatID)      // change
        store.addReaction("😂", to: message.id, in: chatID)      // same emoji again = remove

        XCTAssertEqual(published.map(\.2), ["❤️", "😂", nil])
        XCTAssertEqual(published.map(\.0), [message.id, message.id, message.id])
        XCTAssertEqual(published.map(\.1), [chatID, chatID, chatID])
        // Local state must agree with what was published.
        XCTAssertTrue(store.messages(in: chatID).first { $0.id == message.id }?.reactions.isEmpty ?? false)
    }

    func testReactionsStayLocalWithoutABackend() {
        // Local/preview mode has no sink; reactions must still work exactly as before.
        let store = DataStore.inMemory()
        let chat = store.visibleChats.first { !store.messages(in: $0.id).isEmpty }!
        let message = store.messages(in: chat.id).first!

        store.addReaction("👍", to: message.id, in: chat.id)

        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == message.id }?.reactions.first?.emoji, "👍")
    }

    // MARK: Reactions — incoming (ingest)

    func testIngestAppliesReactionsFromOtherDevices() {
        let store = syncingStore()
        let chatID = emptyChat(store)
        let message = store.send(text: "look", to: chatID, replyingTo: nil)
        let sender = peer(store)

        store.ingest(remoteReactions: [message.id: [Reaction(emoji: "🎉", userID: sender.id)]], in: chatID)

        let reactions = store.messages(in: chatID).first { $0.id == message.id }?.reactions ?? []
        XCTAssertEqual(reactions.count, 1)
        XCTAssertEqual(reactions.first?.emoji, "🎉")
        XCTAssertEqual(reactions.first?.userID, sender.id)
    }

    func testIngestRemovesReactionsTheServerNoLongerHas() {
        let store = syncingStore()
        let chatID = emptyChat(store)
        let message = store.send(text: "look", to: chatID, replyingTo: nil)
        let sender = peer(store)

        store.ingest(remoteReactions: [message.id: [Reaction(emoji: "🎉", userID: sender.id)]], in: chatID)
        // The peer un-reacted on their device: the reaction document is gone, so the
        // snapshot simply no longer mentions this message. That absence IS the removal.
        store.ingest(remoteReactions: [:], in: chatID)

        XCTAssertTrue(store.messages(in: chatID).first { $0.id == message.id }?.reactions.isEmpty ?? false)
    }

    func testIngestKeepsMultipleReactorsOnOneMessage() {
        let store = syncingStore()
        let chatID = emptyChat(store)
        let message = store.send(text: "look", to: chatID, replyingTo: nil)
        let sender = peer(store)

        store.ingest(remoteReactions: [message.id: [
            Reaction(emoji: "🎉", userID: sender.id),
            Reaction(emoji: "❤️", userID: store.currentUser.id),
        ]], in: chatID)

        let emojis = Set((store.messages(in: chatID).first { $0.id == message.id }?.reactions ?? []).map(\.emoji))
        XCTAssertEqual(emojis, ["🎉", "❤️"])
    }

    func testIngestLeavesADeletedMessageWithoutReactions() {
        let store = syncingStore()
        let chatID = emptyChat(store)
        let message = store.send(text: "oops", to: chatID, replyingTo: nil)
        let sender = peer(store)
        store.deleteMessage(message.id, in: chatID)

        // A reaction snapshot that still carries rows for a message deleted for everyone
        // must not resurrect decoration on the tombstone.
        store.ingest(remoteReactions: [message.id: [Reaction(emoji: "🎉", userID: sender.id)]], in: chatID)

        XCTAssertTrue(store.messages(in: chatID).first { $0.id == message.id }?.reactions.isEmpty ?? false)
    }

    // MARK: Reaction encryption

    func testReactionCiphertextCannotBeReplayedAsAMessageBody() throws {
        // Reactions and bodies share the chat key, so the AAD is what stops the server
        // from moving a ciphertext between the two roles.
        let chatID = UUID()
        let key = SymmetricKey(size: .bits256)
        let sealed = try MessageCrypto.shared.encrypt("❤️", chatID: chatID, key: key, purpose: .reaction)

        XCTAssertEqual(try MessageCrypto.shared.decrypt(sealed, chatID: chatID, key: key, purpose: .reaction), "❤️")
        XCTAssertThrowsError(try MessageCrypto.shared.decrypt(sealed, chatID: chatID, key: key, purpose: .body))
    }

    func testMessageBodyAADIsUnchangedSoOlderCiphertextsStillOpen() throws {
        // Introducing `Purpose` must not have altered the AAD used for bodies: every
        // message already stored in Firestore was sealed with "cove.msg.<chatId>", and
        // changing it would make the entire history undecryptable.
        let chatID = UUID()
        let key = SymmetricKey(size: .bits256)
        let sealed = try MessageCrypto.shared.encrypt("hello", chatID: chatID, key: key)

        let legacyAAD = Data("cove.msg.\(chatID.uuidString)".utf8)
        let opened = try CryptoService.shared.open(
            XCTUnwrap(Data(base64Encoded: sealed)), key: key, aad: legacyAAD)
        XCTAssertEqual(String(decoding: opened, as: UTF8.self), "hello")
    }
}
