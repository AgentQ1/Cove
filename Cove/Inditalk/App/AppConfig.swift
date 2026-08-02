//
//  AppConfig.swift
//  Inditalk
//
//  Runtime configuration. Firebase is the ONLY backend: there is no local, demo, or
//  mock mode. If the app is misconfigured we surface an explicit setup screen
//  (FirebaseSetupView) rather than silently degrading to fabricated data.
//

import Foundation

enum AppConfig {

    /// Describes exactly why Firebase can't be used, so the setup screen can tell a
    /// developer what to fix instead of the app quietly showing an empty/fake shell.
    enum ConfigurationProblem: Equatable {
        case missingPlist
        case malformedPlist(missingKeys: [String])

        var title: String {
            switch self {
            case .missingPlist: return "GoogleService-Info.plist not found"
            case .malformedPlist: return "GoogleService-Info.plist is incomplete"
            }
        }

        var detail: String {
            switch self {
            case .missingPlist:
                return """
                Inditalk requires a real Firebase configuration — it has no demo or offline mode.

                Download GoogleService-Info.plist for the iOS app (bundle id chat.cove.app) \
                from the Firebase console and place it at Inditalk/Resources/GoogleService-Info.plist, \
                then rebuild.
                """
            case .malformedPlist(let keys):
                return """
                The bundled GoogleService-Info.plist is missing required keys: \
                \(keys.joined(separator: ", ")).

                Re-download it from the Firebase console for bundle id chat.cove.app and rebuild.
                """
            }
        }
    }

    /// Keys Firebase needs before `FirebaseApp.configure()` can produce a working app.
    private static let requiredPlistKeys = ["API_KEY", "GCM_SENDER_ID", "GOOGLE_APP_ID", "PROJECT_ID", "BUNDLE_ID"]

    private static let plistPath: String? = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")

    /// `nil` when Firebase is properly configured; otherwise the reason it is not.
    static let configurationProblem: ConfigurationProblem? = {
        guard let path = plistPath else { return .missingPlist }
        guard let dict = NSDictionary(contentsOfFile: path) else {
            return .malformedPlist(missingKeys: requiredPlistKeys)
        }
        let missing = requiredPlistKeys.filter { key in
            guard let value = dict[key] as? String else { return true }
            return value.isEmpty
        }
        return missing.isEmpty ? nil : .malformedPlist(missingKeys: missing)
    }()

    /// True only when a real, complete GoogleService-Info.plist is present.
    static var isFirebaseConfigured: Bool { configurationProblem == nil }

    /// Whether live Firebase work should run. Firebase is mandatory, so this is simply
    /// "is the app configured" — retained as a named concept because call sites read
    /// better as `usesFirebase`.
    static var usesFirebase: Bool { isFirebaseConfigured }

    /// The Firebase project the bundled plist points at (for diagnostics / review notes).
    static var projectID: String? {
        guard let path = plistPath, let dict = NSDictionary(contentsOfFile: path) else { return nil }
        return dict["PROJECT_ID"] as? String
    }

}
