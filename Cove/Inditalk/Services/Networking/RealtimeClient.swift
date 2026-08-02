//
//  RealtimeClient.swift
//  Inditalk
//
//  WebSocket realtime transport (URLSessionWebSocketTask). Implements the frame
//  envelope, auth handshake, heartbeat, and exponential-backoff reconnect described
//  in docs/PHASE3_BACKEND_API.md. Inbound frames are published for the sync engine.
//

import Foundation
import Combine

/// The envelope every realtime frame shares.
struct RealtimeFrame: Codable {
    enum Kind: String, Codable {
        case hello, ack, newMessage, deliveryReceipt, readReceipt
        case typingStart, typingStop, presence, callSignal, ping, pong
    }
    let type: Kind
    let id: String
    let chatId: UUID?
    let payload: Data?          // type-specific, often E2EE ciphertext
    let ts: Date
}

protocol RealtimeClientDelegate: AnyObject {
    func realtime(_ client: RealtimeClient, didReceive frame: RealtimeFrame)
    func realtimeDidChangeConnection(_ connected: Bool)
}

final class RealtimeClient: NSObject {
    nonisolated(unsafe) weak var delegate: RealtimeClientDelegate?

    private let url: URL
    // Conforming to URLSessionWebSocketDelegate makes this class Sendable, and
    // URLSessionWebSocketTask is not. Access is confined to the socket lifecycle calls
    // below, which is the same single-owner discipline `delegate` above relies on.
    private nonisolated(unsafe) var task: URLSessionWebSocketTask?
    // Built in init rather than lazily: the session needs `self` as its delegate, so it
    // cannot be a `let`, and `lazy` storage is mutable in a way Sendable rejects.
    // Assigned exactly once, immediately after super.init.
    private nonisolated(unsafe) var session: URLSession!
    // Socket state, all touched only from the connect/close/reconnect path and the
    // URLSession delegate callbacks for this one session — the same single-owner
    // discipline as `task` and `delegate` above.
    private nonisolated(unsafe) var token: String?
    private nonisolated(unsafe) var reconnectAttempt = 0
    private nonisolated(unsafe) var heartbeat: Task<Void, Never>?
    private nonisolated(unsafe) var isClosing = false

    init(url: URL = URL(string: "wss://rt.inditalk.com/v1/ws")!) {
        self.url = url
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect(token: String) {
        self.token = token
        isClosing = false
        openSocket()
    }

    func disconnect() {
        isClosing = true
        heartbeat?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    func send(_ frame: RealtimeFrame) {
        guard let data = try? JSONEncoder.cove.encode(frame) else { return }
        task?.send(.data(data)) { error in
            if let error { print("ws send error: \(error)") }
        }
    }

    // MARK: internals

    private func openSocket() {
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        task = session.webSocketTask(with: request)
        task?.resume()
        sendHello()
        receiveLoop()
        startHeartbeat()
    }

    private func sendHello() {
        send(RealtimeFrame(type: .hello, id: UUID().uuidString, chatId: nil, payload: nil, ts: Date()))
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case let .data(data) = message,
                   let frame = try? JSONDecoder.cove.decode(RealtimeFrame.self, from: data) {
                    self.reconnectAttempt = 0
                    self.delegate?.realtime(self, didReceive: frame)
                } else if case let .string(text) = message,
                          let frame = try? JSONDecoder.cove.decode(RealtimeFrame.self, from: Data(text.utf8)) {
                    self.delegate?.realtime(self, didReceive: frame)
                }
                self.receiveLoop()
            case .failure:
                self.scheduleReconnect()
            }
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)   // 25s ping
                guard let self, !self.isClosing else { break }
                self.send(RealtimeFrame(type: .ping, id: UUID().uuidString, chatId: nil, payload: nil, ts: Date()))
            }
        }
    }

    /// Exponential backoff with jitter, capped at 30s.
    private func scheduleReconnect() {
        guard !isClosing else { return }
        delegate?.realtimeDidChangeConnection(false)
        reconnectAttempt += 1
        let base = min(pow(2.0, Double(reconnectAttempt)), 30)
        let jitter = Double.random(in: 0...0.5) * base
        let delay = base + jitter
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.isClosing else { return }
            self.openSocket()
        }
    }
}

extension RealtimeClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        delegate?.realtimeDidChangeConnection(true)
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if !isClosing { scheduleReconnect() }
    }
}
