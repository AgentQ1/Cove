//
//  OnboardingViewModelTests.swift
//  InditalkTests
//
//  Drives the phone/OTP onboarding state machine against a test-only stub provider:
//  request-code flow, wrong/right code verification, "wrong number?" reset, and the
//  resend cooldown gating.
//
//  The stub lives HERE, in the test target, not in the app. The shipping app has no
//  mock/demo auth provider at all — it always uses FirebaseAuthService.
//

import XCTest
@testable import Inditalk

#if DEBUG

/// Test double for the OTP backend. Accepts one fixed code so verification paths are
/// deterministic. Test-target only — never compiled into the app.
@MainActor
struct StubPhoneAuth: PhoneAuthenticating {
    static let acceptedCode = "424242"

    func sendCode(to phoneE164: String) async throws {
        try await Task.sleep(nanoseconds: 700_000_000)
    }

    @discardableResult
    func verify(code: String) async throws -> String {
        try await Task.sleep(nanoseconds: 300_000_000)
        guard code.filter(\.isNumber) == Self.acceptedCode else { throw AuthFailure.wrongCode }
        return "test-uid"
    }

    enum AuthFailure: LocalizedError {
        case wrongCode
        var errorDescription: String? { "That code didn't match. Check the SMS and try again." }
    }
}

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    private func makeVM() -> OnboardingViewModel {
        OnboardingViewModel(auth: StubPhoneAuth())
    }

    /// Poll on the main actor until `condition` holds or `timeout` elapses.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    /// Drive a VM through requestCode until it lands on the code step.
    private func advanceToCodeStep(_ vm: OnboardingViewModel) async {
        vm.step = .phone
        vm.phone = "4155550123"
        vm.requestCode()
        let arrived = await waitUntil { vm.step == .code }
        XCTAssertTrue(arrived, "requestCode should advance to the code step")
    }

    // MARK: Synchronous surface

    func testCanSendCodeEnforcesE164DigitBounds() {
        let vm = makeVM()
        vm.phone = "123456"                    // 6 digits — too short
        XCTAssertFalse(vm.canSendCode)
        vm.phone = "1234567"                   // 7 digits — minimum
        XCTAssertTrue(vm.canSendCode)
        vm.phone = "(415) 555-0123"            // formatting ignored, 10 digits
        XCTAssertTrue(vm.canSendCode)
        vm.phone = "123456789012345"           // 15 digits — maximum
        XCTAssertTrue(vm.canSendCode)
        vm.phone = "1234567890123456"          // 16 digits — too long
        XCTAssertFalse(vm.canSendCode)
    }

    func testRequestCodeRejectsInvalidPhoneSynchronously() {
        let vm = makeVM()
        vm.step = .phone
        vm.phone = "123"
        vm.requestCode()
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(vm.step, .phone, "invalid number never leaves the phone step")
        XCTAssertFalse(vm.isSending)
    }

    func testVerifyIgnoresIncompleteCode() {
        let vm = makeVM()
        vm.code = "4242"     // fewer than 6 digits
        var verified = false
        vm.verifyIfComplete { verified = true }
        XCTAssertFalse(vm.isVerifying, "incomplete code must not start verification")
        XCTAssertFalse(verified)
    }

    func testRetryCodeEntryClearsCodeAndError() {
        let vm = makeVM()
        vm.code = "111111"
        vm.error = "bad code"
        vm.retryCodeEntry()
        XCTAssertEqual(vm.code, "")
        XCTAssertNil(vm.error)
    }

    // MARK: Request code flow

    func testRequestCodeAdvancesToCodeStepAndStartsCooldown() async {
        let vm = makeVM()
        await advanceToCodeStep(vm)

        XCTAssertFalse(vm.isSending)
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.code, "", "code field starts empty on arrival")
        XCTAssertGreaterThan(vm.secondsUntilResend, 0, "cooldown starts immediately")
        XCTAssertFalse(vm.canResend)
        // Cooldown starts at 30; allow one tick of scheduling slack.
        XCTAssertTrue(["0:30", "0:29"].contains(vm.resendCountdownLabel),
                      "unexpected countdown label \(vm.resendCountdownLabel)")
    }

    func testResendIsGatedDuringCooldown() async {
        let vm = makeVM()
        await advanceToCodeStep(vm)
        XCTAssertFalse(vm.canResend)

        vm.resend()
        XCTAssertFalse(vm.isSending, "resend during cooldown must be a synchronous no-op")
        XCTAssertGreaterThan(vm.secondsUntilResend, 0, "cooldown untouched")
    }

    // MARK: Verification

    func testWrongCodeSetsErrorAndDoesNotVerify() async {
        let vm = makeVM()
        await advanceToCodeStep(vm)

        var verified = false
        vm.code = "111111"
        vm.verifyIfComplete { verified = true }
        XCTAssertTrue(vm.isVerifying)

        let failed = await waitUntil { vm.error != nil }
        XCTAssertTrue(failed, "wrong code should surface an error")
        XCTAssertFalse(verified)
        XCTAssertFalse(vm.isVerifying)
    }

    func testCorrectCodeCallsOnVerified() async {
        let vm = makeVM()
        await advanceToCodeStep(vm)

        var verified = false
        vm.code = "42 42 42"   // non-digits are filtered before verification
        vm.verifyIfComplete { verified = true }

        let done = await waitUntil { verified }
        XCTAssertTrue(done, "the accepted stub code should verify")
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isVerifying)
    }

    // MARK: Wrong number?

    func testEditNumberReturnsToPhoneClearingState() async {
        let vm = makeVM()
        await advanceToCodeStep(vm)
        vm.code = "123456"
        vm.error = "stale error"

        vm.editNumber()

        XCTAssertEqual(vm.step, .phone)
        XCTAssertEqual(vm.code, "")
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isVerifying)
        XCTAssertEqual(vm.secondsUntilResend, 0, "cooldown cancelled")
        XCTAssertTrue(vm.canResend)
    }
}

#endif
