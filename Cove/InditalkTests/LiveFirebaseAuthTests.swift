//
//  LiveFirebaseAuthTests.swift
//  InditalkTests
//
//  INTEGRATION tests that hit the REAL Firebase project (cove-7f31f). They prove the
//  phone-auth path actually works end to end — something no amount of mocking can
//  establish — using the console-configured test phone numbers, which Firebase resolves
//  without sending an SMS or charging for verification.
//
//  OPT-IN ONLY. These are compiled out unless the INDITALK_LIVE_TESTS condition is set,
//  because they need network, mutate the live project (they create/refresh a
//  users/{uid} document for the test account), and would make the default suite
//  non-hermetic and flaky in CI.
//
//  A compile-time condition is used rather than an environment variable: app-hosted unit
//  tests run inside the Simulator and do not inherit the shell environment (neither a
//  plain env var nor xcodebuild's TEST_RUNNER_* prefix reaches them).
//
//  Run with:
//    xcodebuild build-for-testing -project Inditalk.xcodeproj -scheme Inditalk \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
//      SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) INDITALK_LIVE_TESTS'
//    xcodebuild test-without-building -project Inditalk.xcodeproj -scheme Inditalk \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
//      -only-testing:InditalkTests/LiveFirebaseAuthTests
//
//  Simulator only: app verification is disabled for testing there
//  (FirebaseAuthService.prepareForPhoneAuth), which is what lets test numbers bypass
//  APNs/reCAPTCHA.
//

import XCTest
import FirebaseAuth
@testable import Inditalk

@MainActor
final class LiveFirebaseAuthTests: XCTestCase {

    /// One of the console-configured test numbers and its fixed code.
    private let testPhone = "+16505553434"
    private let testCode = "123456"

    override func setUp() async throws {
        #if INDITALK_LIVE_TESTS
        // Start from a clean session so `verify` exercises a real sign-in.
        try? Auth.auth().signOut()
        #else
        throw XCTSkip("Live Firebase test — build with SWIFT_ACTIVE_COMPILATION_CONDITIONS=INDITALK_LIVE_TESTS to run.")
        #endif
    }

    override func tearDown() async throws {
        try? Auth.auth().signOut()
    }

    func testFirebaseIsConfiguredForTheExpectedProject() throws {
        XCTAssertNil(AppConfig.configurationProblem,
                     "GoogleService-Info.plist should be present and complete")
        XCTAssertEqual(AppConfig.projectID, "cove-7f31f")
    }

    /// The full path: request a code for a test number, verify it, and land signed in.
    /// A failure here means real users cannot sign in.
    func testPhoneSignInWithTestNumberSucceeds() async throws {
        let service = FirebaseAuthService.shared
        service.prepareForPhoneAuth()

        try await service.sendCode(to: testPhone)
        let uid = try await service.verify(code: testCode)

        XCTAssertFalse(uid.isEmpty, "sign-in should return a Firebase uid")
        XCTAssertTrue(service.isSignedIn)
        XCTAssertEqual(Auth.auth().currentUser?.phoneNumber, testPhone)
    }

    /// The uid must survive the round trip into the local identity the store adopts —
    /// this is what makes calling and the contact QR code address a real account.
    func testSignedInIdentityCarriesUIDAndPhone() async throws {
        let service = FirebaseAuthService.shared
        service.prepareForPhoneAuth()
        try await service.sendCode(to: testPhone)
        let uid = try await service.verify(code: testCode)

        let identity = try XCTUnwrap(service.localIdentity())
        XCTAssertEqual(identity.remoteUID, uid)
        XCTAssertEqual(identity.phoneNumber, testPhone)
        XCTAssertEqual(identity.id, FirebaseSyncCoordinator.stableUUID(uid),
                       "local id must be the deterministic hash of the uid")
    }

    /// Sign-in writes users/{uid}; the app must be able to read it back, which also
    /// exercises the deployed Firestore rules for an authenticated read.
    func testSignInCreatesReadableUserDocument() async throws {
        let service = FirebaseAuthService.shared
        service.prepareForPhoneAuth()
        try await service.sendCode(to: testPhone)
        let uid = try await service.verify(code: testCode)

        let remote = try await FirestoreService.shared.fetchUser(uid: uid)
        let profile = try XCTUnwrap(remote, "sign-in should have upserted users/\(uid)")
        XCTAssertEqual(profile.phone, testPhone)
    }

    /// A wrong code must fail cleanly with the mapped, user-facing error.
    func testWrongCodeIsRejected() async throws {
        let service = FirebaseAuthService.shared
        service.prepareForPhoneAuth()
        try await service.sendCode(to: testPhone)

        do {
            _ = try await service.verify(code: "654321")
            XCTFail("a wrong verification code should not sign in")
        } catch {
            XCTAssertFalse(service.isSignedIn)
            XCTAssertFalse(error.localizedDescription.isEmpty,
                           "the error must be presentable to the user")
        }
    }
}
