//
//  AccountAndSafetyTests.swift
//  InditalkTests
//
//  Covers the App-Store-readiness additions that are unit-testable without a backend:
//  local account-deletion wipe, block enforcement in the store + composer, and the
//  abuse-report outbox.
//

import XCTest
@testable import Inditalk

@MainActor
final class AccountAndSafetyTests: XCTestCase {

    // MARK: Account deletion (local wipe)

    func testWipeAllLocalDataClearsEverything() {
        let store = DataStore.inMemory()
        XCTAssertFalse(store.chats.isEmpty, "seed should populate chats")

        // Dirty some state, including a block.
        let chat = store.visibleChats[0]
        store.send(text: "hello", to: chat.id)
        if let other = store.otherParticipant(in: chat) { store.block(other.id) }

        store.wipeAllLocalData()

        XCTAssertTrue(store.chats.isEmpty)
        XCTAssertTrue(store.calls.isEmpty)
        XCTAssertTrue(store.messagesByChat.allSatisfy { $0.value.isEmpty })
        XCTAssertTrue(store.privacy.blockedUserIDs.isEmpty)
        XCTAssertEqual(store.allStarred().count, 0)
    }

    // MARK: Block enforcement

    private func directChatWithOther(_ store: DataStore) -> (Chat, InditalkUser)? {
        for chat in store.visibleChats where chat.kind == .direct {
            if let other = store.otherParticipant(in: chat) { return (chat, other) }
        }
        return nil
    }

    func testIsBlockedChatTracksBlockState() {
        let store = DataStore.inMemory()
        guard let (chat, other) = directChatWithOther(store) else { return XCTFail("no direct chat") }

        XCTAssertFalse(store.isBlockedChat(chat.id))
        store.block(other.id)
        XCTAssertTrue(store.isBlocked(other.id))
        XCTAssertTrue(store.isBlockedChat(chat.id))
        store.unblock(other.id)
        XCTAssertFalse(store.isBlockedChat(chat.id))
    }

    func testComposerSendIsBlockedForBlockedContact() {
        let store = DataStore.inMemory()
        guard let (chat, other) = directChatWithOther(store) else { return XCTFail("no direct chat") }
        let vm = ChatDetailViewModel()

        store.block(other.id)
        let before = store.messages(in: chat.id).count
        vm.draft = "should not send"
        vm.send(into: chat.id, store: store)

        XCTAssertEqual(store.messages(in: chat.id).count, before, "sending to a blocked contact must be a no-op")
    }

    func testComposerSendWorksAfterUnblock() {
        let store = DataStore.inMemory()
        guard let (chat, other) = directChatWithOther(store) else { return XCTFail("no direct chat") }
        let vm = ChatDetailViewModel()

        store.block(other.id)
        store.unblock(other.id)
        let before = store.messages(in: chat.id).count
        vm.draft = "hi again"
        vm.send(into: chat.id, store: store)

        XCTAssertEqual(store.messages(in: chat.id).count, before + 1)
    }

    // MARK: Report outbox

    private func freshReportStore() -> ReportStore {
        let suite = "cove.tests.reports.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ReportStore(defaults: defaults)
    }

    func testReportOutboxRecordAndSubmit() {
        let store = freshReportStore()
        let report = Report(reporterID: UUID(), reportedUserID: UUID(), chatID: UUID(),
                            reason: .harassment, note: "abusive")

        XCTAssertTrue(store.pending().isEmpty)
        store.record(report)
        XCTAssertEqual(store.pending().count, 1)
        XCTAssertEqual(store.all().count, 1)

        store.markSubmitted(report.id)
        XCTAssertTrue(store.pending().isEmpty)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertTrue(store.all().first?.submitted ?? false)

        store.clear()
        XCTAssertTrue(store.all().isEmpty)
    }

    func testReportCodableRoundTrip() throws {
        let report = Report(reporterID: UUID(), reportedUserID: UUID(), chatID: nil,
                            reason: .impersonation, note: "fake profile")
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(Report.self, from: data)
        XCTAssertEqual(report, decoded)
    }
}
