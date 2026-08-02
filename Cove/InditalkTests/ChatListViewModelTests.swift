//
//  ChatListViewModelTests.swift
//  InditalkTests
//
//  Covers chat-list search filtering and pinned ordering, plus the store's
//  send/read/pin/mute/archive mutations.
//

import XCTest
@testable import Inditalk

@MainActor
final class ChatListViewModelTests: XCTestCase {

    func testRowsReturnAllVisibleChatsByDefault() {
        let store = DataStore.inMemory()
        let vm = ChatListViewModel()
        let rows = vm.rows(store: store)
        XCTAssertEqual(rows.count, store.visibleChats.count)
        XCTAssertFalse(rows.isEmpty)
    }

    func testSearchFiltersByTitle() {
        let store = DataStore.inMemory()
        let vm = ChatListViewModel()
        vm.searchText = "cadence"
        let rows = vm.rows(store: store)
        XCTAssertTrue(rows.allSatisfy { $0.chat.title.lowercased().contains("cadence") })
        XCTAssertGreaterThanOrEqual(rows.count, 1)
    }

    func testSearchMatchesMessageBody() {
        let store = DataStore.inMemory()
        let vm = ChatListViewModel()
        vm.searchText = "transit center"   // appears in the Alexandra thread
        let rows = vm.rows(store: store)
        XCTAssertGreaterThanOrEqual(rows.count, 1)
    }

    func testPinnedChatsSortFirst() {
        let store = DataStore.inMemory()
        guard let target = store.visibleChats.last else { return XCTFail("no chats") }
        store.togglePin(target.id)
        XCTAssertEqual(store.visibleChats.first?.id, target.id)
    }

    func testArchiveRemovesFromVisibleList() {
        let store = DataStore.inMemory()
        let target = store.visibleChats[0]
        let before = store.visibleChats.count
        store.toggleArchive(target.id)
        XCTAssertEqual(store.visibleChats.count, before - 1)
        XCTAssertTrue(store.archivedChats.contains { $0.id == target.id })
    }

    func testMarkReadClearsUnread() {
        let store = DataStore.inMemory()
        guard let unread = store.chats.first(where: { $0.unreadCount > 0 }) else {
            return XCTFail("expected an unread chat in seed data")
        }
        store.markRead(unread.id)
        XCTAssertEqual(store.chat(unread.id)?.unreadCount, 0)
    }

    func testSendAppendsOutgoingMessageInSendingState() {
        let store = DataStore.inMemory()
        let chat = store.visibleChats[0]
        let before = store.messages(in: chat.id).count
        let msg = store.send(text: "Hello there", to: chat.id, replyingTo: nil)
        XCTAssertEqual(store.messages(in: chat.id).count, before + 1)
        XCTAssertTrue(msg.isOutgoing)
        XCTAssertEqual(msg.state, .sending)
        XCTAssertEqual(store.messages(in: chat.id).last?.text, "Hello there")
    }

    func testToggleMuteAndPinFlags() {
        let store = DataStore.inMemory()
        let chat = store.visibleChats[0]
        store.toggleMute(chat.id)
        XCTAssertTrue(store.chat(chat.id)?.isMuted ?? false)
        store.togglePin(chat.id)
        XCTAssertTrue(store.chat(chat.id)?.isPinned ?? false)
    }

    func testStarAndReaction() {
        let store = DataStore.inMemory()
        let chat = store.visibleChats.first { !store.messages(in: $0.id).isEmpty }!
        let msg = store.messages(in: chat.id).first!
        store.toggleStar(msg.id, in: chat.id)
        XCTAssertTrue(store.allStarred().contains { $0.id == msg.id })
        store.addReaction("❤️", to: msg.id, in: chat.id)
        XCTAssertEqual(store.messages(in: chat.id).first { $0.id == msg.id }?.reactions.first?.emoji, "❤️")
    }
}
