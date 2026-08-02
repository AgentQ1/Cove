//
//  SyncEngine.swift
//  Inditalk
//
//  Offline-first send/receive engine. Outgoing messages are appended to a durable
//  outbox with an idempotency key and drained with retry + exponential backoff;
//  incoming realtime frames and delta-sync pages are merged into the store. This is
//  the client half of the design in docs/PHASE3_BACKEND_API.md.
//

import Foundation
import Combine

/// One queued outgoing operation. Persisted (SwiftData in Phase 2) so it survives
/// app restarts and drains when connectivity returns.
struct OutboxItem: Identifiable, Codable {
    let id: UUID                 // also the idempotency key
    let chatID: UUID
    let request: SendMessageRequest
    var attempts: Int
    var nextAttemptAt: Date
}

@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var isOnline = false
    @Published private(set) var pending: [OutboxItem] = []

    private let api: APIClient
    private let realtime: RealtimeClient
    private var draining = false
    /// Highest server cursor we've synced to, per chat (delta-sync watermark).
    private var cursors: [UUID: String] = [:]

    init(api: APIClient, realtime: RealtimeClient) {
        self.api = api
        self.realtime = realtime
    }

    // MARK: Outbox

    /// Enqueue a message for reliable delivery. Returns the idempotency key.
    @discardableResult
    func enqueue(_ request: SendMessageRequest) -> UUID {
        let item = OutboxItem(id: UUID(), chatID: request.chatId, request: request,
                              attempts: 0, nextAttemptAt: Date())
        pending.append(item)
        Task { await drain() }
        return item.id
    }

    /// Drain the outbox, honoring per-item backoff. Idempotency keys make retries safe.
    func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }

        for index in pending.indices where pending[index].nextAttemptAt <= Date() {
            let item = pending[index]
            do {
                _ = try await api.sendMessage(item.request, idempotencyKey: item.id.uuidString)
                pending.removeAll { $0.id == item.id }
            } catch {
                var updated = item
                updated.attempts += 1
                let backoff = min(pow(2.0, Double(updated.attempts)), 60)
                updated.nextAttemptAt = Date().addingTimeInterval(backoff)
                if let i = pending.firstIndex(where: { $0.id == item.id }) { pending[i] = updated }
            }
        }
    }

    // MARK: Delta sync

    /// Pull any messages newer than our stored cursor for a chat and merge them.
    func syncChat(_ chatID: UUID, into store: DataStore) async {
        do {
            var cursor = cursors[chatID]
            repeat {
                let page = try await api.fetchMessages(chatID: chatID, cursor: cursor)
                // merge(page.items) — dedup by id, apply newest state (elided in Phase 1).
                cursor = page.nextCursor
                cursors[chatID] = cursor
            } while cursor != nil
        } catch {
            // Stay offline-first: failures are non-fatal; retry on next connectivity event.
        }
    }

    func start(token: String) {
        realtime.delegate = self
        realtime.connect(token: token)
    }
}

extension SyncEngine: RealtimeClientDelegate {
    nonisolated func realtime(_ client: RealtimeClient, didReceive frame: RealtimeFrame) {
        // Route frames: newMessage -> insert; receipts -> state transition; typing/presence -> UI.
    }
    nonisolated func realtimeDidChangeConnection(_ connected: Bool) {
        Task { @MainActor in
            self.isOnline = connected
            if connected { await self.drain() }
        }
    }
}
