//
//  DataStoreFeatureTests.swift
//  InditalkTests
//
//  Covers the newer DataStore surface: favorites, contact creation with
//  normalized-phone dedupe, status updates (24h expiry projections), scheduled
//  calls, group membership mutations, the default-disappearing-timer inheritance,
//  the read-receipts-off delivery lifecycle, and avatar updates.
//

import XCTest
@testable import Inditalk

@MainActor
final class DataStoreFeatureTests: XCTestCase {

    // MARK: Helpers

    /// Any seeded user other than the local user.
    private func someoneElse(_ store: DataStore) -> InditalkUser {
        store.users.values.first { $0.id != store.currentUser.id }!
    }

    private func seededGroupChat(_ store: DataStore) -> Chat? {
        store.chats.first { $0.kind == .group }
    }

    /// Poll on the main actor until `condition` holds or `timeout` elapses.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: Favorites

    func testToggleFavoriteSetsFlagAndAppearsInFavorites() {
        let store = DataStore.inMemory()
        let target = someoneElse(store)
        XCTAssertFalse(store.favoriteUsers.contains { $0.id == target.id })

        store.toggleFavorite(target.id)
        XCTAssertTrue(store.users[target.id]?.isFavorite ?? false)
        XCTAssertTrue(store.favoriteUsers.contains { $0.id == target.id })
    }

    func testUntoggleFavoriteRemoves() {
        let store = DataStore.inMemory()
        let target = someoneElse(store)
        store.toggleFavorite(target.id)
        store.toggleFavorite(target.id)
        XCTAssertFalse(store.users[target.id]?.isFavorite ?? true)
        XCTAssertFalse(store.favoriteUsers.contains { $0.id == target.id })
    }

    func testFavoriteUsersSortedByDisplayName() {
        let store = DataStore.inMemory()
        let others = store.users.values.filter { $0.id != store.currentUser.id }.prefix(3)
        for user in others { store.toggleFavorite(user.id) }

        let names = store.favoriteUsers.map(\.displayName)
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(
            names,
            names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        )
    }

    // MARK: Contacts

    func testAddContactCreatesUser() {
        let store = DataStore.inMemory()
        let before = store.users.count
        let contact = store.addContact(name: "Priya", phone: "+1 (415) 555-0177")
        XCTAssertEqual(store.users.count, before + 1)
        XCTAssertEqual(store.users[contact.id]?.displayName, "Priya")
        XCTAssertEqual(store.users[contact.id]?.phoneNumber, "+1 (415) 555-0177")
    }

    func testAddContactDedupesByNormalizedPhone() {
        let store = DataStore.inMemory()
        let first = store.addContact(name: "Priya", phone: "+1 (415) 555-0177")
        let before = store.users.count

        // Same line, different formatting (bare digits with country code).
        let second = store.addContact(name: "Priya Again", phone: "14155550177")
        XCTAssertEqual(second.id, first.id, "same normalized phone must return the original user")
        XCTAssertEqual(store.users.count, before, "no duplicate user row")
        XCTAssertEqual(store.users[first.id]?.displayName, "Priya", "original name kept")
    }

    func testAddContactMatchingSeededUserReturnsExisting() {
        let store = DataStore.inMemory()
        // The local user is seeded with "+1 (415) 555-0102"; digits-only must dedupe.
        let before = store.users.count
        let result = store.addContact(name: "Duplicate Me", phone: "14155550102")
        XCTAssertEqual(result.id, store.currentUser.id)
        XCTAssertEqual(store.users.count, before)
    }

    func testAddContactBlankNameFallsBackToPhone() {
        let store = DataStore.inMemory()
        let contact = store.addContact(name: "   ", phone: "+1 (415) 555-0166")
        XCTAssertEqual(contact.displayName, "+1 (415) 555-0166")
    }

    func testUserWithPhoneMatchesAcrossFormats() {
        let store = DataStore.inMemory()
        store.addContact(name: "Priya", phone: "+1 (415) 555-0177")

        XCTAssertNotNil(store.user(withPhone: "(415) 555-0177"))
        XCTAssertNotNil(store.user(withPhone: "1-415-555-0177"))
        XCTAssertNil(store.user(withPhone: "+1 (415) 555-0299"))
        XCTAssertNil(store.user(withPhone: ""), "empty phone never matches")
    }

    // MARK: Status updates

    func testPostStatusAppearsInMyActiveStatuses() {
        let store = DataStore.inMemory()
        XCTAssertTrue(store.myActiveStatuses.isEmpty, "seed posts no statuses for the local user")

        let posted = store.postStatus(kind: .text, text: "Hello from tests", localName: nil, paletteIndex: 1)
        XCTAssertEqual(store.myActiveStatuses.map(\.id), [posted.id])
        XCTAssertEqual(posted.userID, store.currentUser.id)
        // Expires ~24h out.
        XCTAssertGreaterThan(posted.expiresAt, Date().addingTimeInterval(23 * 3_600))
        XCTAssertFalse(posted.isExpired)
    }

    func testStatusExpiryExcludesPastExpiresAt() {
        // postStatus always stamps a fresh 24h expiry, so expiry is exercised at the
        // model level — the projections (`myActiveStatuses` / `othersActiveStatuses`)
        // filter on this same `isExpired` flag.
        let expired = StatusUpdate(userID: UUID(), text: "old",
                                   createdAt: Date().addingTimeInterval(-90_000),
                                   expiresAt: Date().addingTimeInterval(-3_600))
        XCTAssertTrue(expired.isExpired)

        let active = StatusUpdate(userID: UUID(), text: "new")
        XCTAssertFalse(active.isExpired)
    }

    func testOthersActiveStatusesExcludesMeAndSortsFreshestAuthorFirst() {
        let store = DataStore.inMemory()
        store.postStatus(kind: .text, text: "mine", localName: nil, paletteIndex: 0)

        let others = store.othersActiveStatuses
        XCTAssertFalse(others.isEmpty, "seed ships statuses from contacts")
        XCTAssertFalse(others.contains { $0.user.id == store.currentUser.id })

        // Authors ordered by their freshest update, newest first.
        let freshest = others.map { $0.updates.last?.createdAt ?? .distantPast }
        XCTAssertEqual(freshest, freshest.sorted(by: >))

        // Within an author, updates are oldest first.
        for entry in others {
            let dates = entry.updates.map(\.createdAt)
            XCTAssertEqual(dates, dates.sorted())
        }
    }

    func testMarkStatusViewedFlips() {
        let store = DataStore.inMemory()
        guard let target = store.othersActiveStatuses.first?.updates.first else {
            return XCTFail("expected a seeded contact status")
        }
        XCTAssertFalse(target.isViewed)

        store.markStatusViewed(target.id)
        let updated = store.othersActiveStatuses
            .flatMap(\.updates)
            .first { $0.id == target.id }
        XCTAssertEqual(updated?.isViewed, true)
    }

    func testMarkStatusViewedPublishesReceiptEvenWhenAlreadySeen() {
        let store = DataStore.inMemory()
        guard let target = store.othersActiveStatuses.first?.updates.first else {
            return XCTFail("expected a seeded contact status")
        }
        var published: [UUID] = []
        store.statusViewedSink = { published.append($0.id) }

        store.markStatusViewed(target.id)
        // Re-opening a status must re-publish: that's how a receipt lost to an offline
        // write gets retried.
        store.markStatusViewed(target.id)
        XCTAssertEqual(published, [target.id, target.id])
    }

    func testMarkStatusViewedDoesNotPublishForOwnStatus() {
        let store = DataStore.inMemory()
        let mine = store.postStatus(kind: .text, text: "mine", localName: nil, paletteIndex: 0)
        var published: [UUID] = []
        store.statusViewedSink = { published.append($0.id) }

        store.markStatusViewed(mine.id)
        XCTAssertTrue(published.isEmpty, "you never appear in your own seen-by list")
    }

    func testStatusViewersSortNewestFirstAndClearOnDelete() {
        let store = DataStore.inMemory()
        let posted = store.postStatus(kind: .text, text: "temp", localName: nil, paletteIndex: 0)
        let older = StatusViewer(id: UUID(), displayName: "Bipin",
                                 viewedAt: Date().addingTimeInterval(-600))
        let newer = StatusViewer(id: UUID(), displayName: "Jisnu", viewedAt: Date())

        store.setStatusViewers([older, newer], for: posted.id)
        XCTAssertEqual(store.viewers(of: posted.id).map(\.displayName), ["Jisnu", "Bipin"])

        store.deleteStatus(posted.id)
        XCTAssertTrue(store.viewers(of: posted.id).isEmpty)
    }

    func testDeleteStatusRemoves() {
        let store = DataStore.inMemory()
        let posted = store.postStatus(kind: .text, text: "temp", localName: nil, paletteIndex: 0)
        XCTAssertTrue(store.myActiveStatuses.contains { $0.id == posted.id })

        store.deleteStatus(posted.id)
        XCTAssertFalse(store.myActiveStatuses.contains { $0.id == posted.id })
    }

    // MARK: Scheduled calls

    func testScheduledCallsProjectFutureSortedAscending() {
        let store = DataStore.inMemory()
        XCTAssertTrue(store.scheduledCalls.isEmpty, "nothing scheduled in seed data")

        let later = ScheduledCall(title: "Design sync", displayName: "Jisnu",
                                  media: .video, date: Date().addingTimeInterval(7_200))
        let sooner = ScheduledCall(title: "Standup", displayName: "Bipin",
                                   media: .voice, date: Date().addingTimeInterval(3_600))
        store.scheduleCall(later)
        store.scheduleCall(sooner)

        XCTAssertEqual(store.scheduledCalls.map(\.id), [sooner.id, later.id],
                       "projection must be ascending by date regardless of insert order")
    }

    func testPastScheduledCallExcludedFromProjection() {
        let store = DataStore.inMemory()
        let past = ScheduledCall(title: "Missed window", displayName: "Neel",
                                 date: Date().addingTimeInterval(-3_600))
        store.scheduleCall(past)
        XCTAssertFalse(store.scheduledCalls.contains { $0.id == past.id })
    }

    func testDeleteScheduledCallRemoves() {
        let store = DataStore.inMemory()
        let call = ScheduledCall(title: "Catch-up", displayName: "Cadence",
                                 date: Date().addingTimeInterval(1_800))
        store.scheduleCall(call)
        XCTAssertTrue(store.scheduledCalls.contains { $0.id == call.id })

        store.deleteScheduledCall(call.id)
        XCTAssertTrue(store.scheduledCalls.isEmpty)
    }

    // MARK: Group membership

    func testAddMembersAppendsParticipantsAndSystemMessage() {
        let store = DataStore.inMemory()
        guard let group = seededGroupChat(store) else { return XCTFail("no seeded group") }
        let newcomers = store.users.values
            .filter { !group.participantIDs.contains($0.id) }
            .prefix(2)
            .map(\.id)
        XCTAssertEqual(newcomers.count, 2, "seed should have users outside the group")

        store.addMembers(Array(newcomers), to: group.id)

        let updated = store.chat(group.id)!
        for id in newcomers { XCTAssertTrue(updated.participantIDs.contains(id)) }
        let last = store.messages(in: group.id).last
        XCTAssertEqual(last?.kind, .system)
        XCTAssertEqual(last?.text, "You added 2 people.")
    }

    func testAddMembersDedupesExistingParticipants() {
        let store = DataStore.inMemory()
        guard let group = seededGroupChat(store) else { return XCTFail("no seeded group") }
        let existing = group.participantIDs.first { $0 != store.currentUser.id }!
        let newcomer = store.users.values.first { !group.participantIDs.contains($0.id) }!.id

        store.addMembers([existing, newcomer], to: group.id)

        let updated = store.chat(group.id)!
        XCTAssertEqual(updated.participantIDs.filter { $0 == existing }.count, 1)
        XCTAssertEqual(store.messages(in: group.id).last?.text, "You added 1 person.",
                       "only the genuinely new member counts")
    }

    func testAddMembersAllExistingIsNoOp() {
        let store = DataStore.inMemory()
        guard let group = seededGroupChat(store) else { return XCTFail("no seeded group") }
        let before = store.messages(in: group.id).count

        store.addMembers(group.participantIDs, to: group.id)

        XCTAssertEqual(store.chat(group.id)?.participantIDs.count, group.participantIDs.count)
        XCTAssertEqual(store.messages(in: group.id).count, before, "no system message on a no-op")
    }

    func testLeaveGroupRemovesCurrentUserAndKeepsForeignOwner() {
        let store = DataStore.inMemory()
        guard let group = seededGroupChat(store) else { return XCTFail("no seeded group") }
        let ownerBefore = group.group?.ownerID
        XCTAssertNotEqual(ownerBefore, store.currentUser.id, "seed group is owned by someone else")

        store.leaveGroup(group.id)

        let updated = store.chat(group.id)!
        XCTAssertFalse(updated.participantIDs.contains(store.currentUser.id))
        XCTAssertEqual(updated.group?.ownerID, ownerBefore, "ownership unchanged when a non-owner leaves")
        XCTAssertFalse(updated.group?.adminIDs.contains(store.currentUser.id) ?? true)
        XCTAssertEqual(store.messages(in: group.id).last?.text, "You left")
    }

    func testLeaveGroupPromotesNewOwnerWhenOwnerLeaves() {
        let store = DataStore.inMemory()
        let members = store.users.values
            .filter { $0.id != store.currentUser.id }
            .prefix(2)
            .map(\.id)
        let chat = store.createGroup(title: "Owner exodus", memberIDs: Array(members))
        XCTAssertEqual(chat.group?.ownerID, store.currentUser.id)

        store.leaveGroup(chat.id)

        let updated = store.chat(chat.id)!
        XCTAssertFalse(updated.participantIDs.contains(store.currentUser.id))
        guard let newOwner = updated.group?.ownerID else { return XCTFail("group lost its owner") }
        XCTAssertTrue(members.contains(newOwner), "ownership hands off to a remaining member")
        XCTAssertTrue(updated.group?.adminIDs.contains(newOwner) ?? false, "successor becomes admin")
    }

    func testSetGroupApproveNewMembersPersists() {
        let store = DataStore.inMemory()
        guard let group = seededGroupChat(store) else { return XCTFail("no seeded group") }
        XCTAssertEqual(group.group?.permissions.approveNewMembers, false)

        store.setGroupApproveNewMembers(true, in: group.id)
        XCTAssertEqual(store.chat(group.id)?.group?.permissions.approveNewMembers, true)

        store.setGroupApproveNewMembers(false, in: group.id)
        XCTAssertEqual(store.chat(group.id)?.group?.permissions.approveNewMembers, false)
    }

    // MARK: Default disappearing timer inheritance

    func testStartDirectChatInheritsDefaultDisappearingSeconds() {
        let store = DataStore.inMemory()
        store.privacy.defaultDisappearingSeconds = 86_400

        let fresh = InditalkUser(displayName: "Newcomer", phoneNumber: "+1 (415) 555-0300")
        let chat = store.startDirectChat(with: fresh)

        XCTAssertEqual(chat.disappearingSeconds, 86_400)
        XCTAssertEqual(store.chat(chat.id)?.disappearingSeconds, 86_400)
        XCTAssertTrue(store.messages(in: chat.id).contains {
            $0.kind == .system && $0.text.contains("default timer")
        }, "new chat carries the default-timer system notice")
    }

    func testCreateGroupInheritsDefaultDisappearingSeconds() {
        let store = DataStore.inMemory()
        store.privacy.defaultDisappearingSeconds = 86_400

        let member = someoneElse(store).id
        let chat = store.createGroup(title: "Timer group", memberIDs: [member])

        XCTAssertEqual(chat.disappearingSeconds, 86_400)
        XCTAssertEqual(store.chat(chat.id)?.disappearingSeconds, 86_400)
    }

    func testStartDirectChatReturnsExistingChatForKnownContact() {
        let store = DataStore.inMemory()
        guard let direct = store.chats.first(where: { $0.kind == .direct }),
              let other = store.otherParticipant(in: direct) else {
            return XCTFail("no seeded direct chat")
        }
        let before = store.chats.count
        let chat = store.startDirectChat(with: other)
        XCTAssertEqual(chat.id, direct.id)
        XCTAssertEqual(store.chats.count, before, "no duplicate chat created")
    }

    // MARK: Delivery lifecycle vs read receipts

    func testDeliveryStopsAtDeliveredWhenReadReceiptsOff() async {
        let store = DataStore.inMemory()
        store.privacy.readReceipts = false
        let chat = store.visibleChats[0]

        let msg = store.send(text: "no receipts", to: chat.id)
        let state: @MainActor () -> MessageState? = {
            store.messages(in: chat.id).first { $0.id == msg.id }?.state
        }

        let delivered = await waitUntil(timeout: 5) { state() == .delivered }
        XCTAssertTrue(delivered, "message should reach .delivered (~1.3s)")

        // The .read step would land ~1.6s after .delivered; give it 2s and assert it never does.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(state(), .delivered, "with read receipts off the lifecycle must stop at .delivered")
    }

    func testDeliveryReachesReadWhenReadReceiptsOn() async {
        let store = DataStore.inMemory()
        XCTAssertTrue(store.privacy.readReceipts, "read receipts default on")
        let chat = store.visibleChats[0]

        let msg = store.send(text: "with receipts", to: chat.id)
        let read = await waitUntil(timeout: 8) {
            store.messages(in: chat.id).first { $0.id == msg.id }?.state == .read
        }
        XCTAssertTrue(read, "message should reach .read (~2.9s)")
    }

    // MARK: Avatar

    func testUpdateAvatarSetsAndClearsLocalName() {
        let store = DataStore.inMemory()
        XCTAssertNil(store.currentUser.avatarLocalName)

        let name = "test-avatar-\(UUID().uuidString).jpg"
        store.updateAvatar(localName: name)
        XCTAssertEqual(store.currentUser.avatarLocalName, name)

        let replacement = "test-avatar-\(UUID().uuidString).jpg"
        store.updateAvatar(localName: replacement)
        XCTAssertEqual(store.currentUser.avatarLocalName, replacement)

        store.updateAvatar(localName: nil)
        XCTAssertNil(store.currentUser.avatarLocalName)
    }

    // MARK: Remote ingestion (decrypt-failure placeholder handling)

    func testIngestNeverClobbersPlaintextWithDecryptFailure() {
        let store = DataStore.inMemory()
        let peer = store.addContact(name: "Vera", phone: "+15550001111")
        let chat = store.startDirectChat(with: peer)
        let id = UUID()

        let plain = Message(id: id, chatID: chat.id, senderID: peer.id,
                            text: "hello", isOutgoing: false)
        store.ingest(remoteMessages: [plain], in: chat.id)
        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == id }?.text, "hello")

        // A later snapshot whose decrypt failed must not destroy the good plaintext.
        var failed = plain
        failed.text = Message.failedDecryptionText
        store.ingest(remoteMessages: [failed], in: chat.id)
        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == id }?.text, "hello")
    }

    func testIngestHealsPlaceholderOnceDecryptionSucceeds() {
        let store = DataStore.inMemory()
        let peer = store.addContact(name: "Vera", phone: "+15550002222")
        let chat = store.startDirectChat(with: peer)
        let id = UUID()

        let failed = Message(id: id, chatID: chat.id, senderID: peer.id,
                             text: Message.failedDecryptionText, isOutgoing: false)
        store.ingest(remoteMessages: [failed], in: chat.id)
        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == id }?.text,
                       Message.failedDecryptionText)

        // Once the key agreement succeeds, the re-decrypted snapshot replaces it.
        var plain = failed
        plain.text = "now readable"
        store.ingest(remoteMessages: [plain], in: chat.id)
        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == id }?.text, "now readable")
    }

    // MARK: Delete semantics (tombstones, hide-for-me, resurrection)

    func testDeletedMessageNeverResurrectedByLaterSnapshot() {
        let store = DataStore.inMemory()
        let peer = store.addContact(name: "Vera", phone: "+15550004444")
        let chat = store.startDirectChat(with: peer)
        let id = UUID()

        let original = Message(id: id, chatID: chat.id, senderID: peer.id,
                               text: "secret", isOutgoing: false)
        store.ingest(remoteMessages: [original], in: chat.id)
        store.deleteMessage(id, in: chat.id)
        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == id }?.isDeleted, true)

        // Firestore snapshots re-deliver the full message list; the tombstone must win.
        store.ingest(remoteMessages: [original], in: chat.id)
        let after = store.messages(in: chat.id).first { $0.id == id }
        XCTAssertEqual(after?.isDeleted, true)
        XCTAssertEqual(after?.text, "")
    }

    func testIngestRemoteTombstoneAppliesToExistingMessage() {
        let store = DataStore.inMemory()
        let peer = store.addContact(name: "Vera", phone: "+15550005555")
        let chat = store.startDirectChat(with: peer)
        let id = UUID()

        let original = Message(id: id, chatID: chat.id, senderID: peer.id,
                               text: "soon gone", isOutgoing: false)
        store.ingest(remoteMessages: [original], in: chat.id)

        var tombstone = original
        tombstone.isDeleted = true
        tombstone.text = ""
        store.ingest(remoteMessages: [tombstone], in: chat.id)
        let after = store.messages(in: chat.id).first { $0.id == id }
        XCTAssertEqual(after?.isDeleted, true)
        XCTAssertEqual(after?.text, "")
    }

    func testHideMessageRemovesFromProjectionAndSurvivesReIngest() {
        let store = DataStore.inMemory()
        let peer = store.addContact(name: "Vera", phone: "+15550006666")
        let chat = store.startDirectChat(with: peer)
        let id = UUID()

        let message = Message(id: id, chatID: chat.id, senderID: peer.id,
                              text: "hide me", isOutgoing: false)
        store.ingest(remoteMessages: [message], in: chat.id)
        store.hideMessage(id, in: chat.id)
        XCTAssertFalse(store.messages(in: chat.id).contains { $0.id == id })

        // The next snapshot re-delivers it; it must stay hidden on this device.
        store.ingest(remoteMessages: [message], in: chat.id)
        XCTAssertFalse(store.messages(in: chat.id).contains { $0.id == id })
    }

    func testDeleteOwnMessageNotifiesDeleteSink() {
        let store = DataStore.inMemory()
        let peer = store.addContact(name: "Vera", phone: "+15550007777")
        let chat = store.startDirectChat(with: peer)
        store.remoteSink = { _ in }   // suppress the local delivery simulation
        let sent = store.send(text: "mine", to: chat.id)

        var sunk: (UUID, UUID)?
        store.messageDeleteSink = { sunk = ($0, $1) }
        store.deleteMessage(sent.id, in: chat.id)
        XCTAssertEqual(sunk?.0, sent.id)
        XCTAssertEqual(sunk?.1, chat.id)
    }

    func testHideOrDeleteIncomingNeverNotifiesDeleteSink() {
        let store = DataStore.inMemory()
        let peer = store.addContact(name: "Vera", phone: "+15550008888")
        let chat = store.startDirectChat(with: peer)
        let id = UUID()
        store.ingest(remoteMessages: [Message(id: id, chatID: chat.id, senderID: peer.id,
                                              text: "theirs", isOutgoing: false)], in: chat.id)

        var called = false
        store.messageDeleteSink = { _, _ in called = true }
        store.deleteMessage(id, in: chat.id)   // incoming: local tombstone only
        store.hideMessage(id, in: chat.id)
        XCTAssertFalse(called)
    }

    // MARK: Reply threading, pin, resend, media phases

    func testIngestPreservesAndBackfillsReplyToID() {
        let store = DataStore.inMemory()
        let peer = store.addContact(name: "Vera", phone: "+15550009999")
        let chat = store.startDirectChat(with: peer)
        let originalID = UUID()
        let replyID = UUID()

        store.ingest(remoteMessages: [Message(id: originalID, chatID: chat.id, senderID: peer.id,
                                              text: "root", isOutgoing: false)], in: chat.id)
        // First delivery of the reply lacks the link (e.g. older mapping); a later
        // snapshot carries it — the row must backfill, not stay unthreaded.
        store.ingest(remoteMessages: [Message(id: replyID, chatID: chat.id, senderID: peer.id,
                                              text: "reply", isOutgoing: false)], in: chat.id)
        store.ingest(remoteMessages: [Message(id: replyID, chatID: chat.id, senderID: peer.id,
                                              text: "reply", isOutgoing: false,
                                              replyToID: originalID)], in: chat.id)
        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == replyID }?.replyToID, originalID)
    }

    func testTogglePinMessage() {
        let store = DataStore.inMemory()
        let peer = store.addContact(name: "Vera", phone: "+15551110000")
        let chat = store.startDirectChat(with: peer)
        store.remoteSink = { _ in }
        let sent = store.send(text: "pin me", to: chat.id)

        store.togglePinMessage(sent.id, in: chat.id)
        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == sent.id }?.isPinned, true)
        store.togglePinMessage(sent.id, in: chat.id)
        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == sent.id }?.isPinned, false)
    }

    func testResendOnlyRetriesFailedOutgoingThroughSink() {
        let store = DataStore.inMemory()
        let peer = store.addContact(name: "Vera", phone: "+15551110001")
        let chat = store.startDirectChat(with: peer)
        var pushed: [UUID] = []
        store.remoteSink = { pushed.append($0.id) }
        let sent = store.send(text: "flaky", to: chat.id)
        XCTAssertEqual(pushed, [sent.id])

        // Not failed yet -> resend is a no-op.
        store.resend(sent.id, in: chat.id)
        XCTAssertEqual(pushed, [sent.id])

        store.applyReceipt(.failed, for: sent.id, in: chat.id)
        store.resend(sent.id, in: chat.id)
        XCTAssertEqual(pushed, [sent.id, sent.id])
        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == sent.id }?.state, .sending)
    }

    func testMediaPhaseSetClearAndRetrySink() {
        let store = DataStore.inMemory()
        let id = UUID()
        store.setMediaPhase(.downloading, for: id)
        XCTAssertNotNil(store.mediaPhases[id])
        store.setMediaPhase(.failed, for: id)

        var retried: UUID?
        store.mediaRetrySink = { retried = $0 }
        store.retryMediaDownload(id)
        XCTAssertEqual(retried, id)

        store.setMediaPhase(nil, for: id)
        XCTAssertNil(store.mediaPhases[id])
    }

    func testIngestRemoteUsersCarriesAvatarURL() {
        let store = DataStore.inMemory()
        let user = InditalkUser(displayName: "Vincent", phoneNumber: "+15550003333",
                            avatarURL: "https://example.com/a.jpg", remoteUID: "uid-vincent")
        store.ingest(remoteUsers: [user])
        XCTAssertEqual(store.users[user.id]?.avatarURL, "https://example.com/a.jpg")

        // Server removal (nil) must clear it too.
        var removed = user
        removed.avatarURL = nil
        store.ingest(remoteUsers: [removed])
        XCTAssertNil(store.users[user.id]?.avatarURL)
    }
}
