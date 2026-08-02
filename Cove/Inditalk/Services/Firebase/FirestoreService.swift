//
//  FirestoreService.swift
//  Inditalk
//
//  The Firebase Firestore messaging backend for Inditalk.
//
//  ⚠️ END-TO-END ENCRYPTION BOUNDARY: message *bodies* are stored as CIPHERTEXT only
//  (the `ciphertext` field), encrypted on-device by CryptoService before they ever
//  reach Firestore. The server (Google) can therefore NOT read message content. What
//  IS visible to the server is metadata: who is in a chat, message timestamps, sizes,
//  and read receipts. This matches the threat model in docs/PHASE5_ENCRYPTION.md.
//  Never write plaintext bodies here.
//
//  REQUIRES: FirebaseFirestore SPM package (v10+ for built-in Codable support).
//
//  Firestore layout:
//    users/{uid}
//    chats/{chatId}                         (participantIds, kind, lastActivity, …)
//    chats/{chatId}/messages/{messageId}    (senderId, kind, ciphertext, sentAt, …)
//    chats/{chatId}/receipts/{uid}          (lastReadMessageId, lastReadAt)
//    chats/{chatId}/reactions/{msgId_uid}   (messageId, uid, ciphertext, updatedAt)
//    chats/{chatId}/typing/{uid}            (isTyping, updatedAt)
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

// MARK: - Wire models (server-shaped; bodies are ciphertext)

struct RemoteUser: Codable {
    @DocumentID var id: String?
    var displayName: String
    var phone: String
    var about: String
    var avatarURL: String?
    var identityKey: String?     // base64 X25519 public identity key for E2EE
    // NOTE: push tokens are deliberately NOT here. This document is readable by every
    // signed-in user (contact discovery), and a push token is a stable per-install
    // identifier. They live at users/{uid}/privateDevices/{deviceId}, owner-only under
    // the rules — see PushService.swift and functions/devices.js.
    var isOnline: Bool
    @ServerTimestamp var lastSeen: Timestamp?
    /// The author's own visibility choices, published so a reader knows what it is
    /// allowed to show. Absent for profiles written before this existed — treated as
    /// "everyone", which is what those accounts were already doing.
    var privacy: RemotePrivacy?
}

/// Visibility choices as published on users/{uid}.privacy. Raw values match
/// `PrivacySettings.Visibility` ("everyone" | "contacts" | "nobody").
struct RemotePrivacy: Codable {
    var lastSeen: String?
    var profilePhoto: String?
    var about: String?
}

struct RemoteChat: Codable {
    @DocumentID var id: String?
    var kind: String
    var title: String
    var participantIds: [String]
    var adminIds: [String]
    var avatarURL: String?
    @ServerTimestamp var lastActivity: Timestamp?
    var disappearingSeconds: Int
}

struct RemoteMessage: Codable {
    @DocumentID var id: String?
    var senderId: String
    var kind: String
    var ciphertext: String        // base64 of CryptoService.seal(...) — never plaintext
    var replyTo: String?
    var deleted: Bool?            // sender tombstoned it ("delete for everyone")
    @ServerTimestamp var sentAt: Timestamp?
}

/// One participant's read position in a chat, at chats/{chatId}/receipts/{uid}.
/// Doc id is the reader's uid; `lastReadMessageId` is the newest message they've read.
struct RemoteReceipt: Codable {
    @DocumentID var id: String?           // reader uid
    var lastReadMessageId: String
    @ServerTimestamp var lastReadAt: Timestamp?
}

/// One user's emoji reaction to one message, at chats/{chatId}/reactions/{reactionId}.
///
/// Kept in a per-CHAT subcollection (rather than under the message) so a single
/// listener covers every reaction in the conversation — one listener per open message
/// would be hundreds of them. The composite doc id enforces the domain rule that a user
/// has at most one reaction per message: re-reacting overwrites, un-reacting deletes.
///
/// `ciphertext` is the emoji sealed with the chat's key — a reaction is user content
/// and gets the same treatment as a message body (see the E2EE note at the top of this
/// file). The server never sees which emoji was used.
struct RemoteReaction: Codable {
    @DocumentID var id: String?           // "{messageId}_{uid}"
    var messageId: String
    var uid: String
    var ciphertext: String
    @ServerTimestamp var updatedAt: Timestamp?
}

/// A published 24h status, stored at users/{uid}/statuses/{statusId}. Statuses are
/// BROADCAST to all of the author's contacts (like the profile photo/about, and unlike
/// 1:1 messages), so — matching those fields — the body is not pair-key E2EE; media
/// uploads plaintext to the owner-writable status/{uid}/ Storage folder.
struct RemoteStatus: Codable {
    @DocumentID var id: String?
    var kind: String              // StatusKind rawValue: text | photo | video
    var text: String              // body for text statuses, caption for media
    var paletteIndex: Int
    var mediaPath: String?        // Storage path of the photo/video, nil for text
    @ServerTimestamp var createdAt: Timestamp?
    var expiresAt: Timestamp
}

/// A view receipt at users/{authorUid}/statuses/{statusId}/views/{viewerUid} — one doc
/// per contact who watched the status (WhatsApp's "seen by" list). Doc id = viewer uid;
/// the viewer writes their own displayName so the author can render the list without a
/// profile fetch.
struct RemoteStatusView: Codable {
    @DocumentID var id: String?   // viewer uid
    var displayName: String
    @ServerTimestamp var viewedAt: Timestamp?
}

// MARK: - Service

@MainActor
final class FirestoreService {
    static let shared = FirestoreService()
    private let db = Firestore.firestore()

    private var uid: String? { Auth.auth().currentUser?.uid }

    // MARK: Users

    func upsertCurrentUserProfile(displayName: String, phone: String, identityKey: String? = nil,
                                  about: String? = nil) async throws {
        guard let uid else { return }
        var data: [String: Any] = [
            "displayName": displayName,
            "phone": phone,
        ]
        // Presence rides along with the profile write, so it has to respect the Last Seen
        // choice too — otherwise saving your name republishes the presence that "Nobody"
        // just deleted.
        if sharesPresence {
            data["isOnline"] = true
            data["lastSeen"] = FieldValue.serverTimestamp()
        }
        if let identityKey { data["identityKey"] = identityKey }
        if let about { data["about"] = about }
        try await db.collection("users").document(uid).setData(data, merge: true)
    }

    /// Fetch a single account by uid. Returns nil when no such user document exists —
    /// used by QR scanning to tell "not an Inditalk user" apart from a network failure.
    func fetchUser(uid userID: String) async throws -> RemoteUser? {
        let snapshot = try await db.collection("users").document(userID).getDocument()
        guard snapshot.exists else { return nil }
        return try snapshot.data(as: RemoteUser.self)
    }

    /// Fetch several accounts by uid. Firestore caps `in` queries at 30 values, so this
    /// chunks the request; missing documents are simply absent from the result.
    func fetchUsers(uids: [String]) async throws -> [RemoteUser] {
        let unique = Array(Set(uids)).filter { !$0.isEmpty }
        guard !unique.isEmpty else { return [] }

        var result: [RemoteUser] = []
        for chunk in stride(from: 0, to: unique.count, by: 30).map({ Array(unique[$0..<min($0 + 30, unique.count)]) }) {
            let snapshot = try await db.collection("users")
                .whereField(FieldPath.documentID(), in: chunk)
                .getDocuments()
            result.append(contentsOf: snapshot.documents.compactMap { try? $0.data(as: RemoteUser.self) })
        }
        return result
    }

    /// Mirrors the "Profile Photo" choice, for the same reason as `sharesPresence`:
    /// with it off, an avatar upload must not put the URL back on the public document.
    var sharesProfilePhoto = true

    /// Point the profile at an uploaded photo — nil removes it (photo deleted).
    func setAvatarURL(_ url: String?) async throws {
        guard let uid else { return }
        guard sharesProfilePhoto || url == nil else {
            print("[Inditalk privacy] profile photo is hidden — not publishing its URL")
            return
        }
        try await db.collection("users").document(uid).setData([
            "avatarURL": url ?? FieldValue.delete(),
        ], merge: true)
    }

    /// Mirrors the account's "Last Seen & Online" choice. While false, presence writes
    /// are dropped entirely rather than filtered by readers — the timestamp never
    /// reaches the server, so there is nothing to leak. Kept here (rather than checked
    /// at each call site) because presence is written from the scene phase, sign-in, and
    /// termination, and a single missed call site would quietly publish it anyway.
    var sharesPresence = true

    func setPresence(online: Bool) async throws {
        guard let uid, sharesPresence else { return }
        try await db.collection("users").document(uid).setData([
            "isOnline": online,
            "lastSeen": FieldValue.serverTimestamp(),
        ], merge: true)
    }

    /// Publish the account's visibility choices, and enforce the strict one.
    ///
    /// "Nobody" is enforced by WITHHOLDING rather than by asking readers to behave: the
    /// value is deleted from the profile document, so no client — patched, stale, or
    /// hostile — can read what isn't there. "My Contacts" can only be applied by the
    /// reader (a Firestore document has one copy for all viewers, and the server does
    /// not know the author's address book), so it is published for readers to honour.
    func updatePrivacy(_ settings: PrivacySettings, about: String, avatarURL: String?) async throws {
        guard let uid else { return }
        sharesPresence = settings.lastSeen != .nobody
        sharesProfilePhoto = settings.profilePhoto != .nobody

        var data: [String: Any] = [
            "privacy": [
                "lastSeen": settings.lastSeen.rawValue,
                "profilePhoto": settings.profilePhoto.rawValue,
                "about": settings.about.rawValue,
            ],
        ]
        // Hiding DELETES the URL; unhiding leaves whatever is on the document (the photo
        // itself is re-published by the avatar sync, which has the local bytes). Never
        // write `delete()` on the unhidden path — that would erase a perfectly visible
        // photo every time these settings are republished.
        if settings.profilePhoto == .nobody {
            data["avatarURL"] = FieldValue.delete()
        } else if let avatarURL {
            data["avatarURL"] = avatarURL
        }
        data["about"] = settings.about == .nobody ? "" : about
        if settings.lastSeen == .nobody {
            data["isOnline"] = false
            data["lastSeen"] = FieldValue.delete()
        }
        try await db.collection("users").document(uid).setData(data, merge: true)
        print("[Inditalk privacy] published lastSeen=\(settings.lastSeen.rawValue) "
              + "photo=\(settings.profilePhoto.rawValue) about=\(settings.about.rawValue)")
    }

    // MARK: Blocking

    /// Publish (or withdraw) a block at `users/{uid}/blocked/{peerUid}`.
    ///
    /// The list is private to its owner under the rules, and is read server-side by
    /// `onCallInvite` before it sends a VoIP push. That check is the only thing that stops
    /// a blocked contact ringing a LOCKED phone: the client's own block check needs the
    /// sync coordinator to have started, which a push-launched app has not done.
    func setBlocked(_ blocked: Bool, peerUID: String) async throws {
        guard let uid, !peerUID.isEmpty else { return }
        let ref = db.collection("users").document(uid).collection("blocked").document(peerUID)
        if blocked {
            try await ref.setData(["blockedAt": FieldValue.serverTimestamp()], merge: true)
        } else {
            try await ref.delete()
        }
    }

    /// The uids this account has blocked, as stored on the server. Used at start-up to
    /// reconcile a local block list that predates server-side publication.
    func fetchBlockedUIDs() async throws -> Set<String> {
        guard let uid else { return [] }
        let snapshot = try await db.collection("users").document(uid)
            .collection("blocked").getDocuments()
        return Set(snapshot.documents.map(\.documentID))
    }

    // MARK: Chats

    /// Live list of the current user's chats, newest activity first.
    func listenChats(_ handler: @escaping ([RemoteChat]) -> Void) -> ListenerRegistration? {
        guard let uid else { return nil }
        return db.collection("chats")
            .whereField("participantIds", arrayContains: uid)
            .order(by: "lastActivity", descending: true)
            .addSnapshotListener { snapshot, error in
                // A denied or un-indexed query otherwise reports an EMPTY list, which is
                // indistinguishable from "you have no chats" — the failure mode that makes
                // a broken chat list impossible to diagnose from the UI.
                if let error {
                    print("[Inditalk firestore] listenChats failed: \(error)")
                }
                let chats = snapshot?.documents.compactMap { try? $0.data(as: RemoteChat.self) } ?? []
                handler(chats)
            }
    }

    /// Create the chat document if it isn't there yet, leaving an existing one untouched.
    ///
    /// This must happen BEFORE the first message write. `firestore.rules` authorizes a
    /// message create with `isParticipant(chatId)`, which reads
    /// `chats/{chatId}.participantIds` — against a missing document that rule errors and
    /// the write is rejected, so the message never leaves the device. Creating the chat
    /// is also what puts it in the other participant's `listenChats` query.
    ///
    /// Idempotent (merge write), so it is safe to call on every send.
    ///
    /// Deliberately does NOT check for existence first: `allow read` on a chat is
    /// `isParticipant(chatId)`, which itself reads the document — so probing a chat that
    /// does not exist yet is denied by the rules, not reported as "absent". A blind merge
    /// write is both simpler and the only thing the rules permit here (it authorizes as a
    /// create when the doc is new, an update when it already exists; the caller is a
    /// participant either way).
    ///
    /// `title` is merged rather than left alone, so renaming a group still propagates.
    /// `participantIds` is re-asserted from local state, which is correct for direct chats
    /// (fixed pair) but means group membership changes made elsewhere could be reverted by
    /// a stale client — group membership needs a server-authoritative update path.
    func ensureChat(chatId: String, kind: String, title: String,
                    participantIds: [String], adminIds: [String] = []) async throws {
        try await db.collection("chats").document(chatId).setData([
            "kind": kind,
            "title": title,
            "participantIds": participantIds,
            "adminIds": adminIds,
            "disappearingSeconds": 0,
            "lastActivity": FieldValue.serverTimestamp(),
        ], merge: true)
    }

    // MARK: Messages

    /// Send a message. `ciphertext` MUST already be encrypted by CryptoService.
    /// `messageId` should be the id of the local optimistic message so the echoed
    /// snapshot dedups against it (no duplicate) rather than appearing twice.
    func sendMessage(chatId: String, ciphertext: String, messageId: String = UUID().uuidString,
                     kind: String = "text", replyTo: String? = nil) async throws {
        guard let uid else { return }
        let messages = db.collection("chats").document(chatId).collection("messages")
        var data: [String: Any] = [
            "senderId": uid,
            "kind": kind,
            "ciphertext": ciphertext,
            "sentAt": FieldValue.serverTimestamp(),
        ]
        if let replyTo { data["replyTo"] = replyTo }
        try await messages.document(messageId).setData(data)
        // Bump the parent chat so it re-sorts to the top for everyone.
        try await db.collection("chats").document(chatId)
            .setData(["lastActivity": FieldValue.serverTimestamp()], merge: true)
    }

    /// Tombstone one of the current user's own messages for every participant
    /// ("delete for everyone"). The rules only allow the sender to update a message,
    /// which is exactly the authorization this needs. Ciphertext is cleared so the
    /// deleted content is really gone from the server, not just flagged.
    func markMessageDeleted(chatId: String, messageId: String) async throws {
        try await db.collection("chats").document(chatId)
            .collection("messages").document(messageId)
            .updateData(["deleted": true, "ciphertext": ""])
    }

    /// Live message stream for a chat, oldest first. Returns the registration so the
    /// caller can remove the listener on disappear.
    func listenMessages(chatId: String, _ handler: @escaping ([RemoteMessage]) -> Void) -> ListenerRegistration {
        db.collection("chats").document(chatId).collection("messages")
            .order(by: "sentAt", descending: false)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[Inditalk firestore] listenMessages(\(chatId)) failed: \(error)")
                }
                let messages = snapshot?.documents.compactMap { try? $0.data(as: RemoteMessage.self) } ?? []
                handler(messages)
            }
    }

    // MARK: Statuses (24h updates)

    /// Publish a status under the current user's profile. `expiresAt` comes from the
    /// domain model (+24h) so client and server agree on the lifetime.
    func publishStatus(statusId: String, kind: String, text: String, paletteIndex: Int,
                       mediaPath: String?, expiresAt: Date) async throws {
        guard let uid else { return }
        var data: [String: Any] = [
            "kind": kind,
            "text": text,
            "paletteIndex": paletteIndex,
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: expiresAt),
        ]
        if let mediaPath { data["mediaPath"] = mediaPath }
        try await db.collection("users").document(uid)
            .collection("statuses").document(statusId).setData(data)
    }

    /// Remove one of the current user's statuses (author delete, or expiry pruning).
    /// Returns the doc's mediaPath (if any) so the caller can delete the blob too.
    @discardableResult
    func deleteStatus(statusId: String) async throws -> String? {
        guard let uid else { return nil }
        let ref = db.collection("users").document(uid).collection("statuses").document(statusId)
        let mediaPath = (try? await ref.getDocument())?.get("mediaPath") as? String
        // Firestore doesn't cascade deletes: clear the view receipts first, or they
        // orphan under the deleted doc forever.
        if let views = try? await ref.collection("views").getDocuments() {
            for doc in views.documents { try? await doc.reference.delete() }
        }
        try await ref.delete()
        return mediaPath
    }

    /// The current user's statuses that have already expired — launch-time hygiene so
    /// stale docs don't accumulate under the profile forever.
    func fetchOwnExpiredStatuses() async throws -> [RemoteStatus] {
        guard let uid else { return [] }
        let snapshot = try await db.collection("users").document(uid).collection("statuses")
            .whereField("expiresAt", isLessThan: Timestamp(date: Date()))
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: RemoteStatus.self) }
    }

    /// Live stream of one author's ACTIVE statuses. Single-field range filter, so no
    /// composite index is needed. The bound is fixed at attach time; ingest re-checks
    /// `isExpired` client-side, so mid-session expiry still hides correctly.
    func listenStatuses(uid authorUID: String,
                        _ handler: @escaping ([RemoteStatus]) -> Void) -> ListenerRegistration {
        db.collection("users").document(authorUID).collection("statuses")
            .whereField("expiresAt", isGreaterThan: Timestamp(date: Date()))
            .addSnapshotListener { snapshot, error in
                if let error {
                    // Same rationale as listenChats: a denied listener otherwise looks
                    // exactly like "this contact has no statuses".
                    print("[Inditalk status] listenStatuses(\(authorUID)) failed: \(error)")
                }
                let statuses = snapshot?.documents.compactMap { try? $0.data(as: RemoteStatus.self) } ?? []
                handler(statuses)
            }
    }

    /// Record that the current user watched a contact's status (viewer side of the
    /// "seen by" list). Merge-upsert keyed by our uid, so re-watching never duplicates.
    func markStatusViewed(authorUid: String, statusId: String, displayName: String) async throws {
        guard let uid else { return }
        try await db.collection("users").document(authorUid)
            .collection("statuses").document(statusId)
            .collection("views").document(uid)
            .setData([
                "displayName": displayName,
                "viewedAt": FieldValue.serverTimestamp(),
            ], merge: true)
    }

    /// Live stream of who watched ONE of the current user's statuses (author side).
    /// Rules restrict this read to the status owner.
    func listenStatusViews(statusId: String,
                           _ handler: @escaping ([RemoteStatusView]) -> Void) -> ListenerRegistration? {
        guard let uid else { return nil }
        return db.collection("users").document(uid)
            .collection("statuses").document(statusId)
            .collection("views")
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[Inditalk status] listenStatusViews(\(statusId)) failed: \(error)")
                }
                let views = snapshot?.documents.compactMap { try? $0.data(as: RemoteStatusView.self) } ?? []
                handler(views)
            }
    }

    // MARK: Receipts & typing

    func markRead(chatId: String, lastMessageId: String) async throws {
        guard let uid else { return }
        try await db.collection("chats").document(chatId)
            .collection("receipts").document(uid).setData([
                "lastReadMessageId": lastMessageId,
                "lastReadAt": FieldValue.serverTimestamp(),
            ], merge: true)
    }

    /// Live read positions for every participant of a chat.
    ///
    /// The counterpart to `markRead` — which has always written these documents while
    /// nothing read them, so a sent message could never honestly show as read. One
    /// listener per chat covers all participants.
    func listenReceipts(chatId: String,
                        _ handler: @escaping ([RemoteReceipt]) -> Void) -> ListenerRegistration {
        db.collection("chats").document(chatId).collection("receipts")
            .addSnapshotListener { snapshot, error in
                if let error {
                    // Same rationale as listenChats: a denied listener is indistinguishable
                    // from "nobody has read anything" unless it says so.
                    print("[Inditalk firestore] listenReceipts(\(chatId)) failed: \(error)")
                }
                let receipts = snapshot?.documents.compactMap { try? $0.data(as: RemoteReceipt.self) } ?? []
                handler(receipts)
            }
    }

    // MARK: Reactions

    /// Doc id for one user's reaction to one message — the uniqueness constraint that
    /// makes "one reaction per user per message" a storage rule rather than a hope.
    static func reactionDocId(messageId: String, uid: String) -> String { "\(messageId)_\(uid)" }

    /// Add or change the current user's reaction to a message. `ciphertext` MUST already
    /// be sealed by MessageCrypto — the emoji is content, like a message body.
    func setReaction(chatId: String, messageId: String, ciphertext: String) async throws {
        guard let uid else { return }
        try await db.collection("chats").document(chatId)
            .collection("reactions").document(Self.reactionDocId(messageId: messageId, uid: uid))
            .setData([
                "messageId": messageId,
                "uid": uid,
                "ciphertext": ciphertext,
                "updatedAt": FieldValue.serverTimestamp(),
            ], merge: true)
    }

    /// Remove the current user's reaction (tapping the same emoji again un-reacts).
    func clearReaction(chatId: String, messageId: String) async throws {
        guard let uid else { return }
        try await db.collection("chats").document(chatId)
            .collection("reactions").document(Self.reactionDocId(messageId: messageId, uid: uid))
            .delete()
    }

    /// Live stream of every reaction in a chat, from every participant. The snapshot is
    /// the complete truth for the chat, which is what lets the client treat a missing
    /// document as "that reaction was removed".
    func listenReactions(chatId: String,
                         _ handler: @escaping ([RemoteReaction]) -> Void) -> ListenerRegistration {
        db.collection("chats").document(chatId).collection("reactions")
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[Inditalk firestore] listenReactions(\(chatId)) failed: \(error)")
                }
                let reactions = snapshot?.documents.compactMap { try? $0.data(as: RemoteReaction.self) } ?? []
                handler(reactions)
            }
    }

    // MARK: Typing

    func setTyping(chatId: String, isTyping: Bool) async throws {
        guard let uid else { return }
        try await db.collection("chats").document(chatId)
            .collection("typing").document(uid).setData([
                "isTyping": isTyping,
                "updatedAt": FieldValue.serverTimestamp(),
            ], merge: true)
    }

    func listenTyping(chatId: String, _ handler: @escaping ([String]) -> Void) -> ListenerRegistration {
        db.collection("chats").document(chatId).collection("typing")
            .whereField("isTyping", isEqualTo: true)
            .addSnapshotListener { [weak self] snapshot, _ in
                let others = (snapshot?.documents ?? [])
                    .map { $0.documentID }
                    .filter { $0 != self?.uid }
                handler(others)
            }
    }
}
