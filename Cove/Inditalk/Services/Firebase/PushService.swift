//
//  PushService.swift
//  Inditalk
//
//  Publishes this device's push tokens so the backend can reach it:
//    * the FCM token, for ordinary message pushes (functions/index.js), and
//    * the PushKit VoIP token, for incoming calls (functions/voip.js).
//
//  Because message bodies are E2EE, push payloads carry only a non-sensitive nudge
//  ("New message") plus the chatId; the app fetches + decrypts the actual content
//  locally. A Notification Service Extension can decrypt a preview on-device if desired.
//
//  WHERE THE TOKENS LIVE. Not on users/{uid} — that document is readable by every
//  signed-in user, and a push token is a stable per-install identifier. They live at
//  users/{uid}/privateDevices/{deviceId}, which firestore.rules restricts to the owner;
//  Cloud Functions read it with the Admin SDK, which bypasses rules. One document per
//  install also means a user signed in on two devices rings on both, instead of the
//  second registration overwriting the first.
//
//  REQUIRES: FirebaseMessaging SPM package + APNs auth key uploaded to the console.
//

import Foundation
import FirebaseMessaging
import FirebaseFirestore
import FirebaseAuth
import UIKit

@MainActor
final class PushService {
    static let shared = PushService()
    private let db = Firestore.firestore()

    /// Subcollection of `users/{uid}` holding one document per install. Owner-only in
    /// firestore.rules — see the file header.
    private static let devicesCollection = "privateDevices"

    /// Stable id for THIS install, so re-registering updates one document instead of
    /// accumulating one per launch. `identifierForVendor` changes when the last app from
    /// the vendor is uninstalled, which is exactly the moment the old token dies anyway;
    /// the generated fallback (stored alongside it) covers the rare nil case.
    static let deviceId: String = {
        let key = "cove.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    /// Which APNs host this build's tokens are valid against.
    ///
    /// APNs is environment-split: a token minted under `aps-environment=development` is
    /// rejected by the production gateway and vice versa, with `BadDeviceToken` and no
    /// client-side symptom at all. Recording it per device is what lets a Debug install
    /// and a TestFlight install of the same account both ring — a single server-side flag
    /// would silence whichever build didn't match it.
    ///
    /// Read from the embedded provisioning profile, which is the same entitlement APNs
    /// itself checks. The Simulator has no profile, so fall back to the build
    /// configuration (project.yml pins Debug -> development, Release -> production).
    static let apnsEnvironment: String = {
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        // The profile is CMS-signed; the embedded plist is plain XML inside it, so a
        // latin-1 decode of the whole file is enough to find the entitlement.
        let text = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { String(data: $0, encoding: .isoLatin1) }
        return apnsEnvironment(inProvisioningProfile: text)
    }()

    /// Split out from the `Bundle` lookup so the parsing rule is unit-testable: getting
    /// this wrong sends every push to the wrong APNs host, and the only symptom is a
    /// phone that never rings.
    static func apnsEnvironment(inProvisioningProfile text: String?) -> String {
        // No profile (the Simulator, or a build not signed for a device) or no
        // entitlement: fall back to the build configuration, which project.yml pins to
        // the same split — Debug -> Inditalk.entitlements = development, Release -> production.
        #if DEBUG
        let fallback = "development"
        #else
        let fallback = "production"
        #endif

        // Read the FIRST <string> value after the key, not a window of nearby text: a
        // profile mentions "production" in several unrelated places (profile name, team
        // name), and matching one of those would send a development build's tokens to the
        // production gateway, where every one of them is BadDeviceToken.
        guard let text,
              let key = text.range(of: "<key>aps-environment</key>"),
              let open = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex)
        else { return fallback }

        let value = text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "production" ? "production" : "development"
    }

    private var deviceRef: DocumentReference? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return db.collection("users").document(uid)
            .collection(Self.devicesCollection).document(Self.deviceId)
    }

    // MARK: FCM (message pushes)

    /// Store the FCM registration token for this device.
    func registerToken(_ token: String) async throws {
        fcmToken = token
        try await publish(["fcmToken": token])
    }

    /// Fetch the current token on demand (e.g. right after sign-in).
    func currentToken() async throws -> String {
        try await Messaging.messaging().token()
    }

    /// The most recent FCM token, cached for the same reason as the VoIP one: it can
    /// arrive before there is a signed-in user to store it against.
    private(set) var fcmToken: String?

    // MARK: VoIP (PushKit) token
    //
    // Separate from the FCM token on purpose: FCM cannot address a PushKit token, so
    // the `onCallInvite` Cloud Function talks to APNs directly using this one. Without
    // it stored, a backgrounded or locked device never rings.

    /// The most recent token PushKit handed us. Cached because PushKit issues it once
    /// per process — at launch, usually well BEFORE sign-in — so there is often no uid
    /// to store it against at the moment it arrives.
    private(set) var voipToken: String?

    /// Record a new (or revoked) VoIP token and publish it if we can.
    func setVoIPToken(_ token: String?) {
        voipToken = token
        Task { try? await publishVoIPToken() }
    }

    /// Write the cached VoIP token to this device's document. Safe to call repeatedly;
    /// call it again after sign-in, which is when the uid finally exists.
    func publishVoIPToken() async throws {
        guard let voipToken else {
            // Revoked: stop the backend pushing into a token APNs no longer honours.
            try await publish(["voipToken": FieldValue.delete()])
            return
        }
        try await publish(["voipToken": voipToken])
        print("[Inditalk push] VoIP token published for device \(Self.deviceId)")
    }

    /// Re-publish everything this device knows. Called after sign-in, when the tokens
    /// PushKit/FCM issued at launch finally have a user document to attach to.
    func publishAllTokens() async throws {
        var fields: [String: Any] = [:]
        if let voipToken { fields["voipToken"] = voipToken }
        if let fcmToken { fields["fcmToken"] = fcmToken }
        guard !fields.isEmpty else { return }
        try await publish(fields)
    }

    // MARK: Writing

    /// Merge `fields` into this device's document, always refreshing the metadata the
    /// backend needs to pick the right APNs host.
    private func publish(_ fields: [String: Any]) async throws {
        guard let deviceRef else { return }
        var data = fields
        data["platform"] = "ios"
        data["apnsEnvironment"] = Self.apnsEnvironment
        data["bundleId"] = Bundle.main.bundleIdentifier ?? "chat.cove.app"
        data["updatedAt"] = FieldValue.serverTimestamp()
        try await deviceRef.setData(data, merge: true)
        await clearLegacyProfileTokens()
    }

    /// Remove tokens written to the profile document by older builds.
    ///
    /// Those are readable by every signed-in user, so this is a migration AND a cleanup:
    /// the first publish from an updated app takes the token out of the world-readable
    /// document. The Cloud Functions read the profile only as a fallback, so the order
    /// (write the private doc, then clear the public one) never leaves a gap where the
    /// device is unreachable.
    private func clearLegacyProfileTokens() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let profile = db.collection("users").document(uid)
        guard let snapshot = try? await profile.getDocument(),
              snapshot.get("voipToken") != nil || snapshot.get("fcmToken") != nil else { return }
        try? await profile.updateData([
            "voipToken": FieldValue.delete(),
            "fcmToken": FieldValue.delete(),
        ])
        print("[Inditalk push] migrated legacy profile push tokens into privateDevices")
    }

    // MARK: Teardown

    /// Remove this device's tokens on sign-out so the backend stops pushing to a device
    /// nobody is signed in on.
    ///
    /// `uid` is passed explicitly because the caller has to run this BEFORE
    /// `Auth.signOut()` — afterwards the write is unauthenticated and the rules reject
    /// it, which is how a signed-out device keeps ringing.
    func clearToken(uid: String? = nil) async throws {
        guard let uid = uid ?? Auth.auth().currentUser?.uid else { return }
        // Delete the whole device document: nothing else on it is worth keeping for a
        // device that is no longer signed in.
        try await db.collection("users").document(uid)
            .collection(Self.devicesCollection).document(Self.deviceId).delete()
        // Older installs may still have tokens on the profile.
        try? await db.collection("users").document(uid).updateData([
            "fcmToken": FieldValue.delete(),
            "voipToken": FieldValue.delete(),
        ])
        voipToken = nil
        fcmToken = nil
        try await Messaging.messaging().deleteToken()
    }
}
