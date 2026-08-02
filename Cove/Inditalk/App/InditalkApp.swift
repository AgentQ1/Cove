//
//  InditalkApp.swift
//  Inditalk
//
//  App entry point. Owns the single DataStore and injects it into the environment.
//

import SwiftUI
import FirebaseAuth

@main
struct InditalkApp: App {
    // Bootstraps Firebase (FirebaseApp.configure) + push. Requires the Firebase SPM
    // packages + a real GoogleService-Info.plist — see README "Firebase setup".
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var store = DataStore()
    @StateObject private var session = AppSession()
    @StateObject private var coordinator = FirebaseSyncCoordinator()

    var body: some Scene {
        WindowGroup {
            Group {
                // Firebase is mandatory. Misconfiguration surfaces an explicit setup
                // screen rather than a shell full of fabricated data.
                if let problem = AppConfig.configurationProblem {
                    FirebaseSetupView(problem: problem)
                } else if session.isAuthenticated {
                    RootView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(store)
            .environmentObject(session)
            .environmentObject(coordinator)
            .inditalkToastHost()
            .tint(Palette.ink)
            // Firebase phone-auth reCAPTCHA/APNs callback (no-op in local mode).
            .onOpenURL { url in
                if AppConfig.usesFirebase { _ = FirebaseAuthService.shared.handleOpenURL(url) }
            }
            // Start/stop live Firestore sync + incoming-call listening with the auth
            // state. Both no-op in local mode (AppConfig.usesFirebase == false).
            .task(id: session.isAuthenticated) {
                if session.isAuthenticated {
                    // Bind the store to the REAL signed-in account before sync starts, so
                    // "me" is the Firebase user rather than a locally invented identity.
                    if let identity = FirebaseAuthService.shared.localIdentity() {
                        store.adoptIdentity(identity)
                    }
                    coordinator.start(store: store)
                    CallCenter.shared.startListening()
                    if AppConfig.usesFirebase {
                        appDelegate.registerForPushNotifications()
                        Task { try? await FirestoreService.shared.setPresence(online: true) }
                        // PushKit (and FCM) issue their tokens at launch — before sign-in
                        // on a fresh install — so publish the cached ones now that there
                        // is a user document to attach them to. Without this the first
                        // session after install never rings while backgrounded.
                        Task { try? await PushService.shared.publishAllTokens() }
                    }
                } else {
                    coordinator.stop()
                    CallCenter.shared.stopListening()
                }
            }
            // Mirror foreground/background into presence so contacts see "online"
            // accurately. Guarded: only meaningful with a live backend + session.
            .onChange(of: scenePhase) { _, phase in
                guard AppConfig.usesFirebase, session.isAuthenticated else { return }
                switch phase {
                case .active:
                    Task { try? await FirestoreService.shared.setPresence(online: true) }
                case .background:
                    Task { try? await FirestoreService.shared.setPresence(online: false) }
                default:
                    break
                }
            }
        }
    }
}

/// Tracks auth + top-level app session state. Firebase Auth's keychain session is the
/// ONLY source of truth — there is no local "pretend I'm signed in" flag, so a fresh
/// install always lands on onboarding and a signed-out account can never reach the app
/// shell.
@MainActor
final class AppSession: ObservableObject {
    @Published var isAuthenticated: Bool

    init() {
        isAuthenticated = AppConfig.usesFirebase && FirebaseAuthService.shared.isSignedIn
    }

    func completeSignIn() {
        // Trust Firebase, not the caller: only a real keychain session counts.
        isAuthenticated = FirebaseAuthService.shared.isSignedIn
    }

    /// How long the push-token deletion may hold the session open. Bounded because an
    /// offline device must never be stuck signed in waiting for a server ack that can't
    /// come; online it is one round trip.
    private static let tokenCleanupTimeout: Duration = .seconds(3)

    func signOut() {
        // Leave the app shell immediately — the session teardown finishes behind it, so
        // a slow network never looks like a stuck Sign Out button.
        isAuthenticated = false
        Task { await tearDownSession() }
    }

    /// End the Firebase session, taking this device's push tokens with it.
    ///
    /// Order matters and cannot be reversed: deleting
    /// `users/{uid}/privateDevices/{deviceId}` is authorized by `isSelf(uid)`, so it has
    /// to happen while the session is still live. Left behind, that document keeps the
    /// backend pushing calls at a phone nobody is signed in on — the app wakes, finds no
    /// signed-in user, and reports-then-ends a phantom ring.
    ///
    /// Best effort by design: if the deletion doesn't land inside `tokenCleanupTimeout`
    /// the sign-out proceeds anyway. A token that survives is replaced when the next
    /// account signs in on this device, and pruned by `onCallInvite` once APNs reports
    /// it dead.
    private func tearDownSession() async {
        let uid = Auth.auth().currentUser?.uid
        // Presence is independent best-effort and equally unblocking.
        Task { try? await FirestoreService.shared.setPresence(online: false) }

        if let uid {
            // Deliberately NOT a task group: a group awaits every child before it
            // returns, even after `cancelAll()`, and a Firestore write never completes
            // while the device is offline — the "timeout" would be no timeout at all.
            // Start the deletion, watch a flag, and move on when it lands or the deadline
            // passes; the straggler finishes (or doesn't) on its own.
            let cleanup = SignOutCleanup()
            Task {
                try? await PushService.shared.clearToken(uid: uid)
                cleanup.finished = true
            }
            let deadline = ContinuousClock.now.advanced(by: Self.tokenCleanupTimeout)
            while !cleanup.finished, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !cleanup.finished {
                print("[Inditalk push] sign-out: token cleanup didn't land in time — "
                      + "the device document may survive until the next registration")
            }
        }

        try? FirebaseAuthService.shared.signOut()
    }
}

/// One-bit completion flag for the bounded sign-out cleanup above. A `final class` so the
/// escaping task and the waiting loop share it; `@MainActor` so that sharing is safe.
@MainActor
private final class SignOutCleanup {
    var finished = false
}
