//
//  TurnCredentialsService.swift
//  Inditalk
//
//  Fetches short-lived TURN credentials from the `getTurnCredentials` Cloud Function
//  (functions/turn.js) and shapes them into the backend-free `TurnCredentials` value
//  ICEServerConfig installs.
//
//  Why a callable function: TURN relays authenticate with an HMAC of a shared secret
//  that must stay server-side. The function mints a username/credential pair that stops
//  working within the hour, so a credential lifted off a device is worth almost nothing.
//  The callable also carries the Firebase ID token automatically, which is what stops
//  anyone from using Inditalk's relay bandwidth for free.
//
//  REQUIRES: FirebaseFunctions SPM package.
//

import Foundation
import FirebaseFunctions

@MainActor
final class TurnCredentialsService {
    static let shared = TurnCredentialsService()

    /// Must match `setGlobalOptions({ region: ... })` in functions/index.js — a region
    /// mismatch fails every call with NOT_FOUND.
    private let functions = Functions.functions(region: "us-central1")

    /// A call is waiting on this. Better to start on STUN than to sit on a dialing
    /// screen while an unreachable backend times out at the network default.
    private static let callTimeout: TimeInterval = 8

    enum TurnServiceError: LocalizedError {
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .malformedResponse: return "The TURN credential service returned an unexpected response."
            }
        }
    }

    /// Ask the backend for this session's relays. Throws on transport/auth failure;
    /// returns an EMPTY grant when the project simply has no TURN provider configured
    /// (a normal answer — the caller stays on STUN).
    func fetch() async throws -> TurnCredentials {
        let callable = functions.httpsCallable("getTurnCredentials")
        callable.timeoutInterval = Self.callTimeout
        let result = try await callable.call()
        guard let payload = result.data as? [String: Any] else {
            throw TurnServiceError.malformedResponse
        }
        return Self.parse(payload)
    }

    /// Map the function's JSON to the domain value. Split out (and `static`) so the
    /// parsing rules are unit-testable without Firebase or a network.
    ///
    /// Expected shape:
    ///   { "iceServers": [{ "urls": [...], "username": "...", "credential": "..." }],
    ///     "ttlSeconds": 3600, "expiresAt": 1700003600 }
    static func parse(_ payload: [String: Any], now: Date = Date()) -> TurnCredentials {
        let rawServers = payload["iceServers"] as? [[String: Any]] ?? []
        let servers: [TurnServer] = rawServers.compactMap { entry in
            // `urls` is an array per the function, but the WebRTC/JSON convention also
            // allows a bare string — accept both rather than silently dropping a relay.
            let raw = (entry["urls"] as? [String]) ?? (entry["urls"] as? String).map { [$0] } ?? []
            // Drop anything that isn't a relay URL WebRTC will accept. libwebrtc rejects
            // the ENTIRE RTCIceServer entry when one of its URLs is malformed, so a single
            // typo in the backend's TURN_URLS would otherwise cost every relay in the
            // grant — a call that quietly falls back to STUN with no error anywhere.
            let urls = raw.filter { isValidICEURL($0) }
            if urls.count != raw.count {
                print("[Inditalk call] ignoring \(raw.count - urls.count) malformed relay URL(s) from the backend")
            }
            guard let username = entry["username"] as? String,
                  let credential = entry["credential"] as? String else { return nil }
            let server = TurnServer(urls: urls, username: username, credential: credential)
            return server.isUsable ? server : nil
        }

        // Prefer the server's absolute expiry (immune to device clock drift relative to
        // the TTL countdown); fall back to now + ttl, then to a conservative minute.
        let expiresAt: Date
        if let absolute = payload["expiresAt"] as? Double, absolute > 0 {
            expiresAt = Date(timeIntervalSince1970: absolute)
        } else if let ttl = payload["ttlSeconds"] as? Double, ttl > 0 {
            expiresAt = now.addingTimeInterval(ttl)
        } else {
            expiresAt = now.addingTimeInterval(60)
        }
        return TurnCredentials(servers: servers, expiresAt: expiresAt)
    }

    /// `turn:`/`turns:`/`stun:` + host, optional `:port`, optional `?transport=udp|tcp`.
    /// Mirrors the validation `functions/turn.js` applies to TURN_URLS — the client
    /// repeats it because the backend is not the only thing that can put a bad string in
    /// front of WebRTC (a rolled-back function, a hand-edited config).
    static func isValidICEURL(_ url: String) -> Bool {
        let pattern = #"^(turn|turns|stun|stuns):[A-Za-z0-9._-]+(:\d{1,5})?(\?transport=(udp|tcp))?$"#
        return url.range(of: pattern, options: .regularExpression) != nil
    }
}
