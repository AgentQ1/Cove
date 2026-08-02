//
//  TurnCredentialsTests.swift
//  InditalkTests
//
//  Covers the TURN half of NAT traversal: how the backend's response is parsed, and how
//  ICEServerConfig decides what WebRTC is handed. The failure this guards against is
//  quiet — a call that works on office Wi-Fi and never connects on cellular — so the
//  rules that decide "TURN or not" are worth pinning down.
//

import XCTest
@testable import Inditalk

/// Records how often the credential provider was asked, and what to answer. An actor
/// because the provider closure is called from a non-isolated async context.
private actor ProviderSpy {
    private(set) var calls = 0
    private var result: Result<TurnCredentials, Error>
    private var delay: UInt64

    init(_ result: Result<TurnCredentials, Error>, delayNanos: UInt64 = 0) {
        self.result = result
        self.delay = delayNanos
    }

    func provide() async throws -> TurnCredentials {
        calls += 1
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return try result.get()
    }

    func callCount() -> Int { calls }
}

private struct ProviderError: Error {}

@MainActor
final class TurnCredentialsTests: XCTestCase {

    // The async overrides inherit this class's @MainActor isolation; the synchronous
    // setUp()/tearDown() do not, which made every ICEServerConfig touch below a
    // cross-actor access warning.
    override func setUp() async throws {
        try await super.setUp()
        // ICEServerConfig is a session-wide singleton; every test starts from nothing.
        ICEServerConfig.shared.clearTURN()
        ICEServerConfig.shared.credentialProvider = nil
    }

    override func tearDown() async throws {
        ICEServerConfig.shared.clearTURN()
        ICEServerConfig.shared.credentialProvider = nil
        try await super.tearDown()
    }

    private func grant(expiresIn seconds: TimeInterval, urls: [String] = ["turn:relay.test:3478"]) -> TurnCredentials {
        TurnCredentials(
            servers: [TurnServer(urls: urls, username: "1700000000:uid", credential: "hmac")],
            expiresAt: Date().addingTimeInterval(seconds))
    }

    // MARK: Response parsing

    func testParsesTheCloudFunctionResponse() {
        let credentials = TurnCredentialsService.parse([
            "iceServers": [[
                "urls": ["turn:relay.test:3478?transport=udp", "turns:relay.test:5349?transport=tcp"],
                "username": "1700003600:abc",
                "credential": "base64hmac",
            ]],
            "ttlSeconds": 3600.0,
            "expiresAt": 1_700_003_600.0,
        ])

        XCTAssertEqual(credentials.servers.count, 1)
        XCTAssertEqual(credentials.servers[0].urls.count, 2)
        XCTAssertEqual(credentials.servers[0].username, "1700003600:abc")
        XCTAssertEqual(credentials.servers[0].credential, "base64hmac")
        // The server's absolute expiry wins over the TTL countdown: it is immune to a
        // device clock that disagrees about how long a second is.
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_700_003_600))
    }

    func testParseFallsBackToTTLWhenAbsoluteExpiryIsMissing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let credentials = TurnCredentialsService.parse([
            "iceServers": [["urls": ["turn:relay.test:3478"], "username": "u", "credential": "c"]],
            "ttlSeconds": 600.0,
        ], now: now)

        XCTAssertEqual(credentials.expiresAt, now.addingTimeInterval(600))
    }

    func testParseAcceptsASingleUrlString() {
        // WebRTC's own JSON convention allows `urls` to be a bare string; dropping such
        // an entry would silently lose the only relay we were given.
        let credentials = TurnCredentialsService.parse([
            "iceServers": [["urls": "turn:relay.test:3478", "username": "u", "credential": "c"]],
            "ttlSeconds": 600.0,
        ])
        XCTAssertEqual(credentials.servers.first?.urls, ["turn:relay.test:3478"])
    }

    func testParseDropsIncompleteServersAndReportsUnconfigured() {
        // A relay without credentials is unusable — better an honest empty grant (which
        // means "stay on STUN") than an entry WebRTC will fail an allocation against.
        let credentials = TurnCredentialsService.parse([
            "iceServers": [
                ["urls": ["turn:relay.test:3478"]],                       // no credentials
                ["urls": [], "username": "u", "credential": "c"],         // no URLs
            ],
            "ttlSeconds": 600.0,
        ])
        XCTAssertTrue(credentials.isEmpty)

        // An unprovisioned backend answers with no servers at all.
        XCTAssertTrue(TurnCredentialsService.parse(["iceServers": [], "ttlSeconds": 0.0]).isEmpty)
    }

    func testParseDropsMalformedURLsButKeepsTheUsableOnes() {
        // libwebrtc rejects the whole RTCIceServer entry if any one of its URLs is
        // unparseable, so a single bad string from the backend would cost the entire
        // relay set — and the only symptom is a call that quietly stays on STUN.
        let credentials = TurnCredentialsService.parse([
            "iceServers": [[
                "urls": ["turn:relay.test:3478?transport=udp",
                         "https://relay.test",          // not an ICE scheme
                         "turn:user:pass@relay.test",   // credentials belong in the fields
                         "turns:relay.test:5349?transport=tcp"],
                "username": "u",
                "credential": "c",
            ]],
            "ttlSeconds": 600.0,
        ])

        XCTAssertEqual(credentials.servers.first?.urls,
                       ["turn:relay.test:3478?transport=udp", "turns:relay.test:5349?transport=tcp"])
    }

    func testParseTreatsAnEntirelyMalformedGrantAsUnconfigured() {
        // Nothing usable is the same situation as "no relay provisioned": stay on STUN
        // rather than hand WebRTC an entry it will fail an allocation against.
        let credentials = TurnCredentialsService.parse([
            "iceServers": [["urls": ["not a url", "ftp://relay.test"], "username": "u", "credential": "c"]],
            "ttlSeconds": 600.0,
        ])
        XCTAssertTrue(credentials.isEmpty)
    }

    func testICEURLValidationAcceptsEveryShapeTheBackendCanIssue() {
        for url in ["turn:relay.test", "turn:relay.test:3478", "turn:relay.test:3478?transport=udp",
                    "turn:relay.test:3478?transport=tcp", "turns:relay.test:5349?transport=tcp",
                    "stun:stun.l.google.com:19302", "turn:127.0.0.1:3478"] {
            XCTAssertTrue(TurnCredentialsService.isValidICEURL(url), "\(url) should be accepted")
        }
        for url in ["", "relay.test:3478", "https://relay.test", "turn:", "turn:relay.test:3478?transport=sctp",
                    "turn:relay.test:3478 ; rm -rf /"] {
            XCTAssertFalse(TurnCredentialsService.isValidICEURL(url), "\(url) should be rejected")
        }
    }

    // MARK: ICEServerConfig

    func testSTUNIsAlwaysPresentEvenWithoutTURN() {
        XCTAssertFalse(ICEServerConfig.shared.hasTURN)
        XCTAssertEqual(ICEServerConfig.shared.iceServers().count, 1)
    }

    func testApplyingAGrantAddsTURNAlongsideSTUN() {
        ICEServerConfig.shared.apply(grant(expiresIn: 3600))
        XCTAssertTrue(ICEServerConfig.shared.hasTURN)
        XCTAssertEqual(ICEServerConfig.shared.iceServers().count, 2)
    }

    func testExpiredCredentialsAreDroppedRatherThanHandedToWebRTC() {
        // Expired credentials are worse than none: WebRTC keeps retrying an allocation
        // the relay refuses, and the call stalls instead of falling back cleanly.
        ICEServerConfig.shared.apply(grant(expiresIn: -1))
        XCTAssertFalse(ICEServerConfig.shared.hasTURN)
        XCTAssertEqual(ICEServerConfig.shared.iceServers().count, 1)
    }

    func testCredentialsExpiringWithinTheRefreshSkewAreTreatedAsExpired() {
        // A grant with 10 seconds left would die mid-handshake; treat it as gone so the
        // next refresh mints a usable one.
        ICEServerConfig.shared.apply(grant(expiresIn: 10))
        XCTAssertFalse(ICEServerConfig.shared.hasTURN)
    }

    func testLegacySetTURNStillInstallsARelay() {
        ICEServerConfig.shared.setTURN(urls: ["turn:relay.test:3478"],
                                       username: "user", credential: "pass")
        XCTAssertTrue(ICEServerConfig.shared.hasTURN)
        // Empty credentials must never install a broken entry.
        ICEServerConfig.shared.clearTURN()
        ICEServerConfig.shared.setTURN(urls: [], username: "user", credential: "pass")
        XCTAssertFalse(ICEServerConfig.shared.hasTURN)
    }

    // MARK: refreshIfNeeded

    func testRefreshInstallsCredentialsFromTheProvider() async {
        let spy = ProviderSpy(.success(grant(expiresIn: 3600)))
        ICEServerConfig.shared.credentialProvider = { try await spy.provide() }

        await ICEServerConfig.shared.refreshIfNeeded()

        XCTAssertTrue(ICEServerConfig.shared.hasTURN)
        let calls = await spy.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testRefreshIsSkippedWhileCredentialsAreStillValid() async {
        let spy = ProviderSpy(.success(grant(expiresIn: 3600)))
        ICEServerConfig.shared.credentialProvider = { try await spy.provide() }

        await ICEServerConfig.shared.refreshIfNeeded()
        await ICEServerConfig.shared.refreshIfNeeded()

        // Every call would otherwise mint a new grant — wasted round trips on the
        // dialing screen, where latency is most visible.
        let calls = await spy.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testProviderFailureLeavesTheAppOnSTUNAndRetriesNextTime() async {
        let spy = ProviderSpy(.failure(ProviderError()))
        ICEServerConfig.shared.credentialProvider = { try await spy.provide() }

        await ICEServerConfig.shared.refreshIfNeeded()

        // The call must still be placeable — degraded reachability, not a dead call.
        XCTAssertFalse(ICEServerConfig.shared.hasTURN)
        XCTAssertEqual(ICEServerConfig.shared.iceServers().count, 1)

        // A transient failure (offline, cold function) is worth retrying immediately.
        await ICEServerConfig.shared.refreshIfNeeded()
        let calls = await spy.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testUnconfiguredBackendIsNotAskedAgainOnEveryCall() async {
        // An empty grant is a real answer ("this project has no TURN provider"), not an
        // error — so it is cached, unlike a failure.
        let spy = ProviderSpy(.success(.none))
        ICEServerConfig.shared.credentialProvider = { try await spy.provide() }

        await ICEServerConfig.shared.refreshIfNeeded()
        await ICEServerConfig.shared.refreshIfNeeded()

        XCTAssertFalse(ICEServerConfig.shared.hasTURN)
        let calls = await spy.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testConcurrentRefreshesShareOneFetch() async {
        // The caller and callee legs of a call — or two calls in a row — must not each
        // mint their own credentials.
        let spy = ProviderSpy(.success(grant(expiresIn: 3600)), delayNanos: 50_000_000)
        ICEServerConfig.shared.credentialProvider = { try await spy.provide() }

        async let first: Void = ICEServerConfig.shared.refreshIfNeeded()
        async let second: Void = ICEServerConfig.shared.refreshIfNeeded()
        async let third: Void = ICEServerConfig.shared.refreshIfNeeded()
        _ = await (first, second, third)

        XCTAssertTrue(ICEServerConfig.shared.hasTURN)
        let calls = await spy.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testRefreshWithoutAProviderIsAHarmlessNoOp() async {
        // Local/preview builds and tests never wire a backend; call setup must not
        // depend on one existing.
        await ICEServerConfig.shared.refreshIfNeeded()
        XCTAssertEqual(ICEServerConfig.shared.iceServers().count, 1)
    }

    func testClearTURNDropsAGrantOnSignOut() {
        ICEServerConfig.shared.apply(grant(expiresIn: 3600))
        ICEServerConfig.shared.clearTURN()
        XCTAssertFalse(ICEServerConfig.shared.hasTURN)
    }
}
