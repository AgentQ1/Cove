//
//  APIClient.swift
//  Inditalk
//
//  The REST surface documented in docs/PHASE3_BACKEND_API.md and docs/API_CONTRACTS.md.
//  `APIClient` is a protocol so the app can run against the live backend, a local
//  mock, or test doubles. `LiveAPIClient` is a real URLSession implementation with a
//  unified error envelope, bearer auth, and idempotency keys.
//

import Foundation

// MARK: - Contracts

// Sendable: conformers are actors (LiveAPIClient), and the existential is stored +
// awaited from the @MainActor SyncEngine, crossing actor boundaries under Swift 6.
protocol APIClient: Sendable {
    func requestOTP(_ body: OTPRequest) async throws -> OTPRequestResponse
    func verifyOTP(_ body: OTPVerify) async throws -> Session
    func fetchChats(cursor: String?) async throws -> Page<ChatDTO>
    func fetchMessages(chatID: UUID, cursor: String?) async throws -> Page<MessageDTO>
    func sendMessage(_ body: SendMessageRequest, idempotencyKey: String) async throws -> MessageDTO
    func createGroup(_ body: CreateGroupRequest) async throws -> ChatDTO
    func discoverContacts(_ body: ContactDiscoveryRequest) async throws -> [DiscoveredContact]
    func presignUpload(_ body: PresignRequest) async throws -> PresignResponse
}

// MARK: - Wire types (mirror the JSON in API_CONTRACTS.md)

// Sendable: these cross the actor boundary (LiveAPIClient is an actor) under Swift 6.
struct OTPRequest: Codable, Sendable { let phone: String; let region: String }
struct OTPRequestResponse: Codable, Sendable { let requestId: String; let expiresInSeconds: Int }
struct OTPVerify: Codable, Sendable { let requestId: String; let code: String; let deviceName: String }
struct Session: Codable, Sendable { let userId: UUID; let accessToken: String; let refreshToken: String; let expiresAt: Date }

struct Page<T: Codable & Sendable>: Codable, Sendable { let items: [T]; let nextCursor: String? }

struct ChatDTO: Codable, Sendable { let id: UUID; let kind: String; let title: String; let updatedAt: Date; let unread: Int }
struct MessageDTO: Codable, Sendable {
    let id: UUID; let chatId: UUID; let senderId: UUID
    let kind: String; let ciphertext: String; let sentAt: Date; let state: String
}
struct SendMessageRequest: Codable, Sendable { let chatId: UUID; let kind: String; let ciphertext: String; let replyTo: UUID? }
struct CreateGroupRequest: Codable, Sendable { let title: String; let memberIds: [UUID] }
struct ContactDiscoveryRequest: Codable, Sendable { let hashedNumbers: [String] }   // SHA-256 of E.164 numbers
struct DiscoveredContact: Codable, Sendable { let hashedNumber: String; let userId: UUID; let displayName: String }
struct PresignRequest: Codable, Sendable { let mimeType: String; let byteSize: Int }
struct PresignResponse: Codable, Sendable { let uploadURL: URL; let downloadURL: URL; let headers: [String: String] }

/// Unified error envelope returned by every non-2xx response.
struct APIError: Codable, Error, Sendable {
    let code: String        // e.g. "otp_expired", "rate_limited", "unauthorized"
    let message: String
    let retryAfterSeconds: Int?
}

// MARK: - Live implementation

actor LiveAPIClient: APIClient {
    private let baseURL: URL
    private let session: URLSession
    private var accessToken: String?

    init(baseURL: URL = URL(string: "https://api.inditalk.com/v1")!,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func setToken(_ token: String?) { accessToken = token }

    func requestOTP(_ body: OTPRequest) async throws -> OTPRequestResponse {
        try await post("/auth/otp/request", body)
    }
    func verifyOTP(_ body: OTPVerify) async throws -> Session {
        let s: Session = try await post("/auth/otp/verify", body)
        accessToken = s.accessToken
        return s
    }
    func fetchChats(cursor: String?) async throws -> Page<ChatDTO> {
        try await get("/chats", query: cursor.map { ["cursor": $0] } ?? [:])
    }
    func fetchMessages(chatID: UUID, cursor: String?) async throws -> Page<MessageDTO> {
        try await get("/chats/\(chatID)/messages", query: cursor.map { ["cursor": $0] } ?? [:])
    }
    func sendMessage(_ body: SendMessageRequest, idempotencyKey: String) async throws -> MessageDTO {
        try await post("/messages", body, headers: ["Idempotency-Key": idempotencyKey])
    }
    func createGroup(_ body: CreateGroupRequest) async throws -> ChatDTO {
        try await post("/groups", body)
    }
    func discoverContacts(_ body: ContactDiscoveryRequest) async throws -> [DiscoveredContact] {
        try await post("/contacts/discover", body)
    }
    func presignUpload(_ body: PresignRequest) async throws -> PresignResponse {
        try await post("/media/presign", body)
    }

    // MARK: transport

    private func get<R: Codable>(_ path: String, query: [String: String]) async throws -> R {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await send(URLRequest(url: comps.url!), method: "GET", body: Optional<Int>.none)
    }

    private func post<B: Codable, R: Codable>(_ path: String, _ body: B,
                                              headers: [String: String] = [:]) async throws -> R {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await send(req, method: "POST", body: body)
    }

    private func send<B: Codable, R: Codable>(_ request: URLRequest, method: String, body: B?) async throws -> R {
        var req = request
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ios;1.0", forHTTPHeaderField: "X-Inditalk-Client")
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONEncoder.cove.encode(body) }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            if let apiErr = try? JSONDecoder.cove.decode(APIError.self, from: data) { throw apiErr }
            throw APIError(code: "http_\(http.statusCode)", message: "Request failed", retryAfterSeconds: nil)
        }
        return try JSONDecoder.cove.decode(R.self, from: data)
    }
}

extension JSONEncoder {
    static let cove: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
extension JSONDecoder {
    static let cove: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
