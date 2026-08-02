//
//  LiveFirebaseMessagingTests.swift
//  InditalkTests
//
//  Reproduces, against the REAL project, the failure where a sent message never reached
//  the other person: the chat document was only ever created locally, so
//  `firestore.rules` rejected the message write (isParticipant reads
//  chats/{chatId}.participantIds, which errored on a missing doc) and the peer's chat
//  query matched nothing.
//
//  Uses two console-configured test phone numbers as two distinct accounts.
//
//  OPT-IN ONLY — see LiveFirebaseAuthTests for why, and for the run command.
//

import XCTest
import FirebaseAuth
@testable import Inditalk

@MainActor
final class LiveFirebaseMessagingTests: XCTestCase {

    private let phoneA = "+16505553434"
    private let codeA = "123456"
    private let phoneB = "+16505555678"
    private let codeB = "222222"

    override func setUp() async throws {
        #if INDITALK_LIVE_TESTS
        try? Auth.auth().signOut()
        #else
        throw XCTSkip("Live Firebase test — build with SWIFT_ACTIVE_COMPILATION_CONDITIONS=INDITALK_LIVE_TESTS to run.")
        #endif
    }

    override func tearDown() async throws {
        try? Auth.auth().signOut()
    }

    /// Sign in as `phone` and return the uid.
    private func signIn(_ phone: String, code: String) async throws -> String {
        let auth = FirebaseAuthService.shared
        auth.prepareForPhoneAuth()
        try? auth.signOut()
        try await auth.sendCode(to: phone)
        return try await auth.verify(code: code)
    }

    /// A store with no seeded fixtures, standing in for a fresh install.
    private func makeEmptyStore() -> DataStore {
        DataStore(container: PersistenceController.inMemoryContainer(), seed: nil, persistent: false)
    }

    private func waitUntil(timeout: TimeInterval = 20,
                           _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return condition()
    }

    /// The end-to-end path the user hit: A adds B, sends a message, and the message must
    /// actually land in Firestore — which only happens if the chat document was created.
    func testSendingCreatesRemoteChatAndDeliversMessage() async throws {
        // Learn B's uid, then switch back to A. B is just a real second account here.
        let uidB = try await signIn(phoneB, code: codeB)
        let uidA = try await signIn(phoneA, code: codeA)
        XCTAssertNotEqual(uidA, uidB, "the two test numbers must be distinct accounts")

        let store = makeEmptyStore()
        store.adoptIdentity(try XCTUnwrap(FirebaseAuthService.shared.localIdentity()))

        // B as a known contact carrying their real uid — what a QR scan or participant
        // sync produces.
        let peer = InditalkUser(id: FirebaseSyncCoordinator.stableUUID(uidB),
                            displayName: "Test Peer B",
                            phoneNumber: phoneB,
                            remoteUID: uidB)
        store.ingest(remoteUsers: [peer])

        let coordinator = FirebaseSyncCoordinator()
        coordinator.start(store: store)
        defer { coordinator.stop() }

        XCTAssertNotNil(store.remoteSink,
                        "coordinator.start must install the outgoing-message hook")

        let chat = store.startDirectChat(with: peer)
        let body = "live-test-\(UUID().uuidString.prefix(8))"
        store.send(text: body, to: chat.id, replyingTo: nil)

        // Wait for the chat document before listening to its messages. The messages rule
        // is isParticipant(chatId), which get()s the PARENT chat — against a chat that
        // hasn't been created yet that errors, and a denied Firestore listener is never
        // retried. In the app this ordering is guaranteed: subscribeMessages is only
        // called for chats that listenChats has already returned.
        var chatsForA: [RemoteChat] = []
        let chatListener = FirestoreService.shared.listenChats { chats in chatsForA = chats }
        defer { chatListener?.remove() }

        let chatCreated = await waitUntil { chatsForA.contains { $0.id == chat.id.uuidString } }
        XCTAssertTrue(chatCreated, "sending did not create the chat document in Firestore")

        // Read the message back, which also proves the rules allow a participant to read.
        var received: [RemoteMessage] = []
        let listener = FirestoreService.shared.listenMessages(chatId: chat.id.uuidString) { messages in
            received = messages
        }
        defer { listener.remove() }

        let arrived = await waitUntil { received.contains { $0.senderId == uidA } }
        XCTAssertTrue(arrived,
                      "the sent message never reached Firestore — the chat document was probably not created")
    }

    /// The other side of the complaint: B's chat list must show the conversation. This is
    /// the assertion that fails if participantIds is missing or wrong.
    func testPeerSeesTheChatInTheirOwnChatList() async throws {
        let uidB = try await signIn(phoneB, code: codeB)
        _ = try await signIn(phoneA, code: codeA)

        let storeA = makeEmptyStore()
        storeA.adoptIdentity(try XCTUnwrap(FirebaseAuthService.shared.localIdentity()))
        let peer = InditalkUser(id: FirebaseSyncCoordinator.stableUUID(uidB),
                            displayName: "Test Peer B",
                            phoneNumber: phoneB,
                            remoteUID: uidB)
        storeA.ingest(remoteUsers: [peer])

        let coordinatorA = FirebaseSyncCoordinator()
        coordinatorA.start(store: storeA)
        let chat = storeA.startDirectChat(with: peer)
        storeA.send(text: "hello from A", to: chat.id, replyingTo: nil)

        // Give the chat + message writes time to land, then become B.
        _ = await waitUntil(timeout: 15) { false }
        coordinatorA.stop()

        _ = try await signIn(phoneB, code: codeB)
        var chatsForB: [RemoteChat] = []
        let listener = FirestoreService.shared.listenChats { chats in chatsForB = chats }
        defer { listener?.remove() }

        let sees = await waitUntil { chatsForB.contains { $0.id == chat.id.uuidString } }
        XCTAssertTrue(sees, "the recipient's chat list did not include the conversation")

        // Seeing the chat row is not enough — the recipient must be able to read the
        // messages inside it, which is the other half of "I see nothing on the other side".
        var messagesForB: [RemoteMessage] = []
        let messageListener = FirestoreService.shared.listenMessages(chatId: chat.id.uuidString) { messages in
            messagesForB = messages
        }
        defer { messageListener.remove() }

        let readsMessages = await waitUntil { !messagesForB.isEmpty }
        XCTAssertTrue(readsMessages,
                      "the recipient could not read the messages in the chat")
    }
}
