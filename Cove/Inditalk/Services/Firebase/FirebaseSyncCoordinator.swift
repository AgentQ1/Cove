//
//  FirebaseSyncCoordinator.swift
//  Inditalk
//
//  Bridges Firestore live listeners <-> DataStore. It maps server documents to the
//  domain models, DECRYPTS message bodies (MessageCrypto), and ingests them into the
//  store — which is what the UI already renders. Outgoing sends are inserted locally
//  (optimistic) and encrypted before being written to Firestore.
//
//  This file is the ONLY place that couples Firestore to the store; everything it
//  calls (DataStore.ingest…, MessageCrypto) is backend-free and unit-tested. It runs
//  only when Firebase is configured (AppConfig.usesFirebase).
//
//  REQUIRES: FirebaseFirestore + FirebaseAuth SPM packages.
//

import Foundation
import Combine
import CryptoKit
import FirebaseFirestore
import FirebaseAuth

/// Wire form of an attachment, carried INSIDE the E2EE ciphertext for every non-text
/// message kind (a JSON envelope replaces the bare caption string). The media blob
/// itself is sealed with the fresh per-attachment `mediaKey` before upload, so Storage
/// only ever holds ciphertext and Firestore only ever sees this envelope encrypted —
/// attachment metadata gets the same protection as message bodies.
///
/// Text/system messages keep the original bare-string wire format, and a media message
/// whose body doesn't parse as an envelope is treated as caption-only (older messages).
struct MediaEnvelope: Codable, Equatable {
    var caption: String
    var mediaPath: String?        // Storage path of the sealed blob (nil: location/contact card)
    var mediaKey: String?         // base64 256-bit key sealing the blob
    var ext: String?              // original file extension (playback/rendering needs it)
    var assetName: String?        // bundled sample asset (previews/demo content)
    var durationSeconds: Double?
    var waveform: [Float]?
    var fileName: String?
    var byteSize: Int?
    var latitude: Double?
    var longitude: Double?
    var contactName: String?
    var contactPhone: String?

    init(caption: String, attachment: Attachment,
         mediaPath: String? = nil, mediaKey: String? = nil, ext: String? = nil) {
        self.caption = caption
        self.mediaPath = mediaPath
        self.mediaKey = mediaKey
        self.ext = ext
        self.assetName = attachment.assetName
        self.durationSeconds = attachment.durationSeconds
        self.waveform = attachment.waveform
        self.fileName = attachment.fileName
        self.byteSize = attachment.byteSize
        self.latitude = attachment.latitude
        self.longitude = attachment.longitude
        self.contactName = attachment.contactName
        self.contactPhone = attachment.contactPhone
    }

    /// Rebuild the domain attachment on the receiving side. `localName` is filled in
    /// only once the (decrypted) media file actually exists on this device.
    func attachment(localName: String?) -> Attachment {
        Attachment(assetName: assetName, localName: localName,
                   durationSeconds: durationSeconds, waveform: waveform,
                   fileName: fileName, byteSize: byteSize,
                   latitude: latitude, longitude: longitude,
                   contactName: contactName, contactPhone: contactPhone)
    }

    func encodedString() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    /// nil means the plaintext is not an envelope — i.e. a legacy caption-only body.
    static func decode(_ plaintext: String) -> MediaEnvelope? {
        guard plaintext.hasPrefix("{") else { return nil }
        return try? JSONDecoder().decode(MediaEnvelope.self, from: Data(plaintext.utf8))
    }

    /// AAD binding a sealed media blob to its message.
    static func mediaAAD(messageId: String) -> Data { Data("cove.attach.\(messageId)".utf8) }

    /// Deterministic on-device filename for synced media, so re-delivered snapshots
    /// resolve to the already-downloaded file instead of fetching again.
    static func localMediaName(messageId: String, ext: String?) -> String {
        let cleaned = (ext?.isEmpty == false) ? ext! : "bin"
        return "msg-\(messageId).\(cleaned)"
    }
}

@MainActor
final class FirebaseSyncCoordinator: ObservableObject {
    private weak var store: DataStore?
    private var chatListener: ListenerRegistration?
    private var messageListeners: [String: ListenerRegistration] = [:]
    /// One listener per chat on its receipts subcollection — how a sent message learns
    /// it was actually read, on every device, instead of guessing.
    private var receiptListeners: [String: ListenerRegistration] = [:]
    /// One listener per chat on its reactions subcollection (all messages, all users).
    private var reactionListeners: [String: ListenerRegistration] = [:]
    /// One listener per contact uid on users/{uid}/statuses (statuses are broadcast
    /// off the profile, like presence and the avatar).
    private var statusListeners: [String: ListenerRegistration] = [:]
    /// One listener per OWN active status on its views subcollection — the "seen by"
    /// list. Reconciled off the store's own statuses (see observeOwnStatuses).
    private var statusViewListeners: [UUID: ListenerRegistration] = [:]
    private var storeObservers: Set<AnyCancellable> = []
    /// In-flight media fetches, keyed by message/status id, so overlapping snapshots
    /// can't start duplicate downloads.
    private var activeMediaDownloads: Set<UUID> = []
    private var activeStatusDownloads: Set<UUID> = []
    /// Downloads that failed, kept so the bubble's tap-to-retry can re-run them.
    private var failedDownloads: [UUID: PendingMediaDownload] = [:]
    /// Firebase uid of the OTHER participant per direct chat — the identity the shared
    /// chat key is agreed with. Filled from listenChats before message listeners attach.
    private var directPeerUID: [UUID: String] = [:]
    /// Serializes async decrypt+ingest per chat so snapshots apply in arrival order.
    private var ingestTasks: [String: Task<Void, Never>] = [:]
    /// The same serialization for reaction snapshots (decrypting them can await a key).
    private var reactionTasks: [String: Task<Void, Never>] = [:]

    init() {}

    private var currentUID: String? { Auth.auth().currentUser?.uid }

    // MARK: Lifecycle

    /// Begin syncing against `store`. Safe to call when Firebase isn't configured or
    /// no user is signed in — it just no-ops and the app stays in local mode.
    func start(store: DataStore) {
        self.store = store
        guard AppConfig.usesFirebase, currentUID != nil else { return }

        // Route outgoing messages (already inserted locally by DataStore.send) through
        // encryption + Firestore. The message's own id becomes the doc id so the echo
        // dedups instead of duplicating.
        store.remoteSink = { [weak self] message in self?.push(message) }

        // Propagate "delete for everyone" on own messages to the server tombstone.
        store.messageDeleteSink = { messageID, chatID in
            Task {
                do {
                    try await FirestoreService.shared.markMessageDeleted(
                        chatId: chatID.uuidString, messageId: messageID.uuidString)
                    print("[Inditalk send] tombstoned message \(messageID) for everyone")
                } catch {
                    print("[Inditalk send] remote delete failed for \(messageID): \(error)")
                }
            }
        }

        // Tap-to-retry for failed media downloads (bubble placeholder → re-fetch).
        store.mediaRetrySink = { [weak self] messageID in
            guard let self, let download = self.failedDownloads.removeValue(forKey: messageID) else {
                print("[Inditalk media] no retryable download for message \(messageID)")
                return
            }
            self.startMediaDownload(download)
        }

        // Push profile edits (name / about / photo) to the users/{uid} document. The
        // avatar bytes upload to Storage (avatars/{uid}/…, owner-writable per
        // storage.rules) and the download URL is merged into the profile doc so
        // contacts' clients can render it.
        store.profileSink = { [weak store] user in
            Task {
                try? await FirestoreService.shared.upsertCurrentUserProfile(
                    displayName: user.displayName, phone: user.phoneNumber, about: user.about)
                await Self.syncAvatar(localName: user.avatarLocalName)
                // Re-apply visibility LAST: the two writes above publish the about text
                // and the photo URL unconditionally, so an edit made while "Nobody" is
                // selected would otherwise put the hidden value back on the document.
                if let settings = store?.privacy {
                    try? await FirestoreService.shared.updatePrivacy(
                        settings, about: user.about, avatarURL: nil)
                }
            }
        }

        // Publish the visibility choices whenever they change, and once at start so a
        // setting changed while signed out (or before this existed) is applied.
        store.privacySink = { [weak self] settings in self?.publishPrivacy(settings) }
        publishPrivacy(store.privacy)

        // One-time backfill: an avatar chosen before avatar sync existed (or before
        // sign-in finished) never uploaded. If the server has no URL but we have a
        // local photo, push it now.
        Task { [weak self] in await self?.backfillOwnAvatarIfNeeded() }

        // Publish read receipts: when the user opens a chat, record the newest INCOMING
        // message as read in chats/{chatId}/receipts/{uid}.
        store.readSink = { [weak store] chatID in
            guard let last = store?.messages(in: chatID).last(where: { !$0.isOutgoing }) else { return }
            Task {
                try? await FirestoreService.shared.markRead(
                    chatId: chatID.uuidString, lastMessageId: last.id.uuidString)
            }
        }

        // Publish reaction changes so they appear on the other person's device (and the
        // user's other devices) instead of staying a local decoration. The emoji is
        // encrypted like a message body — see sealReaction.
        store.reactionSink = { [weak self] messageID, chatID, emoji in
            Task { await self?.publishReaction(emoji, messageID: messageID, chatID: chatID) }
        }

        // Mirror block/unblock into users/{uid}/blocked/{peerUid}. `onCallInvite` reads
        // that list before it sends a VoIP push — without it, blocking is enforced only
        // while the app is running, which is exactly when it matters least.
        store.blockSink = { [weak store] userID, blocked in
            guard let peerUID = store?.users[userID]?.remoteUID, !peerUID.isEmpty else {
                print("[Inditalk block] no Firebase uid for \(userID) — block stays local only")
                return
            }
            Task {
                do {
                    try await FirestoreService.shared.setBlocked(blocked, peerUID: peerUID)
                    print("[Inditalk block] \(blocked ? "published" : "withdrew") server-side block")
                } catch {
                    print("[Inditalk block] publishing block for \(peerUID) failed: \(error)")
                }
            }
        }
        // Reconcile a block list made before it was published (or on another device).
        Task { [weak self] in await self?.reconcileBlockList() }

        // Give the call layer a way to mint short-lived TURN credentials. Calls fall
        // back to STUN without this, which fails on symmetric NAT (most mobile carrier
        // networks) — see ICEServerConfig and functions/turn.js.
        ICEServerConfig.shared.credentialProvider = { try await TurnCredentialsService.shared.fetch() }
        // Warm them now, while nobody is waiting: the first call then starts with a
        // relay already in hand instead of paying the round trip on the dialing screen.
        Task { await ICEServerConfig.shared.refreshIfNeeded() }

        // Let the call layer consult the local block list (keyed by local UUID) using an
        // incoming caller's Firebase uid, so blocked contacts can't ring the user.
        CallCenter.shared.isPeerBlocked = { [weak store] uid in
            store?.isBlocked(FirebaseSyncCoordinator.stableUUID(uid)) ?? false
        }

        // Resolve an incoming caller's uid to their profile name — otherwise the
        // native call UI shows the raw Firebase uid string.
        CallCenter.shared.resolvePeerName = { [weak store] uid in
            let name = store?.users[FirebaseSyncCoordinator.stableUUID(uid)]?.displayName
            return (name?.isEmpty == false) ? name : nil
        }

        // Persist finished real calls into call history (Calls tab "Recent") — the
        // call layer can't reach the store itself, so it hands the record up here.
        CallCenter.shared.onCallEnded = { [weak store] record, peerUID in
            guard let store else { return }
            var record = record
            if let peerUID {
                let localID = FirebaseSyncCoordinator.stableUUID(peerUID)
                record.chatID = store.chats.first {
                    $0.kind == .direct && $0.participantIDs.contains(localID)
                }?.id
            }
            store.logCall(record)
        }

        // Publish new statuses to contacts, and propagate deletes of our own. Expired
        // docs left behind by past sessions are pruned once per start.
        store.statusSink = { [weak self] status in
            Task { await self?.publishStatus(status) }
        }
        store.statusDeleteSink = { statusID in
            Task {
                do {
                    let mediaPath = try await FirestoreService.shared.deleteStatus(
                        statusId: statusID.uuidString)
                    if let mediaPath { try? await FirebaseStorageService.shared.delete(path: mediaPath) }
                } catch {
                    print("[Inditalk status] remote delete failed for \(statusID): \(error)")
                }
            }
        }
        // Watching a contact's status writes a receipt into THEIR seen-by list.
        store.statusViewedSink = { [weak self] status in
            Task { await self?.publishStatusView(status) }
        }
        // ...and keep a listener on each of OUR statuses' seen-by lists.
        observeOwnStatuses(store: store)
        Task { [weak self] in await self?.pruneOwnExpiredStatuses() }

        // Publish our public prekey bundle so peers can establish E2EE sessions with us.
        Task { try? await PrekeyService.shared.publishLocalBundle() }

        chatListener = FirestoreService.shared.listenChats { [weak self] remoteChats in
            guard let self else { return }
            // Record each direct chat's peer BEFORE attaching message listeners, so the
            // first decrypt already knows whose identity key the chat key is agreed with.
            for remote in remoteChats where remote.kind == ChatKind.direct.rawValue {
                guard let id = remote.id, let chatUUID = UUID(uuidString: id),
                      let peer = remote.participantIds.first(where: { $0 != self.currentUID }) else { continue }
                self.directPeerUID[chatUUID] = peer
            }
            let domain = remoteChats.compactMap(self.mapChat)
            self.store?.ingest(remoteChats: domain)
            for remote in remoteChats {
                guard let id = remote.id else { continue }
                self.subscribeMessages(chatId: id)
                self.subscribeReceipts(chatId: id)
                self.subscribeReactions(chatId: id)
            }
            // Resolve the people in those chats to real profiles. Without this, chat
            // participants are bare hashed ids with no name, avatar, or — critically —
            // uid to place a call to.
            self.refreshParticipants(of: remoteChats)
            // Everyone we share a chat with is a contact whose statuses we should see.
            for uid in Set(remoteChats.flatMap(\.participantIds)) where uid != self.currentUID {
                self.subscribeStatuses(uid: uid)
            }
        }
    }

    /// Fetch profiles for every participant we don't already know, and ingest them so
    /// contacts, calls, and QR lookups all address real accounts.
    private func refreshParticipants(of chats: [RemoteChat]) {
        let uids = Set(chats.flatMap(\.participantIds)).subtracting([currentUID ?? ""])
        guard !uids.isEmpty else { return }
        Task { [weak self] in
            guard let remote = try? await FirestoreService.shared.fetchUsers(uids: Array(uids)) else { return }
            guard let self else { return }
            self.store?.ingest(remoteUsers: remote.compactMap { r in
                Self.mapUser(r).map { self.applyPeerPrivacy($0, r) }
            })
        }
    }

    // MARK: Privacy (visibility of last seen / photo / about)

    /// Push the account's visibility choices to users/{uid} and re-upload the photo when
    /// it has just been UN-hidden (hiding deleted the URL, so there is nothing to show
    /// until the local copy is uploaded again).
    private func publishPrivacy(_ settings: PrivacySettings) {
        guard AppConfig.usesFirebase, currentUID != nil else { return }
        let about = store?.currentUser.about ?? ""
        let localAvatar = store?.currentUser.avatarLocalName
        Task {
            do {
                try await FirestoreService.shared.updatePrivacy(settings, about: about, avatarURL: nil)
            } catch {
                print("[Inditalk privacy] publishing visibility failed: \(error)")
                return
            }
            if settings.profilePhoto == .nobody {
                // Clearing the URL is not enough — the uploaded photo stays readable to
                // anyone who already has the link. Hiding it means deleting the object.
                do {
                    try await FirebaseStorageService.shared.deleteAvatar()
                    print("[Inditalk privacy] profile photo hidden — uploaded copy deleted")
                } catch {
                    print("[Inditalk privacy] could not delete the uploaded photo: \(error)")
                }
            } else if let localAvatar {
                // Un-hidden: the object was deleted, so re-upload from the local copy.
                await Self.syncAvatar(localName: localAvatar)
            }
        }
    }

    /// Apply the AUTHOR's visibility choices to what this device is willing to show.
    ///
    /// "Nobody" is already enforced at the source (the field is deleted from their
    /// document — see FirestoreService.updatePrivacy); re-applying it here costs nothing
    /// and covers a profile written by an older build. "My Contacts" can only be applied
    /// here: one Firestore document serves every viewer, and the server does not know
    /// the author's address book. The relationship this device can actually evaluate is
    /// "we have a conversation", so that is what stands in for being a contact.
    private func applyPeerPrivacy(_ user: InditalkUser, _ remote: RemoteUser) -> InditalkUser {
        var user = user
        let privacy = remote.privacy
        let isContact = sharesAChat(with: user.id)

        func allows(_ raw: String?) -> Bool {
            switch PrivacySettings.Visibility(rawValue: raw ?? "") {
            case .nobody:   return false
            case .contacts: return isContact
            // .everyone, or a profile with no published choice (older build).
            default:        return true
            }
        }

        if !allows(privacy?.profilePhoto) { user.avatarURL = nil }
        if !allows(privacy?.about) { user.about = "" }
        // Last Seen is reciprocal, exactly as the privacy screen promises: hide yours and
        // you stop seeing everyone else's.
        let mine = store?.privacy.lastSeen ?? .everyone
        if !allows(privacy?.lastSeen) || mine == .nobody {
            user.presence = PresenceSnapshot(isOnline: false, lastSeen: nil, shares: false)
        }
        return user
    }

    private func sharesAChat(with userID: UUID) -> Bool {
        store?.chats.contains { $0.participantIDs.contains(userID) } ?? false
    }

    /// Server profile -> domain user, carrying the uid so the account stays addressable.
    static func mapUser(_ r: RemoteUser) -> InditalkUser? {
        guard let uid = r.id else { return nil }
        return InditalkUser(
            id: stableUUID(uid),
            displayName: r.displayName,
            phoneNumber: r.phone,
            about: r.about,
            avatarURL: r.avatarURL,
            presence: PresenceSnapshot(isOnline: r.isOnline,
                                       lastSeen: r.lastSeen?.dateValue(),
                                       shares: true),
            remoteUID: uid
        )
    }

    // MARK: Avatar sync (local photo <-> Storage + users/{uid}.avatarURL)

    /// Upload the user's profile photo (or clear the remote URL when removed).
    private static func syncAvatar(localName: String?) async {
        do {
            if let localName {
                let data = try Data(contentsOf: MediaStore.url(for: localName))
                let url = try await FirebaseStorageService.shared.uploadAvatar(data)
                try await FirestoreService.shared.setAvatarURL(url)
            } else {
                try await FirestoreService.shared.setAvatarURL(nil)
            }
        } catch {
            print("[Inditalk avatar] sync failed: \(error)")
        }
    }

    private func backfillOwnAvatarIfNeeded() async {
        guard let uid = currentUID, let localName = store?.currentUser.avatarLocalName else { return }
        guard let remote = try? await FirestoreService.shared.fetchUser(uid: uid),
              remote.avatarURL == nil else { return }
        await Self.syncAvatar(localName: localName)
    }

    func stop() {
        store?.remoteSink = nil
        store?.profileSink = nil
        store?.readSink = nil
        store?.privacySink = nil
        store?.statusSink = nil
        store?.statusDeleteSink = nil
        store?.statusViewedSink = nil
        store?.messageDeleteSink = nil
        store?.mediaRetrySink = nil
        store?.reactionSink = nil
        store?.blockSink = nil
        CallCenter.shared.isPeerBlocked = nil
        CallCenter.shared.resolvePeerName = nil
        CallCenter.shared.onCallEnded = nil
        // Signing out must not leave a relay grant minted for the previous account
        // installed for the next one.
        ICEServerConfig.shared.credentialProvider = nil
        ICEServerConfig.shared.clearTURN()
        chatListener?.remove(); chatListener = nil
        messageListeners.values.forEach { $0.remove() }
        messageListeners = [:]
        receiptListeners.values.forEach { $0.remove() }
        receiptListeners = [:]
        reactionListeners.values.forEach { $0.remove() }
        reactionListeners = [:]
        statusListeners.values.forEach { $0.remove() }
        statusListeners = [:]
        statusViewListeners.values.forEach { $0.remove() }
        statusViewListeners = [:]
        storeObservers = []
        ingestTasks.values.forEach { $0.cancel() }
        ingestTasks = [:]
        reactionTasks.values.forEach { $0.cancel() }
        reactionTasks = [:]
        directPeerUID = [:]
        activeMediaDownloads = []
        activeStatusDownloads = []
        failedDownloads = [:]
    }

    /// Attach a message listener for a chat.
    ///
    /// Only ever called for chats `listenChats` has already returned, which matters: the
    /// messages read rule get()s the parent chat document, so a listener attached before
    /// that document exists is denied — and Firestore does not retry a denied listener,
    /// it stays dead for the process lifetime.
    private func subscribeMessages(chatId: String) {
        guard messageListeners[chatId] == nil, let chatUUID = UUID(uuidString: chatId) else { return }
        messageListeners[chatId] = FirestoreService.shared.listenMessages(chatId: chatId) { [weak self] remote in
            guard let self else { return }
            // Decryption can await a one-time peer-key fetch, so mapping is async;
            // chain the tasks per chat so an older snapshot can't land after a newer one.
            let previous = self.ingestTasks[chatId]
            self.ingestTasks[chatId] = Task { [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled else { return }
                var domain: [Message] = []
                var downloads: [PendingMediaDownload] = []
                for r in remote {
                    if let (message, download) = await self.mapMessage(r, chatID: chatUUID) {
                        domain.append(message)
                        if let download { downloads.append(download) }
                    }
                }
                self.store?.ingest(remoteMessages: domain, in: chatUUID)
                // Fetch media only AFTER ingest, so the completion always finds the
                // message row it attaches the finished file to.
                for download in downloads { self.startMediaDownload(download) }
            }
        }
    }

    // MARK: Blocking (privacy.blockedUserIDs -> users/{uid}/blocked/{peerUid})

    /// Publish any local block the server doesn't know about yet.
    ///
    /// One-way on purpose. A local block missing from the server means it was made before
    /// blocks were published (or while offline) and must be uploaded; a server block
    /// missing locally is NOT treated as an unblock, because the same absence would be
    /// produced by a failed read — and silently un-blocking someone is the one direction
    /// of this sync that can't be undone by the user noticing.
    private func reconcileBlockList() async {
        guard let store else { return }
        let localBlocks = store.privacy.blockedUserIDs
        guard !localBlocks.isEmpty else { return }
        guard let published = try? await FirestoreService.shared.fetchBlockedUIDs() else { return }

        let missing = localBlocks
            .compactMap { store.users[$0]?.remoteUID }
            .filter { !$0.isEmpty && !published.contains($0) }
        guard !missing.isEmpty else { return }

        for peerUID in missing {
            try? await FirestoreService.shared.setBlocked(true, peerUID: peerUID)
        }
        print("[Inditalk block] backfilled \(missing.count) block(s) to the server")
    }

    // MARK: Read receipts (chats/{chatId}/receipts/{uid} -> message state)

    /// Watch every participant's read position in a chat. `markRead` has always WRITTEN
    /// these documents; until this listener existed nothing read them, so an outgoing
    /// message's ticks were a guess that never changed.
    private func subscribeReceipts(chatId: String) {
        guard receiptListeners[chatId] == nil, let chatUUID = UUID(uuidString: chatId) else { return }
        receiptListeners[chatId] = FirestoreService.shared.listenReceipts(chatId: chatId) { [weak self] receipts in
            self?.applyReceipts(receipts, chatID: chatUUID)
        }
    }

    /// A message is READ once every OTHER participant has read at or past it. For a
    /// direct chat that is just the peer; for a group it means the whole room, which is
    /// why a participant with no placeable receipt holds the chat back rather than being
    /// skipped — claiming "read" when one member hasn't opened it would be a lie.
    private func applyReceipts(_ receipts: [RemoteReceipt], chatID: UUID) {
        guard let store, let chat = store.chat(chatID) else { return }
        // Reciprocity, as promised on the privacy screen: with read receipts off you
        // don't send yours and your sent messages stop showing as read. Re-enabling
        // applies from the next receipt onwards ("takes effect immediately for new
        // messages"), because a snapshot already delivered is not replayed.
        guard store.privacy.readReceipts else { return }

        let others = chat.participantIDs.filter { $0 != store.currentUser.id }
        guard !others.isEmpty else { return }

        let messages = store.messages(in: chatID)
        guard !messages.isEmpty else { return }
        var position: [UUID: Int] = [:]
        for (index, message) in messages.enumerated() { position[message.id] = index }

        var byUID: [String: RemoteReceipt] = [:]
        for receipt in receipts {
            if let uid = receipt.id { byUID[uid] = receipt }
        }

        var readThrough = Int.max
        for participant in others {
            // The server-provided peer uid covers a direct chat whose participant
            // profile hasn't synced yet — otherwise the first receipts would be dropped.
            let uid = store.users[participant]?.remoteUID
                ?? (chat.kind == .direct ? directPeerUID[chatID] : nil)
            guard let uid,
                  let receipt = byUID[uid],
                  let index = UUID(uuidString: receipt.lastReadMessageId).flatMap({ position[$0] })
            else { return }   // someone hasn't read anything we can place — nothing is read by all
            readThrough = min(readThrough, index)
        }
        guard messages.indices.contains(readThrough) else { return }
        store.markOutgoingRead(upTo: messages[readThrough].id, in: chatID)
    }

    // MARK: Reactions (chats/{chatId}/reactions -> Message.reactions)

    /// Watch every reaction in a chat. One listener covers all messages and all users
    /// (that is why reactions live in a per-chat subcollection rather than under each
    /// message), and the snapshot is the complete truth — so a removed reaction arrives
    /// as an absence, which `ingest(remoteReactions:)` applies as a removal.
    private func subscribeReactions(chatId: String) {
        guard reactionListeners[chatId] == nil, let chatUUID = UUID(uuidString: chatId) else { return }
        reactionListeners[chatId] = FirestoreService.shared.listenReactions(chatId: chatId) { [weak self] remote in
            guard let self else { return }
            // Decrypting can await a one-time peer-key fetch, so chain per chat to stop
            // an older snapshot landing after a newer one (same reason as messages).
            let previous = self.reactionTasks[chatId]
            self.reactionTasks[chatId] = Task { [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled else { return }
                // Keyed by (message, reactor) so one user can only ever contribute one
                // reaction per message. The rules bind the doc id to exactly that pair,
                // but a document written before that rule existed could still duplicate a
                // reactor — and two hearts from the same person is a visible lie about
                // who reacted. Later documents win, matching "re-reacting replaces".
                var byMessage: [UUID: [UUID: Reaction]] = [:]
                for r in remote.sorted(by: { ($0.updatedAt?.dateValue() ?? .distantPast)
                                             < ($1.updatedAt?.dateValue() ?? .distantPast) }) {
                    guard let messageID = UUID(uuidString: r.messageId),
                          let emoji = await self.openReaction(r.ciphertext, chatID: chatUUID) else { continue }
                    let reactorID = Self.stableUUID(r.uid)
                    byMessage[messageID, default: [:]][reactorID] =
                        Reaction(emoji: emoji, userID: reactorID)
                }
                self.store?.ingest(remoteReactions: byMessage.mapValues { Array($0.values) },
                                   in: chatUUID)
            }
        }
    }

    /// Publish the local user's reaction change (nil emoji = they removed it).
    private func publishReaction(_ emoji: String?, messageID: UUID, chatID: UUID) async {
        do {
            if let emoji {
                let ciphertext = try await sealReaction(emoji, chatID: chatID)
                try await FirestoreService.shared.setReaction(
                    chatId: chatID.uuidString, messageId: messageID.uuidString, ciphertext: ciphertext)
            } else {
                try await FirestoreService.shared.clearReaction(
                    chatId: chatID.uuidString, messageId: messageID.uuidString)
            }
        } catch {
            // Non-fatal: the reaction still shows locally and the next snapshot
            // reconciles this device back to whatever the server actually holds.
            print("[Inditalk sync] reaction publish failed for message \(messageID): \(error)")
        }
    }

    /// The key a reaction is sealed with: the agreed pair key for direct chats (the only
    /// key the peer can also derive), otherwise the interim device-local key — the same
    /// limitation group message bodies already have (see ChatPairKey).
    ///
    /// Deliberately NOT the Double Ratchet: that chain is ordered and stateful per
    /// message, and spending message keys on reactions would desynchronize it.
    private func reactionKey(chatID: UUID) async -> SymmetricKey? {
        guard let peerUID = peerUID(for: chatID) else { return nil }
        return try? await ChatPairKey.shared.key(chatID: chatID, peerUID: peerUID)
    }

    private func sealReaction(_ emoji: String, chatID: UUID) async throws -> String {
        if let key = await reactionKey(chatID: chatID) {
            return try MessageCrypto.shared.encrypt(emoji, chatID: chatID, key: key, purpose: .reaction)
        }
        return try MessageCrypto.shared.encrypt(emoji, chatID: chatID, purpose: .reaction)
    }

    private func openReaction(_ ciphertext: String, chatID: UUID) async -> String? {
        if let key = await reactionKey(chatID: chatID),
           let emoji = try? MessageCrypto.shared.decrypt(ciphertext, chatID: chatID,
                                                         key: key, purpose: .reaction) {
            return emoji
        }
        return try? MessageCrypto.shared.decrypt(ciphertext, chatID: chatID, purpose: .reaction)
    }

    // MARK: Sending

    /// Encrypt an already-locally-inserted message and write it to Firestore, reusing
    /// its id as the doc id. Called via `store.remoteSink`.
    ///
    /// Attachment kinds first seal + upload their media bytes, then wire the attachment
    /// metadata (and the blob's key) inside the encrypted body — see `wireBody(for:)`.
    private func push(_ message: Message) {
        Task {
            do {
                // The chat document must exist before the first message, or the rules
                // check on chats/{chatId}.participantIds rejects the write.
                try await ensureRemoteChat(for: message.chatID)

                let body = try await wireBody(for: message)

                // Prefer the Double Ratchet session, then the agreed pair key (what the
                // peer can actually decrypt), then the interim device-local key (groups,
                // or a peer whose key bundle isn't published — logged, since that
                // ciphertext is unreadable to them).
                let ciphertext: String
                if let wire = try E2EESessionStore.shared.sessionEncrypt(body, chatID: message.chatID) {
                    ciphertext = wire
                } else if let peerUID = peerUID(for: message.chatID),
                          let key = try? await ChatPairKey.shared.key(chatID: message.chatID, peerUID: peerUID) {
                    ciphertext = try MessageCrypto.shared.encrypt(body, chatID: message.chatID, key: key)
                } else {
                    if store?.chat(message.chatID)?.kind == .direct {
                        print("[Inditalk crypto] WARNING: no agreed key for direct chat \(message.chatID) — "
                              + "sending with device-local key; peer cannot decrypt until their bundle is published")
                    }
                    ciphertext = try MessageCrypto.shared.encrypt(body, chatID: message.chatID)
                }
                try await FirestoreService.shared.sendMessage(
                    chatId: message.chatID.uuidString,
                    ciphertext: ciphertext,
                    messageId: message.id.uuidString,
                    kind: message.kind.rawValue,
                    replyTo: message.replyToID?.uuidString)
                // Server acked → single check. The snapshot echo upgrades further.
                store?.applyReceipt(.sent, for: message.id, in: message.chatID)
            } catch {
                // Never fail silently: without this the message sits on a "sending" clock
                // forever with no indication anything went wrong. Marking it .failed
                // renders the red badge and enables "Try Again" in the message menu.
                print("[Inditalk send] FAILED for message \(message.id) (\(message.kind.rawValue)): \(error)")
                store?.applyReceipt(.failed, for: message.id, in: message.chatID)
                ToastCenter.shared.show(Self.sendFailureMessage(for: error), pending: false)
            }
        }
    }

    /// The plaintext that actually gets encrypted: the bare text for text/system
    /// messages (unchanged wire format — working text chat is untouched), or a JSON
    /// MediaEnvelope for attachment kinds. When the attachment has real bytes on disk,
    /// they are sealed with a fresh key and uploaded FIRST, so the envelope written to
    /// Firestore never points at a blob that doesn't exist.
    private func wireBody(for message: Message) async throws -> String {
        guard message.kind != .text, message.kind != .system,
              let attachment = message.attachment else { return message.text }

        var mediaPath: String?
        var mediaKeyB64: String?
        var ext: String?
        if let localName = attachment.localName, MediaStore.exists(localName) {
            let fileURL = MediaStore.url(for: localName)
            // Read + seal off the main actor; media files can be tens of MB.
            let data = try await Task.detached { try Data(contentsOf: fileURL) }.value
            guard data.count < Self.maxAttachmentBytes else { throw SyncError.attachmentTooLarge }

            let keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let aad = MediaEnvelope.mediaAAD(messageId: message.id.uuidString)
            let sealed = try await Task.detached {
                try CryptoService.shared.seal(data, key: SymmetricKey(data: keyData), aad: aad)
            }.value

            let fileExt = (localName as NSString).pathExtension
            ext = fileExt.isEmpty ? "bin" : fileExt.lowercased()
            let path = FirebaseStorageService.shared.attachmentPath(
                chatId: message.chatID.uuidString, messageId: message.id.uuidString, ext: ext!)
            print("[Inditalk media] uploading \(data.count) bytes for message \(message.id) -> \(path)")
            _ = try await FirebaseStorageService.shared.upload(sealed, path: path)
            print("[Inditalk media] upload complete for message \(message.id)")
            mediaPath = path
            mediaKeyB64 = keyData.base64EncodedString()
        }
        let envelope = MediaEnvelope(caption: message.text, attachment: attachment,
                                     mediaPath: mediaPath, mediaKey: mediaKeyB64, ext: ext)
        return try envelope.encodedString()
    }

    /// Matches the 100 MB write cap in storage.rules.
    private static let maxAttachmentBytes = 100 * 1024 * 1024

    /// Errors that stop a message before it can be written.
    enum SyncError: LocalizedError {
        case unknownChat
        /// At least one participant has no Firebase account we can address.
        case participantNotOnInditalk
        /// The attachment exceeds the Storage rules' write cap.
        case attachmentTooLarge

        var errorDescription: String? {
            switch self {
            case .unknownChat:
                return "That conversation no longer exists."
            case .participantNotOnInditalk:
                return "This contact isn't on Inditalk yet, so messages can't be delivered."
            case .attachmentTooLarge:
                return "That file is too large to send (100 MB limit)."
            }
        }
    }

    private static func sendFailureMessage(for error: Error) -> String {
        (error as? SyncError)?.errorDescription ?? "Couldn't send — check your connection."
    }

    /// Create the Firestore chat document for a locally created chat, addressed by the
    /// participants' real Firebase uids. Idempotent.
    private func ensureRemoteChat(for chatID: UUID) async throws {
        guard let store, let chat = store.chat(chatID), let myUID = currentUID else {
            throw SyncError.unknownChat
        }

        // Local ids are one-way hashes of uids, so the uid has to come from the stored
        // profile. A contact never matched to an Inditalk account has none.
        let uids: [String] = try chat.participantIDs.map { participant in
            if participant == store.currentUser.id { return myUID }
            guard let uid = store.users[participant]?.remoteUID, !uid.isEmpty else {
                throw SyncError.participantNotOnInditalk
            }
            return uid
        }

        // Direct chats carry no server-side title: `chat.title` is the PEER's name as seen
        // from this device, so persisting it would show the other person their own name.
        // Each client derives the title from the participants instead (see mapChat).
        let title = chat.kind == .group ? chat.title : ""

        try await FirestoreService.shared.ensureChat(
            chatId: chatID.uuidString,
            kind: chat.kind.rawValue,
            title: title,
            participantIds: uids,
            adminIds: chat.kind == .group ? [myUID] : []
        )
    }

    // MARK: Status sync (users/{uid}/statuses <-> DataStore.statuses)

    /// Upload a newly posted status: media bytes (photo/video) to the owner-writable
    /// status/{uid}/ Storage folder, then the doc under our profile — the same
    /// broadcast surface as presence and the avatar, which is why contacts' listeners
    /// (subscribeStatuses) can see it.
    private func publishStatus(_ status: StatusUpdate) async {
        do {
            var mediaPath: String?
            if let localName = status.localName, MediaStore.exists(localName) {
                let fileURL = MediaStore.url(for: localName)
                let data = try await Task.detached { try Data(contentsOf: fileURL) }.value
                let fileExt = (localName as NSString).pathExtension
                let path = FirebaseStorageService.shared.statusPath(
                    statusId: status.id.uuidString,
                    ext: fileExt.isEmpty ? "bin" : fileExt.lowercased())
                print("[Inditalk status] uploading \(data.count) bytes -> \(path)")
                _ = try await FirebaseStorageService.shared.upload(data, path: path)
                mediaPath = path
            }
            try await FirestoreService.shared.publishStatus(
                statusId: status.id.uuidString,
                kind: status.kind.rawValue,
                text: status.text,
                paletteIndex: status.paletteIndex,
                mediaPath: mediaPath,
                expiresAt: status.expiresAt)
            print("[Inditalk status] published \(status.kind.rawValue) status \(status.id)")
        } catch {
            print("[Inditalk status] publish failed for \(status.id): \(error)")
            ToastCenter.shared.show("Couldn't post status — check your connection.", pending: false)
        }
    }

    /// Watch one contact's active statuses and mirror them into the store. Attached
    /// for every chat participant; idempotent per uid.
    private func subscribeStatuses(uid: String) {
        guard statusListeners[uid] == nil, uid != currentUID else { return }
        statusListeners[uid] = FirestoreService.shared.listenStatuses(uid: uid) { [weak self] remote in
            guard let self else { return }
            print("[Inditalk status] \(uid): \(remote.count) active status(es) from server")
            var downloads: [PendingStatusDownload] = []
            let domain = remote.compactMap { self.mapStatus($0, authorUID: uid, downloads: &downloads) }
            self.store?.ingest(remoteStatuses: domain, from: Self.stableUUID(uid))
            for download in downloads { self.startStatusDownload(download) }
        }
    }

    // MARK: Status view receipts ("seen by")

    /// Viewer side: record that we watched a contact's status, under the AUTHOR's copy
    /// of it. Needs the author's uid — statuses ingested from a contact always carry an
    /// author we already resolved a profile (and uid) for.
    private func publishStatusView(_ status: StatusUpdate) async {
        guard let authorUID = store?.users[status.userID]?.remoteUID else {
            print("[Inditalk status] no uid for author \(status.userID); view receipt skipped")
            return
        }
        let name = store?.currentUser.displayName ?? ""
        do {
            try await FirestoreService.shared.markStatusViewed(
                authorUid: authorUID, statusId: status.id.uuidString, displayName: name)
        } catch {
            print("[Inditalk status] view receipt failed for \(status.id): \(error)")
        }
    }

    /// Author side: keep one views listener per own active status, adding and removing
    /// them as statuses are posted, deleted, or expire. Driven off the store's published
    /// statuses so every one of those paths is covered by a single reconcile.
    private func observeOwnStatuses(store: DataStore) {
        store.$statuses
            .map { [weak store] all -> Set<UUID> in
                guard let store else { return [] }
                return Set(all.filter { $0.userID == store.currentUser.id && !$0.isExpired }
                              .map(\.id))
            }
            .removeDuplicates()
            .sink { [weak self] ids in self?.reconcileStatusViewListeners(ids) }
            .store(in: &storeObservers)
    }

    private func reconcileStatusViewListeners(_ ids: Set<UUID>) {
        for (id, listener) in statusViewListeners where !ids.contains(id) {
            listener.remove()
            statusViewListeners.removeValue(forKey: id)
        }
        for id in ids where statusViewListeners[id] == nil {
            guard let listener = FirestoreService.shared.listenStatusViews(
                statusId: id.uuidString, { [weak self] views in
                    self?.store?.setStatusViewers(views.compactMap(Self.mapStatusView), for: id)
                }) else { continue }
            statusViewListeners[id] = listener
        }
    }

    private static func mapStatusView(_ r: RemoteStatusView) -> StatusViewer? {
        guard let uid = r.id else { return nil }
        return StatusViewer(id: stableUUID(uid),
                            displayName: r.displayName,
                            viewedAt: r.viewedAt?.dateValue() ?? Date())
    }

    private struct PendingStatusDownload {
        let statusID: UUID
        let path: String
        let localName: String
    }

    private func mapStatus(_ r: RemoteStatus, authorUID: String,
                           downloads: inout [PendingStatusDownload]) -> StatusUpdate? {
        guard let idString = r.id, let id = UUID(uuidString: idString) else { return nil }
        var localName: String?
        if let mediaPath = r.mediaPath {
            let ext = (mediaPath as NSString).pathExtension
            let name = "status-\(idString).\(ext.isEmpty ? "bin" : ext)"
            if MediaStore.exists(name) {
                localName = name
            } else {
                downloads.append(PendingStatusDownload(statusID: id, path: mediaPath, localName: name))
            }
        }
        return StatusUpdate(
            id: id,
            userID: Self.stableUUID(authorUID),
            kind: StatusKind(rawValue: r.kind) ?? .text,
            text: r.text,
            localName: localName,
            paletteIndex: r.paletteIndex,
            createdAt: r.createdAt?.dateValue() ?? Date(),
            expiresAt: r.expiresAt.dateValue()
        )
    }

    private func startStatusDownload(_ download: PendingStatusDownload) {
        guard !activeStatusDownloads.contains(download.statusID) else { return }
        activeStatusDownloads.insert(download.statusID)
        print("[Inditalk status] downloading \(download.path)")
        Task { [weak self] in
            defer { self?.activeStatusDownloads.remove(download.statusID) }
            do {
                let data = try await FirebaseStorageService.shared.download(
                    path: download.path, maxBytes: Int64(Self.maxAttachmentBytes))
                // Use the name the store actually kept — identical bytes are shared with
                // whatever already holds them rather than written a second time.
                guard let stored = MediaStore.saveData(data, named: download.localName) else { return }
                print("[Inditalk status] downloaded \(data.count) bytes -> \(stored)")
                self?.store?.attachDownloadedStatusMedia(statusID: download.statusID,
                                                         localName: stored)
            } catch {
                print("[Inditalk status] media download failed for \(download.statusID): \(error)")
            }
        }
    }

    /// Launch-time hygiene: expired statuses are invisible to contacts (their listeners
    /// filter on expiresAt) but the docs/blobs linger — remove our own.
    private func pruneOwnExpiredStatuses() async {
        guard let expired = try? await FirestoreService.shared.fetchOwnExpiredStatuses(),
              !expired.isEmpty else { return }
        for status in expired {
            guard let id = status.id else { continue }
            // try? flattens the String? return: nil = failed OR no media to remove.
            if let path = try? await FirestoreService.shared.deleteStatus(statusId: id) {
                try? await FirebaseStorageService.shared.delete(path: path)
            }
        }
        print("[Inditalk status] pruned \(expired.count) expired own status(es)")
    }

    // MARK: Mapping (server -> domain)

    private func mapChat(_ r: RemoteChat) -> Chat? {
        guard let idString = r.id, let id = UUID(uuidString: idString) else { return nil }
        let kind = ChatKind(rawValue: r.kind) ?? .direct
        let participantIDs = r.participantIds.map(Self.stableUUID)
        return Chat(
            id: id,
            kind: kind,
            title: resolvedTitle(for: r, kind: kind, participantIDs: participantIDs),
            avatarAsset: nil,
            participantIDs: participantIDs,
            lastActivity: r.lastActivity?.dateValue() ?? Date(),
            disappearingSeconds: r.disappearingSeconds
        )
    }

    /// A direct chat's name is per-viewer — each side sees the OTHER person — so it is
    /// derived here rather than read from the shared document. Groups have one real
    /// shared title and use it as-is.
    ///
    /// Falls back to the peer's phone number, then a neutral placeholder, so a chat whose
    /// participant profile hasn't synced yet still shows something sensible instead of an
    /// empty row. `refreshParticipants` fills the name in moments later.
    private func resolvedTitle(for r: RemoteChat, kind: ChatKind, participantIDs: [UUID]) -> String {
        guard kind == .direct else { return r.title }
        guard let store else { return r.title }

        let peerID = participantIDs.first { $0 != store.currentUser.id }
        if let peer = peerID.flatMap({ store.users[$0] }) {
            if !peer.displayName.isEmpty { return peer.displayName }
            if !peer.phoneNumber.isEmpty { return peer.phoneNumber }
        }
        // Keep any existing local title rather than blanking a row the user already sees.
        if let existing = store.chat(UUID(uuidString: r.id ?? "") ?? UUID())?.title, !existing.isEmpty {
            return existing
        }
        return r.title.isEmpty ? "Inditalk user" : r.title
    }

    /// A media blob to fetch once its message row exists locally.
    private struct PendingMediaDownload {
        let messageID: UUID
        let chatID: UUID
        let path: String
        let keyB64: String
        let localName: String
    }

    private func mapMessage(_ r: RemoteMessage, chatID: UUID) async -> (Message, PendingMediaDownload?)? {
        guard let idString = r.id, let id = UUID(uuidString: idString) else { return nil }
        let isOutgoing = r.senderId == currentUID
        let kind = MessageKind(rawValue: r.kind) ?? .text

        // Sender tombstoned it ("delete for everyone"): the ciphertext is already
        // cleared server-side, so there is nothing to decrypt — just carry the flag.
        if r.deleted == true {
            return (Message(id: id, chatID: chatID, senderID: Self.stableUUID(r.senderId),
                            kind: .text, text: "", sentAt: r.sentAt?.dateValue() ?? Date(),
                            state: isOutgoing ? .delivered : .read, isOutgoing: isOutgoing,
                            isDeleted: true), nil)
        }

        var text = await decryptBody(r.ciphertext, chatID: chatID)
        var attachment: Attachment?
        var download: PendingMediaDownload?

        // Attachment kinds carry a MediaEnvelope inside the ciphertext: surface its
        // caption as the message text and rebuild the attachment. A local copy whose
        // attachment already has its file (our own optimistic send, or a finished
        // download) is left alone — ingest keeps the existing attachment.
        if kind != .text, kind != .system, text != Message.failedDecryptionText,
           let envelope = MediaEnvelope.decode(text) {
            text = envelope.caption
            let existing = store?.messages(in: chatID).first { $0.id == id }
            if existing?.attachment?.localName == nil {
                (attachment, download) = materialize(envelope, messageId: idString, chatID: chatID)
            }
        }
        let message = Message(
            id: id,
            chatID: chatID,
            senderID: Self.stableUUID(r.senderId),
            kind: kind,
            text: text,
            sentAt: r.sentAt?.dateValue() ?? Date(),
            // Starting point only. Outgoing mail is assumed delivered once the server
            // holds it (Inditalk has no separate per-device delivery receipt), and inbound
            // messages we can see are read locally. The `receipts` listener then
            // upgrades outgoing messages to .read for real — see applyReceipts. The
            // state machine never regresses, so this optimistic seed can only be
            // improved on by a genuine receipt, never used to undo one.
            state: isOutgoing ? .delivered : .read,
            isOutgoing: isOutgoing,
            // The reply link is plaintext metadata on the doc (like kind/sentAt);
            // dropping it here was why receivers never saw reply quotes.
            replyToID: r.replyTo.flatMap(UUID.init(uuidString:)),
            attachment: attachment
        )
        return (message, download)
    }

    /// Domain attachment from a wire envelope. When the media blob isn't on disk yet
    /// the attachment comes back WITHOUT `localName` (the bubble shows its placeholder)
    /// plus a pending download; `attachDownloadedMedia` upgrades the row when it lands.
    private func materialize(_ envelope: MediaEnvelope, messageId: String,
                             chatID: UUID) -> (Attachment, PendingMediaDownload?) {
        guard let mediaPath = envelope.mediaPath, let keyB64 = envelope.mediaKey,
              let messageUUID = UUID(uuidString: messageId) else {
            return (envelope.attachment(localName: nil), nil)   // location/contact/sample asset
        }
        // Already on disk: this device SENT the media (its own echo came back), or an
        // earlier snapshot downloaded it — possibly under a shared content-addressed
        // name. Without this check the sender re-downloaded its own photo and stored a
        // second copy of it, which is what made the Storage totals double-count.
        if let existing = store?.attachmentLocalName(for: messageUUID), MediaStore.exists(existing) {
            return (envelope.attachment(localName: existing), nil)
        }
        let name = MediaEnvelope.localMediaName(messageId: messageId, ext: envelope.ext)
        if MediaStore.exists(name) {
            return (envelope.attachment(localName: name), nil)
        }
        let download = PendingMediaDownload(messageID: messageUUID, chatID: chatID,
                                            path: mediaPath, keyB64: keyB64, localName: name)
        return (envelope.attachment(localName: nil), download)
    }

    /// Fetch + decrypt one attachment in the background, then point the ingested
    /// message at the finished file. Deduped by message id across snapshots. The
    /// store's mediaPhases mirror progress so the bubble can show a spinner while
    /// in flight and a tap-to-retry state on failure.
    private func startMediaDownload(_ download: PendingMediaDownload) {
        guard !activeMediaDownloads.contains(download.messageID) else { return }
        guard let keyData = Data(base64Encoded: download.keyB64) else {
            print("[Inditalk media] bad media key for message \(download.messageID)")
            return
        }
        activeMediaDownloads.insert(download.messageID)
        store?.setMediaPhase(.downloading, for: download.messageID)
        print("[Inditalk media] downloading \(download.path) for message \(download.messageID)")
        Task { [weak self] in
            defer { self?.activeMediaDownloads.remove(download.messageID) }
            do {
                let sealed = try await FirebaseStorageService.shared.download(
                    path: download.path, maxBytes: Int64(Self.maxAttachmentBytes))
                let aad = MediaEnvelope.mediaAAD(messageId: download.messageID.uuidString)
                let data = try await Task.detached {
                    try CryptoService.shared.open(sealed, key: SymmetricKey(data: keyData), aad: aad)
                }.value
                guard let self else { return }
                guard let stored = MediaStore.saveData(data, named: download.localName) else {
                    self.failedDownloads[download.messageID] = download
                    self.store?.setMediaPhase(.failed, for: download.messageID)
                    return
                }
                print("[Inditalk media] downloaded \(data.count) bytes for message \(download.messageID) "
                      + "-> \(stored)")
                self.store?.setMediaPhase(nil, for: download.messageID)
                // `stored` may be an existing file with identical contents (the same photo
                // forwarded into several chats), so the message points at THAT.
                self.store?.attachDownloadedMedia(messageID: download.messageID,
                                                  in: download.chatID,
                                                  localName: stored)
            } catch {
                print("[Inditalk media] download FAILED for message \(download.messageID) "
                      + "(\(download.path)): \(error)")
                self?.failedDownloads[download.messageID] = download
                self?.store?.setMediaPhase(.failed, for: download.messageID)
            }
        }
    }

    /// Decrypt a stored body — Double Ratchet session first, then the agreed pair key
    /// (cross-device path for direct chats), then the interim device-local key (own
    /// messages sent before pair keys existed, and groups).
    private func decryptBody(_ ciphertext: String, chatID: UUID) async -> String {
        // `sessionDecrypt` returns String?; `try?` flattens (not String??), so a single
        // binding is correct here.
        if let text = try? E2EESessionStore.shared.sessionDecrypt(ciphertext, chatID: chatID) {
            return text
        }
        if let peerUID = peerUID(for: chatID) {
            do {
                let key = try await ChatPairKey.shared.key(chatID: chatID, peerUID: peerUID)
                if let text = try? MessageCrypto.shared.decrypt(ciphertext, chatID: chatID, key: key) {
                    return text
                }
            } catch {
                print("[Inditalk crypto] pair key unavailable for chat \(chatID) (peer \(peerUID)): \(error)")
            }
        }
        if let text = try? MessageCrypto.shared.decrypt(ciphertext, chatID: chatID) {
            return text
        }
        print("[Inditalk crypto] decrypt failed for chat \(chatID): no key opened the ciphertext "
              + "(peer=\(peerUID(for: chatID) ?? "unknown"))")
        return Message.failedDecryptionText
    }

    /// The Firebase uid the chat key is agreed with (direct chats only). Prefers the
    /// server-provided participant list; falls back to the locally stored profile for
    /// chats created on this device that haven't echoed back yet.
    private func peerUID(for chatID: UUID) -> String? {
        if let cached = directPeerUID[chatID] { return cached }
        guard let store, let chat = store.chat(chatID), chat.kind == .direct else { return nil }
        let peer = chat.participantIDs.first { $0 != store.currentUser.id }.flatMap { store.users[$0] }
        guard let uid = peer?.remoteUID, !uid.isEmpty else { return nil }
        directPeerUID[chatID] = uid
        return uid
    }

    /// Deterministically derive a domain UUID from a Firebase uid string (which is not
    /// itself a UUID) so remote senders map to stable local identifiers.
    static func stableUUID(_ firebaseUID: String) -> UUID {
        var digest = SHA256.hash(data: Data(firebaseUID.utf8)).makeIterator()
        var bytes = [UInt8]()
        for _ in 0..<16 { bytes.append(digest.next() ?? 0) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
