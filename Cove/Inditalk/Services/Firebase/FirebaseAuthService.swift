//
//  FirebaseAuthService.swift
//  Inditalk
//
//  Phone-number authentication via Firebase Auth. Firebase issues and verifies the
//  SMS OTP itself, so the custom /v1/auth/otp REST contract from PHASE3 is NOT used
//  in the Firebase deployment — this service supersedes it. All Firebase imports
//  stay inside this file; callers see only PhoneAuthenticating + LocalizedErrors.
//
//  REQUIRES: FirebaseAuth SPM package + Phone provider enabled in the Firebase
//  console (Authentication → Sign-in method → Phone), and an APNs auth key uploaded
//  for silent-push verification.
//

import Foundation
import FirebaseAuth

@MainActor
final class FirebaseAuthService: ObservableObject, PhoneAuthenticating {
    static let shared = FirebaseAuthService()

    @Published private(set) var uid: String?

    private var verificationID: String?

    init() { uid = Auth.auth().currentUser?.uid }

    var isSignedIn: Bool { Auth.auth().currentUser != nil }

    /// Backend-free projection of the signed-in account for `DataStore.adoptIdentity`.
    /// The domain UUID is derived deterministically from the Firebase uid so the local
    /// "me" row matches the sender id on our own messages coming back from Firestore.
    func localIdentity() -> DataStore.LocalIdentity? {
        guard let user = Auth.auth().currentUser else { return nil }
        return DataStore.LocalIdentity(
            id: FirebaseSyncCoordinator.stableUUID(user.uid),
            displayName: user.displayName ?? "",
            phoneNumber: user.phoneNumber ?? "",
            remoteUID: user.uid
        )
    }

    /// Route any auth callback URL back to Firebase Auth. Wired to the app's `.onOpenURL`.
    ///
    /// Currently a no-op in practice: device sign-in verifies silently over APNs and the
    /// Simulator uses test numbers (see `prepareForPhoneAuth`), so no reCAPTCHA redirect
    /// occurs. Kept wired so that adding an OAuth client — and its REVERSED_CLIENT_ID URL
    /// scheme to Info.plist — makes the web fallback work without further code changes.
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool { Auth.auth().canHandle(url) }

    /// Forward the APNs device token so Firebase can silent-push the verification code.
    func setAPNSToken(_ deviceToken: Data) {
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
    }

    /// Hand a received remote notification to FirebaseAuth.
    ///
    /// Phone auth verifies the app by sending it a SILENT push and waiting for the app to
    /// hand that push back. If it never arrives, `verifyPhoneNumber` fails with
    /// ERROR_NOTIFICATION_NOT_FORWARDED (17054) and sign-in is impossible.
    ///
    /// Firebase's app-delegate swizzling normally does this invisibly, but relying on it
    /// is fragile — it is disabled by `FirebaseAppDelegateProxyEnabled = NO`, and does not
    /// reliably apply when the delegate is driven by SwiftUI's
    /// `@UIApplicationDelegateAdaptor` or hosted in a test runner. Forwarding explicitly
    /// makes sign-in work in every one of those cases.
    ///
    /// - Returns: true when the push was an Auth verification push and was consumed.
    func canHandleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        Auth.auth().canHandleNotification(userInfo)
    }

    /// Step 1 — send the SMS code. `phoneE164` must be full international format,
    /// e.g. "+14155550102".
    func sendCode(to phoneE164: String) async throws {
        do {
            let id = try await PhoneAuthProvider.provider().verifyPhoneNumber(phoneE164, uiDelegate: nil)
            verificationID = id
        } catch {
            throw Self.friendlyError(error)
        }
    }

    /// Configure app verification before any sign-in attempt. Called once at launch.
    ///
    /// Verification normally happens silently over APNs (token forwarded by
    /// `setAPNSToken`, push forwarded by `canHandleNotification`). Disabling app
    /// verification lets the Simulator use console-configured *test* phone numbers
    /// directly, which is faster and avoids depending on Simulator push behaviour that
    /// varies by host OS and Xcode version. A non-test number then fails with a normal
    /// error rather than hanging on a push that never arrives.
    ///
    /// Fenced to DEBUG + Simulator so it can never weaken verification in a shipping build.
    func prepareForPhoneAuth() {
        #if DEBUG && targetEnvironment(simulator)
        guard let settings = Auth.auth().settings else {
            print("[Inditalk auth] WARNING: Auth.settings was nil — app verification NOT disabled")
            return
        }
        settings.isAppVerificationDisabledForTesting = true
        #endif
    }

    /// Step 2 — verify the 6-digit code and sign in. Returns the Firebase uid.
    @discardableResult
    func verify(code: String) async throws -> String {
        guard let verificationID else { throw PhoneAuthError.missingVerificationID }
        let credential = PhoneAuthProvider.provider().credential(
            withVerificationID: verificationID, verificationCode: code)
        do {
            let result = try await Auth.auth().signIn(with: credential)
            uid = result.user.uid
            // Ensure a user document exists / is refreshed on first sign-in.
            try? await FirestoreService.shared.upsertCurrentUserProfile(
                displayName: result.user.displayName ?? "Inditalk user",
                phone: result.user.phoneNumber ?? phoneNumberFallback())
            return result.user.uid
        } catch {
            throw Self.friendlyError(error)
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
        uid = nil
        verificationID = nil
    }

    private func phoneNumberFallback() -> String { Auth.auth().currentUser?.phoneNumber ?? "" }

    // MARK: - Error mapping

    /// Translates raw FirebaseAuth NSErrors into human-readable LocalizedErrors so
    /// the view model can surface `error.localizedDescription` directly.
    private static func friendlyError(_ error: Error) -> Error {
        let nsError = error as NSError
        #if DEBUG
        // The mapped message is deliberately non-technical, which makes an unmapped code
        // invisible. Log the raw error so a "Something went wrong" is diagnosable.
        print("[Inditalk auth] raw error domain=\(nsError.domain) code=\(nsError.code) "
              + "desc=\(nsError.localizedDescription) info=\(nsError.userInfo)")
        #endif
        guard nsError.domain == AuthErrorDomain,
              let code = AuthErrorCode(rawValue: nsError.code) else {
            return PhoneAuthError.unknown
        }
        switch code {
        case .invalidPhoneNumber, .missingPhoneNumber:
            return PhoneAuthError.invalidPhoneNumber
        case .invalidVerificationCode:
            return PhoneAuthError.invalidVerificationCode
        case .sessionExpired:
            return PhoneAuthError.sessionExpired
        case .quotaExceeded, .tooManyRequests:
            return PhoneAuthError.quotaExceeded
        case .networkError:
            return PhoneAuthError.networkError
        case .captchaCheckFailed:
            return PhoneAuthError.captchaCheckFailed
        case .operationNotAllowed:
            // Covers both "Phone provider disabled" and "this SMS region is not allowed"
            // (Authentication → Settings → SMS region policy). Both are project
            // configuration, not anything the person signing in can fix.
            return PhoneAuthError.phoneSignInNotAllowed
        default:
            return PhoneAuthError.unknown
        }
    }

    enum PhoneAuthError: LocalizedError {
        case missingVerificationID
        case invalidPhoneNumber
        case invalidVerificationCode
        case sessionExpired
        case quotaExceeded
        case networkError
        case captchaCheckFailed
        case phoneSignInNotAllowed
        case unknown

        var errorDescription: String? {
            switch self {
            case .missingVerificationID:
                return "Request a code before verifying."
            case .invalidPhoneNumber:
                return "That phone number doesn't look right. Check the country code and number."
            case .invalidVerificationCode:
                return "That code didn't match. Check the SMS and try again."
            case .sessionExpired:
                return "This code has expired. Tap Resend to get a new one."
            case .quotaExceeded:
                return "Too many attempts right now. Please wait a few minutes and try again."
            case .networkError:
                return "No connection. Check your internet and try again."
            case .captchaCheckFailed:
                return "We couldn't complete the security check. Try sending the code again."
            case .phoneSignInNotAllowed:
                return "Inditalk can't send an SMS to this number's region yet. If you're testing this build, enable the region under Firebase → Authentication → Settings → SMS region policy."
            case .unknown:
                return "Something went wrong. Please try again."
            }
        }
    }
}
