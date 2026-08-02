//
//  AccountDeletionService.swift
//  Inditalk
//
//  Implements the App-Store-required "delete your account" flow (Guideline 5.1.1(v)):
//  an in-app path that removes the account and its data, not just a link to a website.
//
//  Deletion runs in two layers:
//    1. Remote (only when AppConfig.usesFirebase): clear the push token, delete the
//       caller-owned Firestore docs the security rules allow (users/{uid} + its keys),
//       then delete the Firebase Auth user. Deleting the Auth user fires the
//       `onUserDeleted` Cloud Function (functions/index.js) which performs the deep,
//       admin-only cleanup the client can't do under the rules — removing the user from
//       shared chats, deleting their Storage objects, and pruning receipts/typing.
//    2. Local: wipe every on-device trace — SwiftData store, media files, Keychain
//       identity/prekeys, in-memory E2EE sessions, the report outbox, and the privacy
//       blob. This always runs, including in local (no-backend) mode.
//
//  REQUIRES the FirebaseAuth + FirebaseFirestore SPM packages (remote layer only runs
//  when Firebase is configured; the local wipe is backend-free).
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class AccountDeletionService {
    static let shared = AccountDeletionService()

    enum DeletionError: LocalizedError {
        case requiresRecentLogin
        case backend(String)

        var errorDescription: String? {
            switch self {
            case .requiresRecentLogin:
                return "For your security, please sign in again, then retry deleting your account."
            case .backend(let message):
                return "Couldn't delete your account: \(message)"
            }
        }
    }

    /// Full account deletion. Attempts the remote layer first (when configured); if that
    /// fails the local wipe is NOT run, so the user isn't signed out of a still-live
    /// account. On success the caller signs the session out.
    func deleteAccount(store: DataStore) async throws {
        try await deleteRemoteIfConfigured()
        wipeLocal(store: store)
    }

    private func deleteRemoteIfConfigured() async throws {
        guard AppConfig.usesFirebase, let user = Auth.auth().currentUser else { return }
        let uid = user.uid
        let db = Firestore.firestore()

        // Stop pushes to this device/account.
        try? await PushService.shared.clearToken()

        // Delete the caller-owned docs the rules permit (best-effort — the Cloud
        // Function reconciles anything left behind).
        try? await db.collection("users").document(uid).collection("keys").document("bundle").delete()
        try? await db.collection("users").document(uid).delete()

        // Delete the Firebase Auth user. This triggers the server-side cleanup function.
        do {
            try await user.delete()
        } catch {
            let ns = error as NSError
            // FIRAuthErrorCodeRequiresRecentLogin (17014) — stable public value; compared
            // numerically so this doesn't depend on FirebaseAuth's error-type shape.
            let requiresRecentLoginCode = 17014
            if ns.code == requiresRecentLoginCode {
                throw DeletionError.requiresRecentLogin
            }
            throw DeletionError.backend(ns.localizedDescription)
        }
    }

    /// Erase all on-device state. Exposed separately so it can be unit-tested with an
    /// in-memory store without touching any backend.
    func wipeLocal(store: DataStore) {
        store.wipeAllLocalData()
        MediaStore.clearAll()
        IdentityKeyManager.shared.deleteIdentity()
        E2EESessionStore.shared.clearAll()
        ChatPairKey.shared.clearAll()
        ReportStore.shared.clear()
    }
}
