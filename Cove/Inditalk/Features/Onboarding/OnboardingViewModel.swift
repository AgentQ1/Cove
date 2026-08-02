//
//  OnboardingViewModel.swift
//  Inditalk
//
//  Drives the phone/OTP auth state machine against a `PhoneAuthenticating` provider.
//  The app injects exactly one provider: `FirebaseAuthService`, backed by real Firebase
//  phone auth. There is no mock/demo/offline provider — a build without Firebase never
//  reaches onboarding (InditalkApp shows FirebaseSetupView instead). Tests supply their own
//  double, so this view model still imports no backend SDK.
//

import Foundation
import Combine

/// Abstraction over an SMS/OTP auth backend. `@MainActor` so the main-actor
/// FirebaseAuthService satisfies it under Swift 6 strict concurrency.
@MainActor
protocol PhoneAuthenticating {
    func sendCode(to phoneE164: String) async throws
    @discardableResult func verify(code: String) async throws -> String   // returns user id/uid
}


/// One entry in the country-code picker.
struct CountryDialCode: Identifiable, Hashable {
    let name: String
    let code: String
    var id: String { code }
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step { case welcome, phone, code }

    static let resendCooldownSeconds = 30

    /// Common dial codes for the phone-entry picker.
    static let countryCodes: [CountryDialCode] = [
        .init(name: "United States / Canada", code: "+1"),
        .init(name: "United Kingdom", code: "+44"),
        .init(name: "India", code: "+91"),
        .init(name: "Australia", code: "+61"),
        .init(name: "Japan", code: "+81"),
        .init(name: "Germany", code: "+49"),
        .init(name: "France", code: "+33"),
        .init(name: "Brazil", code: "+55"),
        .init(name: "China", code: "+86"),
        .init(name: "United Arab Emirates", code: "+971"),
        .init(name: "Nigeria", code: "+234"),
    ]

    @Published var step: Step = .welcome
    @Published var countryCode = "+1"
    @Published var phone = ""
    @Published var code = ""
    @Published var isSending = false
    @Published var isVerifying = false
    @Published var error: String?
    @Published private(set) var secondsUntilResend = 0

    private let auth: PhoneAuthenticating
    private var cooldownTask: Task<Void, Never>?

    init(auth: PhoneAuthenticating) {
        self.auth = auth
    }

    /// A phone entered in full E.164 form (leading "+") bypasses the country picker,
    /// so users in countries outside the picker list can still sign up.
    private var isFullE164: Bool { phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") }

    /// 7–15 digits (ITU E.164 national-number bounds).
    var canSendCode: Bool { (7...15).contains(phone.filter(\.isNumber).count) }

    var canResend: Bool { secondsUntilResend == 0 && !isSending }

    /// "0:26"-style label for the resend countdown.
    var resendCountdownLabel: String {
        String(format: "%d:%02d", secondsUntilResend / 60, secondsUntilResend % 60)
    }

    /// The number the user verified, in E.164 — exposed so the caller can persist it
    /// onto the profile after sign-in.
    var verifiedPhoneE164: String { phoneE164 }

    /// Human-readable number for the "Sent to …" subtitle (respects full-E.164 entry).
    var enteredNumberDisplay: String { isFullE164 ? phone : "\(countryCode) \(phone)" }

    private var phoneE164: String {
        isFullE164 ? "+" + phone.filter(\.isNumber) : countryCode + phone.filter(\.isNumber)
    }

    func requestCode() {
        error = nil
        guard canSendCode else { error = "Enter a valid phone number (7–15 digits)."; return }
        isSending = true
        Task {
            do {
                try await auth.sendCode(to: phoneE164)
                isSending = false
                code = ""
                step = .code
                startResendCooldown()
            } catch {
                isSending = false
                self.error = error.localizedDescription
            }
        }
    }

    /// Re-sends the SMS from the code screen; gated by the 30-second cooldown.
    func resend() {
        guard canResend else { return }
        error = nil
        isSending = true
        Task {
            do {
                try await auth.sendCode(to: phoneE164)
                isSending = false
                code = ""
                startResendCooldown()
            } catch {
                isSending = false
                self.error = error.localizedDescription
            }
        }
    }

    /// "Wrong number?" — back to the phone step, clearing code + error + cooldown.
    func editNumber() {
        cooldownTask?.cancel()
        cooldownTask = nil
        secondsUntilResend = 0
        code = ""
        error = nil
        isVerifying = false
        step = .phone
    }

    /// Clears a failed code so the user can retype ("Try again" affordance).
    func retryCodeEntry() {
        code = ""
        error = nil
    }

    func verifyIfComplete(_ onVerified: @escaping () -> Void) {
        // Cap at the first 6 digits so an over-long paste (e.g. a full SMS body) still
        // verifies instead of silently stalling on a != 6 count.
        let digits = String(code.filter(\.isNumber).prefix(6))
        guard digits.count == 6, !isVerifying else { return }
        isVerifying = true
        error = nil
        Task {
            do {
                _ = try await auth.verify(code: digits)
                isVerifying = false
                error = nil
                onVerified()
            } catch {
                isVerifying = false
                self.error = error.localizedDescription
            }
        }
    }

    private func startResendCooldown() {
        cooldownTask?.cancel()
        secondsUntilResend = Self.resendCooldownSeconds
        cooldownTask = Task { [weak self] in
            // Ticks once a second; exits when it hits zero, is cancelled, or the VM dies.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.secondsUntilResend > 0 { self.secondsUntilResend -= 1 }
                if self.secondsUntilResend == 0 { return }
            }
        }
    }
}
