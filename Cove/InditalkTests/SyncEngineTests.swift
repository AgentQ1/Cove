//
//  SyncEngineTests.swift
//  InditalkTests
//
//  Verifies the outbox drains on success and retains items (with backoff) on
//  failure, using an in-memory mock APIClient — no network.
//

import XCTest
@testable import Inditalk

/// Configurable mock backend for exercising the sync engine.
actor MockAPIClient: APIClient {
    var failNextSends: Int = 0
    private(set) var sendCount = 0

    func setFailures(_ n: Int) { failNextSends = n }
    func sends() -> Int { sendCount }

    func sendMessage(_ body: SendMessageRequest, idempotencyKey: String) async throws -> MessageDTO {
        sendCount += 1
        if failNextSends > 0 {
            failNextSends -= 1
            throw APIError(code: "unavailable", message: "mock failure", retryAfterSeconds: nil)
        }
        return MessageDTO(id: UUID(), chatId: body.chatId, senderId: UUID(),
                          kind: body.kind, ciphertext: body.ciphertext, sentAt: Date(), state: "sent")
    }

    // Unused endpoints for these tests.
    func requestOTP(_ body: OTPRequest) async throws -> OTPRequestResponse { .init(requestId: "x", expiresInSeconds: 60) }
    func verifyOTP(_ body: OTPVerify) async throws -> Session { .init(userId: UUID(), accessToken: "t", refreshToken: "r", expiresAt: Date()) }
    func fetchChats(cursor: String?) async throws -> Page<ChatDTO> { .init(items: [], nextCursor: nil) }
    func fetchMessages(chatID: UUID, cursor: String?) async throws -> Page<MessageDTO> { .init(items: [], nextCursor: nil) }
    func createGroup(_ body: CreateGroupRequest) async throws -> ChatDTO { .init(id: UUID(), kind: "group", title: body.title, updatedAt: Date(), unread: 0) }
    func discoverContacts(_ body: ContactDiscoveryRequest) async throws -> [DiscoveredContact] { [] }
    func presignUpload(_ body: PresignRequest) async throws -> PresignResponse {
        .init(uploadURL: URL(string: "https://x")!, downloadURL: URL(string: "https://y")!, headers: [:])
    }
}

@MainActor
final class SyncEngineTests: XCTestCase {

    private func makeEngine(_ api: APIClient) -> SyncEngine {
        SyncEngine(api: api, realtime: RealtimeClient())
    }

    func testOutboxDrainsOnSuccess() async {
        let api = MockAPIClient()
        let engine = makeEngine(api)
        engine.enqueue(SendMessageRequest(chatId: UUID(), kind: "text", ciphertext: "AAAA", replyTo: nil))
        await engine.drain()
        XCTAssertTrue(engine.pending.isEmpty, "successful send should clear the outbox")
        let count = await api.sends()
        XCTAssertEqual(count, 1)
    }

    func testFailedSendStaysQueuedWithBackoff() async {
        let api = MockAPIClient()
        await api.setFailures(1)
        let engine = makeEngine(api)
        engine.enqueue(SendMessageRequest(chatId: UUID(), kind: "text", ciphertext: "AAAA", replyTo: nil))
        await engine.drain()
        XCTAssertEqual(engine.pending.count, 1, "failed send should remain queued")
        XCTAssertEqual(engine.pending.first?.attempts, 1)
        XCTAssertGreaterThan(engine.pending.first!.nextAttemptAt, Date(), "backoff should push next attempt into the future")
    }

    func testIdempotencyKeyStableAcrossRetries() async {
        let api = MockAPIClient()
        await api.setFailures(1)
        let engine = makeEngine(api)
        let key = engine.enqueue(SendMessageRequest(chatId: UUID(), kind: "text", ciphertext: "AAAA", replyTo: nil))
        await engine.drain()
        XCTAssertEqual(engine.pending.first?.id, key, "the idempotency key must not change between attempts")
    }
}
