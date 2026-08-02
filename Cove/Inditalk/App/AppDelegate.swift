//
//  AppDelegate.swift
//  Inditalk
//
//  Bootstraps Firebase and push notifications. Wired into the SwiftUI lifecycle via
//  @UIApplicationDelegateAdaptor in InditalkApp.
//
//  REQUIRES the Firebase SPM packages (see README "Firebase setup"):
//    FirebaseCore, FirebaseAuth, FirebaseFirestore, FirebaseStorage, FirebaseMessaging
//  and a real GoogleService-Info.plist in the app target.
//

import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Guard so the app still launches (in local SwiftData mode) before you've
        // added the real GoogleService-Info.plist. Once the plist is present,
        // Firebase configures and the live backend is active.
        if AppConfig.isFirebaseConfigured {
            FirebaseApp.configure()
            Messaging.messaging().delegate = self
            UNUserNotificationCenter.current().delegate = self
            FirebaseAuthService.shared.prepareForPhoneAuth()

            // Register with APNs NOW, before sign-in. Phone auth verifies the device with
            // a silent push, so FirebaseAuth needs the APNs token during onboarding — and
            // registering is what produces it. This does NOT prompt the user: only
            // requestAuthorization (below, post-sign-in) shows a permission dialog.
            application.registerForRemoteNotifications()

            // PushKit registration must also happen at LAUNCH, not after sign-in: the
            // app can be launched *by* a VoIP push (locked phone, app not running), and
            // the registry only delivers that push if its delegate is already set. The
            // token it produces is cached by PushService and published once there is a
            // signed-in user to attach it to. Also no user-facing prompt.
            VoIPPushHandler.shared.register()
        } else {
            // Not reachable in a shipping build: InditalkApp shows FirebaseSetupView instead.
            print("⚠️ Inditalk: Firebase is not configured — \(AppConfig.configurationProblem?.title ?? "unknown"). See README ‘Firebase setup’.")
        }
        return true
    }

    /// Ask for notification *permission* (call after sign-in, when the value is
    /// explainable to the user). APNs registration itself already happened at launch.
    func registerForPushNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    // APNs token -> hand to BOTH consumers:
    //   * FirebaseAuth, so phone-number sign-in can verify the app silently instead of
    //     falling back to a reCAPTCHA web flow;
    //   * FCM, so the server can address this device for message pushes.
    // Missing the Auth hand-off is silent: sign-in still "works" but degrades to
    // reCAPTCHA, which this project has no OAuth client to return from.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated {
            FirebaseAuthService.shared.setAPNSToken(deviceToken)
        }
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error)")
    }

    /// Silent/background pushes. Auth verification pushes MUST be forwarded to
    /// FirebaseAuth here or phone sign-in fails with ERROR_NOTIFICATION_NOT_FORWARDED —
    /// see FirebaseAuthService.canHandleNotification.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if FirebaseAuthService.shared.canHandleNotification(userInfo) {
            // Consumed by Auth's app-verification handshake; not an Inditalk message push.
            completionHandler(.noData)
            return
        }
        // Message nudges carry no content — the body is fetched and decrypted on-device
        // by the Firestore listeners, so there is nothing to do here yet.
        completionHandler(.noData)
    }
}

// MARK: - FCM token lifecycle

extension AppDelegate: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        // Persist the token on the signed-in user's document so the server can push.
        Task { try? await PushService.shared.registerToken(fcmToken) }
    }
}

// MARK: - Foreground notification presentation

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .badge, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        // Route taps into the relevant chat via a deep link (chatId in userInfo).
    }
}
