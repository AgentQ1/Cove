//
//  PrivacySettingsTests.swift
//  InditalkTests
//
//  The privacy screen's promises, at the store boundary: a visibility change sticks,
//  and it notifies the sync layer so the backend copy actually changes. A setting that
//  only lives on the device is not a privacy setting.
//

import XCTest
@testable import Inditalk

@MainActor
final class PrivacySettingsTests: XCTestCase {

    func testVisibilityChangeSticks() {
        let store = DataStore.inMemory()
        store.privacy.profilePhoto = .nobody
        XCTAssertEqual(store.privacy.profilePhoto, .nobody)

        // Same path the picker uses: a key path write through the computed property.
        let keyPath = \PrivacySettings.about
        store.privacy[keyPath: keyPath] = .contacts
        XCTAssertEqual(store.privacy.about, .contacts)
    }

    func testVisibilityChangeNotifiesTheSyncLayer() {
        let store = DataStore.inMemory()
        var published: [PrivacySettings.Visibility] = []
        store.privacySink = { published.append($0.profilePhoto) }

        store.privacy.profilePhoto = .nobody
        store.privacy.profilePhoto = .everyone

        XCTAssertEqual(published, [.nobody, .everyone],
                       "each visibility change must reach the backend publisher")
    }

    func testLastSeenAndAboutAlsoPublish() {
        let store = DataStore.inMemory()
        var count = 0
        store.privacySink = { _ in count += 1 }

        store.privacy.lastSeen = .nobody
        store.privacy.about = .contacts

        XCTAssertEqual(count, 2)
    }

    /// Settings that don't change what OTHER people can see are enforced locally and
    /// must not cause a profile republish.
    func testLocalOnlySettingsDoNotPublish() {
        let store = DataStore.inMemory()
        var published = 0
        store.privacySink = { _ in published += 1 }

        store.privacy.readReceipts = false
        store.privacy.defaultDisappearingSeconds = 86_400
        store.block(UUID())

        XCTAssertEqual(published, 0)
    }

    /// Re-selecting the value already in place is a no-op, not a redundant write.
    func testUnchangedVisibilityDoesNotPublish() {
        let store = DataStore.inMemory()
        store.privacy.profilePhoto = .nobody
        var published = 0
        store.privacySink = { _ in published += 1 }

        store.privacy.profilePhoto = .nobody

        XCTAssertEqual(published, 0)
    }

    /// Blocking is what actually stops a blocked contact reaching you: their messages
    /// are dropped on arrival rather than persisted.
    func testBlockedSendersMessagesAreDropped() {
        let store = DataStore.inMemory()
        guard let chat = store.chats.first(where: { $0.kind == .direct }),
              let peer = store.otherParticipant(in: chat) else {
            return XCTFail("expected a seeded direct chat")
        }
        let before = store.messages(in: chat.id).count
        store.block(peer.id)

        store.ingest(remoteMessages: [
            Message(chatID: chat.id, senderID: peer.id, kind: .text,
                    text: "let me in", state: .delivered, isOutgoing: false),
        ], in: chat.id)

        XCTAssertEqual(store.messages(in: chat.id).count, before,
                       "a blocked contact's message must not be persisted")
    }
}
