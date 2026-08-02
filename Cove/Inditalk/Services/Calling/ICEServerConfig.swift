//
//  ICEServerConfig.swift
//  Inditalk
//
//  Central source of the ICE servers WebRTC uses for NAT traversal. Public STUN is
//  always included (fine for LAN/simulator); TURN — required for reliable real-world
//  calls behind symmetric NATs — is populated at RUNTIME and never hardcoded.
//
//  Security: TURN credentials are SHORT-LIVED and minted by the backend (the
//  `getTurnCredentials` Cloud Function — see functions/turn.js), then installed here
//  via `credentialProvider`. Long-lived TURN secrets must never ship inside the app
//  binary. Until TURN is configured, calls fall back to STUN-only.
//
//  REQUIRES the WebRTC SPM package.
//

import Foundation
import WebRTC

/// One relay entry as minted by the backend: a set of URLs sharing one ephemeral
/// username/credential pair.
struct TurnServer: Equatable, Sendable {
    var urls: [String]
    var username: String
    var credential: String

    var isUsable: Bool { !urls.isEmpty && !username.isEmpty && !credential.isEmpty }
}

/// A backend-minted TURN grant with the moment it stops working. Empty (no servers) is
/// a legitimate answer — it means the project has no TURN provider configured yet and
/// clients should stay on STUN.
struct TurnCredentials: Equatable, Sendable {
    var servers: [TurnServer]
    var expiresAt: Date

    static let none = TurnCredentials(servers: [], expiresAt: .distantPast)

    var isEmpty: Bool { servers.allSatisfy { !$0.isUsable } }
}

@MainActor
final class ICEServerConfig {
    static let shared = ICEServerConfig()

    /// Public STUN — always available. Enough for simulator/LAN, not for symmetric NAT.
    private let stun = RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])

    /// TURN relays, empty until the app configures them from backend-minted ephemeral
    /// credentials. No credentials live in source control.
    private var turn: [RTCIceServer] = []

    /// When the installed credentials stop being accepted by the relay. Past this the
    /// entries are dropped rather than handed to WebRTC, because a peer connection
    /// built with expired TURN credentials fails its allocation and quietly degrades to
    /// STUN-only anyway — better to know, and to re-fetch.
    private var expiresAt: Date?

    /// Set when the backend answered "no TURN configured", so an unprovisioned project
    /// isn't asked again on every single call.
    private var retryNoTurnAfter: Date?

    /// Coalesces concurrent refreshes — caller and callee legs of the same call, or two
    /// calls in quick succession, must not each mint their own credentials.
    private var refreshTask: Task<Void, Never>?

    /// Injected by the app layer (FirebaseSyncCoordinator) so this file stays free of
    /// any backend SDK, and so tests can supply credentials without a network.
    var credentialProvider: (() async throws -> TurnCredentials)?

    /// Re-fetch this long before the grant actually expires, so a call placed at the
    /// boundary doesn't start with credentials that die mid-handshake.
    private static let refreshSkew: TimeInterval = 60

    /// How long to take "TURN isn't configured" for an answer before asking again.
    private static let unconfiguredBackoff: TimeInterval = 600

    /// The full ICE server list handed to each RTCPeerConnection.
    func iceServers() -> [RTCIceServer] {
        dropExpiredTURN()
        return [stun] + turn
    }

    /// True once a TURN relay has been configured for this session and is still valid.
    var hasTURN: Bool {
        dropExpiredTURN()
        return !turn.isEmpty
    }

    /// Install a TURN relay from ephemeral credentials fetched from your backend.
    /// Example: `ICEServerConfig.shared.setTURN(urls: ["turn:turn.inditalk.com:3478"],
    ///                                          username: shortLived.user, credential: shortLived.pass)`
    func setTURN(urls: [String], username: String, credential: String,
                 expiresAt: Date = .distantFuture) {
        apply(TurnCredentials(
            servers: [TurnServer(urls: urls, username: username, credential: credential)],
            expiresAt: expiresAt))
    }

    /// Install a whole backend grant (possibly several relays, e.g. UDP + TCP + TLS).
    func apply(_ credentials: TurnCredentials) {
        let usable = credentials.servers.filter(\.isUsable)
        guard !usable.isEmpty else { return }
        turn = usable.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        expiresAt = credentials.expiresAt
        retryNoTurnAfter = nil
    }

    /// Clear TURN config (e.g. on sign-out or when credentials expire).
    func clearTURN() {
        turn = []
        expiresAt = nil
        retryNoTurnAfter = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Ensure valid TURN credentials are installed before a peer connection is built.
    ///
    /// MUST be awaited before `RTCPeerConnection` is created: WebRTC snapshots
    /// `RTCConfiguration.iceServers` at construction time, so a relay installed after
    /// that is never used by that call. Never throws and never blocks indefinitely —
    /// a backend that is slow, broken, or simply has no TURN provider leaves the app on
    /// STUN, which is the documented fallback, not an error.
    func refreshIfNeeded() async {
        dropExpiredTURN()
        if !turn.isEmpty { return }                       // still valid
        if let retryNoTurnAfter, Date() < retryNoTurnAfter { return }
        guard let credentialProvider else { return }      // no backend wired (local/tests)

        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            do {
                let credentials = try await credentialProvider()
                guard let self else { return }
                if credentials.isEmpty {
                    print("[Inditalk call] backend reports no TURN relay configured — "
                          + "TURN unavailable; continuing with STUN only")
                    self.retryNoTurnAfter = Date().addingTimeInterval(Self.unconfiguredBackoff)
                } else {
                    self.apply(credentials)
                    let urls = credentials.servers.flatMap(\.urls)
                    // URLs and lifetime only — never the username or credential, which are
                    // live relay authentication for the length of the grant.
                    print("[Inditalk call] TURN configured: \(urls.count) relay URL(s), "
                          + "valid for \(Int(credentials.expiresAt.timeIntervalSinceNow))s")
                }
            } catch {
                // Losing TURN degrades reachability; it does not break the call.
                print("[Inditalk call] TURN credential fetch failed — "
                      + "TURN unavailable; continuing with STUN only (\(error.localizedDescription))")
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Expired credentials are worse than none: WebRTC keeps trying an allocation the
    /// relay refuses. Drop them so `iceServers()` is always honest and the next
    /// `refreshIfNeeded()` mints a fresh grant.
    private func dropExpiredTURN() {
        guard !turn.isEmpty, let expiresAt else { return }
        if Date().addingTimeInterval(Self.refreshSkew) >= expiresAt {
            print("[Inditalk call] TURN credentials expired — dropping until refreshed")
            turn = []
            self.expiresAt = nil
        }
    }
}
