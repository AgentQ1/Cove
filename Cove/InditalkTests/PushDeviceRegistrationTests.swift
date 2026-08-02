//
//  PushDeviceRegistrationTests.swift
//  InditalkTests
//
//  Covers the two rules that decide whether a locked phone rings at all, both of which
//  fail silently in production:
//
//    1. The APNs environment a device registers itself under. A token minted by a
//       development-entitled build is rejected by the production gateway (and vice
//       versa) with BadDeviceToken — no error reaches the app, the phone just stays
//       quiet. Recording it PER DEVICE is what lets a Debug install and a TestFlight
//       install of the same account both ring.
//    2. Publication of the block list. `onCallInvite` reads users/{uid}/blocked/{uid}
//       before pushing, and that server-side check is the only block enforcement that
//       exists when the callee's app is backgrounded or not running.
//

import XCTest
@testable import Inditalk

@MainActor
final class PushDeviceRegistrationTests: XCTestCase {

    // MARK: APNs environment

    /// Shaped like the real embedded.mobileprovision: a CMS-signed blob with a plain
    /// XML plist inside it, which is why the parser scans text rather than decoding.
    private func profile(apsEnvironment: String) -> String {
        """
        \u{01}\u{02}binary preamble\u{00}\u{03}
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>AppIDName</key><string>Inditalk</string>
            <key>Entitlements</key><dict>
                <key>application-identifier</key><string>TEAMID.chat.cove.app</string>
                <key>aps-environment</key>
                <string>\(apsEnvironment)</string>
                <key>get-task-allow</key><true/>
            </dict>
        </dict></plist>
        trailing signature bytes
        """
    }

    func testDevelopmentProfileRegistersAsSandbox() {
        XCTAssertEqual(
            PushService.apnsEnvironment(inProvisioningProfile: profile(apsEnvironment: "development")),
            "development")
    }

    func testProductionProfileRegistersAsProduction() {
        XCTAssertEqual(
            PushService.apnsEnvironment(inProvisioningProfile: profile(apsEnvironment: "production")),
            "production")
    }

    func testEnvironmentIsReadFromTheValueNotAnUnrelatedLaterMention() {
        // "production" appears further down the profile in an unrelated key. Matching it
        // would push every Debug device to the production host, where its token is
        // invalid — the exact silent failure this parser exists to prevent.
        let text = """
        <key>aps-environment</key>
        <string>development</string>
        <key>Name</key><string>Inditalk production distribution</string>
        """
        XCTAssertEqual(PushService.apnsEnvironment(inProvisioningProfile: text), "development")
    }

    func testMissingProfileFallsBackToTheBuildConfiguration() {
        // The Simulator has no embedded profile. project.yml pins Debug to the
        // development entitlement and Release to production, so the build configuration
        // is the correct fallback — and the tests themselves run under Debug.
        XCTAssertEqual(PushService.apnsEnvironment(inProvisioningProfile: nil), "development")
        XCTAssertEqual(PushService.apnsEnvironment(inProvisioningProfile: "no entitlements here"),
                       "development")
    }

    func testDeviceIdIsStableAcrossLookups() {
        // One document per install. A per-launch id would accumulate dead device
        // documents and push to every one of them on every call.
        XCTAssertFalse(PushService.deviceId.isEmpty)
        XCTAssertEqual(PushService.deviceId, PushService.deviceId)
    }

    // MARK: Block publication

    func testBlockingPublishesToTheBackend() {
        let store = DataStore.inMemory()
        let other = store.users.values.first { $0.id != store.currentUser.id }!

        var published: [(UUID, Bool)] = []
        store.blockSink = { userID, blocked in published.append((userID, blocked)) }

        store.block(other.id)
        store.unblock(other.id)

        XCTAssertEqual(published.map(\.1), [true, false],
                       "the server copy must follow both directions, or an unblocked "
                       + "contact stays unable to ring the user")
        XCTAssertEqual(published.map(\.0), [other.id, other.id])
    }

    func testBlockStateIsStillLocalWhenThereIsNoBackend() {
        // Local/preview mode has no sink; blocking must keep working exactly as before.
        let store = DataStore.inMemory()
        let other = store.users.values.first { $0.id != store.currentUser.id }!

        store.block(other.id)

        XCTAssertTrue(store.isBlocked(other.id))
    }
}
