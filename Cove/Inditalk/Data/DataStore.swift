//
//  DataStore.swift
//  Inditalk
//
//  Single source of truth for the app. Backed by SwiftData for durable local
//  persistence (chats, messages, calls, users survive relaunch); privacy settings
//  persist to UserDefaults. The persistent models are an implementation detail —
//  the UI depends only on the `MessagingStore` protocol and the value-type domain
//  models, so the backing store can change without touching a single view.
//
//  Design: SwiftData is the source of truth; the @Published projections are rebuilt
//  from the context after each mutation, which keeps SwiftUI reactive without
//  scattering @Query across the view layer.
//

import Foundation
import Combine
import SwiftData

@MainActor
protocol MessagingStore: ObservableObject {
    var currentUser: InditalkUser { get }
    var users: [UUID: InditalkUser] { get }
    var chats: [Chat] { get }
    var calls: [CallRecord] { get }
    var privacy: PrivacySettings { get set }

    func messages(in chatID: UUID) -> [Message]
    func chat(_ id: UUID) -> Chat?
    @discardableResult func send(text: String, to chatID: UUID, replyingTo: UUID?) -> Message
    func markRead(_ chatID: UUID)
    func togglePin(_ chatID: UUID)
    func toggleMute(_ chatID: UUID)
    func toggleArchive(_ chatID: UUID)
    func toggleStar(_ messageID: UUID, in chatID: UUID)
    func addReaction(_ emoji: String, to messageID: UUID, in chatID: UUID)
    func deleteMessage(_ messageID: UUID, in chatID: UUID)
    func setDisappearing(seconds: Int, in chatID: UUID)
}

/// Shape of fixture data used ONLY by unit tests and SwiftUI previews. Production
/// initialization passes `nil`, so no seeded content can reach a real app flow.
@MainActor
protocol SeedData {
    var currentUser: InditalkUser { get }
    var usersByID: [UUID: InditalkUser] { get }
    var chats: [Chat] { get }
    var calls: [CallRecord] { get }
    var messagesByChat: [UUID: [Message]] { get }
    var statuses: [StatusUpdate] { get }
    var privacy: PrivacySettings { get }
}

@MainActor
final class DataStore: MessagingStore {

    @Published private(set) var currentUser: InditalkUser
    @Published private(set) var users: [UUID: InditalkUser] = [:]
    @Published private(set) var chats: [Chat] = []
    @Published private(set) var calls: [CallRecord] = []
    @Published private(set) var messagesByChat: [UUID: [Message]] = [:]
    @Published private(set) var statuses: [StatusUpdate] = []
    @Published private(set) var scheduledCalls: [ScheduledCall] = []

    // Privacy is exposed as a settable property (satisfying the protocol) but backed
    // by a @Published store so writes stay reactive AND persist.
    @Published private var _privacy: PrivacySettings
    var privacy: PrivacySettings {
        get { _privacy }
        set {
            let previous = _privacy
            _privacy = newValue
            if persistent { Self.savePrivacy(newValue) }
            // Visibility choices are only real once the backend copy changes — a setting
            // that stays on the device would let contacts keep seeing the photo/about/
            // last-seen it was supposed to hide.
            if previous.lastSeen != newValue.lastSeen
                || previous.profilePhoto != newValue.profilePhoto
                || previous.about != newValue.about {
                privacySink?(newValue)
            }
        }
    }

    private let context: ModelContext
    private let persistent: Bool
    private var currentUserID: UUID

    /// Optional hook set by the Firebase sync layer: called with each outgoing message
    /// so it can be encrypted + pushed to the backend. When set, the local delivery
    /// simulation is skipped (real receipts drive state). Kept as a plain closure so
    /// this store never imports any backend SDK.
    var remoteSink: ((Message) -> Void)?

    /// Backend hook: called with the updated profile at the end of `updateProfile`
    /// and `updateAvatar` (same plain-closure pattern as `remoteSink`).
    var profileSink: ((InditalkUser) -> Void)?

    /// Backend hook: called with the chat ID in `markRead` so read receipts can be
    /// pushed to the other participants.
    var readSink: ((UUID) -> Void)?

    /// Backend hook: called whenever a visibility setting (Last Seen, Profile Photo,
    /// About) changes, so the sync layer can republish the profile — and withhold the
    /// fields the new setting hides.
    var privacySink: ((PrivacySettings) -> Void)?

    /// Backend hook: called with each newly posted status so it can be uploaded and
    /// published to contacts (same plain-closure pattern as `remoteSink`).
    var statusSink: ((StatusUpdate) -> Void)?

    /// Backend hook: called with the status ID when the user deletes one of their own
    /// statuses, so the remote copy disappears for contacts too.
    var statusDeleteSink: ((UUID) -> Void)?

    /// Backend hook: called with another user's status when the local user watches it,
    /// so a view receipt is published to the AUTHOR's "seen by" list.
    var statusViewedSink: ((StatusUpdate) -> Void)?

    /// Who has watched each of the current user's active statuses, keyed by status id.
    /// In-memory only (see `StatusViewer`) — filled by the sync layer's per-status
    /// listeners and cleared with the status.
    @Published private(set) var statusViewers: [UUID: [StatusViewer]] = [:]

    /// Backend hook: called with (messageID, chatID) when the user deletes one of their
    /// OWN messages, so the server copy is tombstoned for every participant.
    var messageDeleteSink: ((UUID, UUID) -> Void)?

    /// Backend hook: called with (messageID, chatID, emoji) whenever the user's own
    /// reaction to a message changes — `nil` emoji means they removed it. Without this,
    /// reactions are a purely local decoration nobody else ever sees.
    var reactionSink: ((UUID, UUID, String?) -> Void)?

    /// Backend hook: called with the message ID when the user taps a failed
    /// attachment to re-download its media.
    var mediaRetrySink: ((UUID) -> Void)?

    /// Backend hook: called with (userID, isBlocked) when the user blocks or unblocks
    /// someone, so the server copy of the block list stays in step.
    ///
    /// This is not a nicety: the `onCallInvite` Cloud Function checks
    /// `users/{uid}/blocked/{callerUid}` before sending a VoIP push, and that is the ONLY
    /// enforcement point when the callee's app is backgrounded, locked, or not running —
    /// the in-app block check needs a live sync coordinator, which a push-launched app
    /// does not have. An unpublished block list means a blocked contact can still ring a
    /// locked phone.
    var blockSink: ((UUID, Bool) -> Void)?

    /// Live sync phase of a message's media blob — NOT persisted. Drives the bubble's
    /// spinner (downloading) and tap-to-retry (failed) states; absent means the file is
    /// either on disk already or was never remote.
    enum MediaPhase { case downloading, failed }
    @Published private(set) var mediaPhases: [UUID: MediaPhase] = [:]

    func setMediaPhase(_ phase: MediaPhase?, for messageID: UUID) {
        if let phase { mediaPhases[messageID] = phase }
        else { mediaPhases.removeValue(forKey: messageID) }
    }

    func retryMediaDownload(_ messageID: UUID) { mediaRetrySink?(messageID) }

    // MARK: Init

    /// App entry point — durable on-disk store. Starts EMPTY: real content arrives from
    /// Firebase via FirebaseSyncCoordinator. Nothing is ever seeded in production.
    convenience init() {
        self.init(container: PersistenceController.shared, seed: nil, persistent: true)
    }

    /// Ephemeral store for tests/previews — never touches disk/UserDefaults. Seeded with
    /// fixture data in DEBUG only; that data can never reach a shipping build.
    static func inMemory() -> DataStore {
        #if DEBUG
        return DataStore(container: PersistenceController.inMemoryContainer(),
                         seed: MockData.shared, persistent: false)
        #else
        return DataStore(container: PersistenceController.inMemoryContainer(),
                         seed: nil, persistent: false)
        #endif
    }

    /// - Parameter seed: fixture data for tests/previews. ALWAYS nil in app flows.
    init(container: ModelContainer, seed: SeedData?, persistent: Bool) {
        self.context = ModelContext(container)
        self.persistent = persistent

        // The stable local-user ID lives in UserDefaults so profile edits stay attached
        // to the same persisted row across relaunches. Signing in replaces it with the
        // Firebase-derived identity (see `adoptIdentity`).
        let storedID = persistent
            ? UserDefaults.standard.string(forKey: Self.currentUserIDKey).flatMap(UUID.init(uuidString:))
            : nil
        self.currentUserID = storedID ?? seed?.currentUser.id ?? UUID()
        self.currentUser = seed?.currentUser ?? InditalkUser(id: self.currentUserID, displayName: "", phoneNumber: "")
        self._privacy = (persistent ? Self.loadPrivacy() : nil) ?? seed?.privacy ?? PrivacySettings()

        if let seed {
            seedIfNeeded(seed)
            recoverCurrentUserIDIfNeeded(seed)
        }
        reloadAll()
        // Keep the published projection consistent with what is actually persisted.
        if let persisted = users[currentUserID] { currentUser = persisted }
    }

    // MARK: Identity

    /// Backend-free description of the signed-in account. The app layer derives this
    /// from Firebase Auth and hands it in, so this store still imports no backend SDK.
    struct LocalIdentity: Equatable {
        var id: UUID
        var displayName: String
        var phoneNumber: String
        /// The Firebase uid this identity was derived from. Kept verbatim because `id`
        /// is a one-way hash of it, and features like the contact QR code and calling
        /// need the original.
        var remoteUID: String
    }

    /// Point the store at the real signed-in account, persisting a user row for it.
    /// Idempotent — safe to call on every launch and every auth-state change.
    func adoptIdentity(_ identity: LocalIdentity) {
        currentUserID = identity.id
        if persistent {
            UserDefaults.standard.set(identity.id.uuidString, forKey: Self.currentUserIDKey)
        }

        if let existing = persistedUser(identity.id) {
            // Never clobber a name the user has since edited with the auth default.
            if existing.displayName.isEmpty { existing.displayName = identity.displayName }
            if existing.phoneNumber.isEmpty { existing.phoneNumber = identity.phoneNumber }
            existing.remoteUID = identity.remoteUID
        } else {
            context.insert(PersistedUser(from: InditalkUser(id: identity.id,
                                                        displayName: identity.displayName,
                                                        phoneNumber: identity.phoneNumber,
                                                        about: "",
                                                        presence: .init(isOnline: true, lastSeen: nil, shares: true),
                                                        remoteUID: identity.remoteUID)))
        }
        save(); reloadUsers()
        if let me = users[identity.id] { currentUser = me }
    }

    /// Robustness for installs seeded before the stable-ID key existed (or where the
    /// key was lost): if `currentUserID` resolves to no persisted row but rows exist,
    /// re-identify "me" by the seed's (stable) phone number and re-persist the key.
    /// Without this, profile edits silently no-op while the UI still reports success.
    private func recoverCurrentUserIDIfNeeded(_ seed: SeedData) {
        guard persistedUser(currentUserID) == nil else { return }
        let all = (try? context.fetch(FetchDescriptor<PersistedUser>())) ?? []
        guard !all.isEmpty,
              let match = all.first(where: { $0.phoneNumber == seed.currentUser.phoneNumber }) else { return }
        currentUserID = match.id
        if persistent { UserDefaults.standard.set(match.id.uuidString, forKey: Self.currentUserIDKey) }
    }

    // MARK: Seeding

    private func seedIfNeeded(_ seed: SeedData) {
        seedStatusesIfNeeded(seed)

        let existing = (try? context.fetchCount(FetchDescriptor<PersistedChat>())) ?? 0
        guard existing == 0 else { return }

        for user in seed.usersByID.values { context.insert(PersistedUser(from: user)) }
        for chat in seed.chats {
            let pc = PersistedChat(from: chat)
            context.insert(pc)
            for message in seed.messagesByChat[chat.id] ?? [] {
                let pm = PersistedMessage(from: message)
                pm.chat = pc
                context.insert(pm)
            }
        }
        for call in seed.calls { context.insert(PersistedCall(from: call)) }
        save()

        // Remember which seeded user is "me" so later launches (with a different
        // random MockData.me) still resolve the same persisted row.
        currentUserID = seed.currentUser.id
        if persistent {
            UserDefaults.standard.set(seed.currentUser.id.uuidString, forKey: Self.currentUserIDKey)
        }
    }

    /// Statuses ship after the first release, so they get their own seed guard —
    /// gating them on the chat count would skip existing installs forever.
    private func seedStatusesIfNeeded(_ seed: SeedData) {
        let existing = (try? context.fetchCount(FetchDescriptor<PersistedStatus>())) ?? 0
        guard existing == 0 else { return }
        let persisted = (try? context.fetch(FetchDescriptor<PersistedUser>())) ?? []
        for var status in seed.statuses {
            // Seed user IDs are random per process; on an existing install, re-attach
            // the status to the persisted author via the (stable) phone number.
            if !persisted.contains(where: { $0.id == status.userID }),
               let phone = seed.usersByID[status.userID]?.phoneNumber,
               let match = persisted.first(where: { $0.phoneNumber == phone }) {
                status.userID = match.id
            }
            context.insert(PersistedStatus(from: status))
        }
        save()
    }

    // MARK: Projection reloads

    private func reloadAll() {
        reloadUsers(); reloadChats(); reloadCalls(); reloadAllMessages()
        reloadStatuses(); reloadScheduledCalls()
        if let u = users[currentUserID] { currentUser = u }
    }

    private func reloadUsers() {
        let fetched = (try? context.fetch(FetchDescriptor<PersistedUser>())) ?? []
        users = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0.toDomain()) })
    }

    private func reloadChats() {
        let fetched = (try? context.fetch(FetchDescriptor<PersistedChat>())) ?? []
        chats = fetched.map { $0.toDomain() }
    }

    private func reloadCalls() {
        let descriptor = FetchDescriptor<PersistedCall>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        calls = ((try? context.fetch(descriptor)) ?? []).map { $0.toDomain() }
    }

    private func reloadAllMessages() {
        let descriptor = FetchDescriptor<PersistedMessage>(sortBy: [SortDescriptor(\.sentAt, order: .forward)])
        // "Deleted for me" rows stay persisted (so server snapshots can't re-insert
        // them) but never reach a projection.
        let all = ((try? context.fetch(descriptor)) ?? []).filter { !$0.isHiddenLocally }
            .map { $0.toDomain() }
        messagesByChat = Dictionary(grouping: all, by: { $0.chatID })
    }

    private func reloadMessages(_ chatID: UUID) {
        messagesByChat[chatID] = persistedMessages(chatID)
            .filter { !$0.isHiddenLocally }
            .map { $0.toDomain() }
    }

    private func reloadStatuses() {
        let d = FetchDescriptor<PersistedStatus>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        statuses = ((try? context.fetch(d)) ?? []).map { $0.toDomain() }
    }

    private func reloadScheduledCalls() {
        let d = FetchDescriptor<PersistedScheduledCall>(sortBy: [SortDescriptor(\.date, order: .forward)])
        let now = Date()
        scheduledCalls = ((try? context.fetch(d)) ?? []).map { $0.toDomain() }.filter { $0.date > now }
    }

    // MARK: Fetch helpers

    private func persistedChat(_ id: UUID) -> PersistedChat? {
        var d = FetchDescriptor<PersistedChat>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func persistedMessage(_ id: UUID) -> PersistedMessage? {
        var d = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func persistedUser(_ id: UUID) -> PersistedUser? {
        var d = FetchDescriptor<PersistedUser>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func persistedCall(_ id: UUID) -> PersistedCall? {
        var d = FetchDescriptor<PersistedCall>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func persistedStatus(_ id: UUID) -> PersistedStatus? {
        var d = FetchDescriptor<PersistedStatus>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func persistedScheduledCall(_ id: UUID) -> PersistedScheduledCall? {
        var d = FetchDescriptor<PersistedScheduledCall>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func persistedMessages(_ chatID: UUID) -> [PersistedMessage] {
        let d = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.chatID == chatID },
            sortBy: [SortDescriptor(\.sentAt, order: .forward)])
        return (try? context.fetch(d)) ?? []
    }

    private func save() { try? context.save() }

    // MARK: Reads

    func chat(_ id: UUID) -> Chat? { chats.first { $0.id == id } }

    func messages(in chatID: UUID) -> [Message] {
        (messagesByChat[chatID] ?? []).filter { !$0.isExpired }
    }

    func user(_ id: UUID) -> InditalkUser? { users[id] }

    var visibleChats: [Chat] {
        chats.filter { !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.lastActivity > rhs.lastActivity
            }
    }

    var archivedChats: [Chat] {
        chats.filter { $0.isArchived }.sorted { $0.lastActivity > $1.lastActivity }
    }

    var totalUnread: Int { chats.filter { !$0.isArchived }.reduce(0) { $0 + $1.unreadCount } }

    func previewLine(for chat: Chat) -> String {
        guard let last = messages(in: chat.id).last else { return "Tap to chat" }
        return preview(for: last)
    }

    /// One line describing a message, for any list that shows messages out of context
    /// (chat rows, starred messages, search results).
    ///
    /// No emoji: the row draws the attachment's icon itself (see PreviewGlyph), the way
    /// every messenger does it — a tinted glyph matching the row's typography rather
    /// than a full-colour emoji.
    func preview(for message: Message) -> String {
        if message.isDeleted { return "This message was deleted" }
        switch message.kind {
        case .text, .system: return message.text
        case .image: return message.text.isEmpty ? "Photo" : message.text
        case .video: return message.text.isEmpty ? "Video" : message.text
        case .document: return message.attachment?.fileName ?? "Document"
        case .voiceNote: return voiceNotePreview(message)
        case .location: return "Location"
        case .contactCard: return message.attachment?.contactName ?? "Contact"
        }
    }

    /// "Voice message (0:07)" — the length is the useful part of a voice note preview.
    private func voiceNotePreview(_ message: Message) -> String {
        guard let seconds = message.attachment?.durationSeconds, seconds >= 1 else {
            return "Voice message"
        }
        let total = Int(seconds.rounded())
        return String(format: "Voice message (%d:%02d)", total / 60, total % 60)
    }

    func allStarred() -> [Message] {
        let d = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.isStarred && !$0.isRetracted && !$0.isHiddenLocally },
            sortBy: [SortDescriptor(\.sentAt, order: .reverse)])
        return ((try? context.fetch(d)) ?? []).map { $0.toDomain() }
    }

    // MARK: Mutations

    @discardableResult
    func send(text: String, to chatID: UUID, replyingTo: UUID? = nil) -> Message {
        let msg = Message(
            chatID: chatID, senderID: currentUser.id, kind: .text, text: text,
            state: .sending, isOutgoing: true, replyToID: replyingTo,
            expiresAt: disappearingExpiry(for: chatID)
        )
        deliver(msg)
        return msg
    }

    /// Send a media/rich message (image, document, …). Bytes are already persisted by
    /// MediaStore; `attachment.localName` references them so the bubble can render.
    @discardableResult
    func sendAttachment(kind: MessageKind, attachment: Attachment, caption: String = "",
                        to chatID: UUID, replyingTo: UUID? = nil) -> Message {
        let msg = Message(
            chatID: chatID, senderID: currentUser.id, kind: kind, text: caption,
            state: .sending, isOutgoing: true, replyToID: replyingTo,
            attachment: attachment, expiresAt: disappearingExpiry(for: chatID)
        )
        deliver(msg)
        return msg
    }

    /// Forward an existing message's content into one or more chats as new outgoing
    /// messages. Image/document forwards reference the same on-disk file.
    func forward(_ message: Message, to chatIDs: [UUID]) {
        for chatID in chatIDs {
            let msg = Message(
                chatID: chatID, senderID: currentUser.id, kind: message.kind,
                text: message.text, state: .sending, isOutgoing: true,
                attachment: message.attachment, expiresAt: disappearingExpiry(for: chatID)
            )
            deliver(msg)
        }
    }

    /// Shared outgoing path: persist, bump the chat, then either hand off to the
    /// backend sink or run the local delivery-receipt simulation.
    ///
    /// Block enforcement backstop: every outgoing path (text, attachment, forward,
    /// voice note) funnels through here, so a single guard makes blocking real even if
    /// a stale UI path (Forward sheet, share-to-chat, quick-capture) reaches a blocked
    /// contact's chat. The UI additionally hides/disables those affordances.
    private func deliver(_ msg: Message) {
        guard !isBlockedChat(msg.chatID) else { return }
        let pm = PersistedMessage(from: msg)
        pm.chat = persistedChat(msg.chatID)
        context.insert(pm)
        if let pc = persistedChat(msg.chatID) { pc.lastActivity = msg.sentAt }
        save()
        reloadMessages(msg.chatID)
        reloadChats()

        if let remoteSink {
            remoteSink(msg)   // encrypt + push to backend; real receipts drive state
        } else {
            let messageID = msg.id
            let chatID = msg.chatID
            Task { [weak self] in await self?.runDeliveryLifecycle(messageID: messageID, in: chatID) }
        }
    }

    /// Edit an outgoing text message in place, stamping `editedAt` (shows "edited").
    func editMessage(_ messageID: UUID, newText: String, in chatID: UUID) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pm = persistedMessage(messageID),
              pm.isOutgoing, !pm.isRetracted else { return }
        pm.text = trimmed
        pm.editedAt = Date()
        save(); reloadMessages(chatID)
    }

    private func runDeliveryLifecycle(messageID: UUID, in chatID: UUID) async {
        // With read receipts off you don't send yours and don't see theirs, so the
        // simulation stops at .delivered (checked per step so a toggle mid-flight sticks).
        let steps: [(MessageState, Double)] = [(.sent, 0.5), (.delivered, 0.8), (.read, 1.6)]
        for (state, delay) in steps {
            if state == .read && !privacy.readReceipts { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if state == .read && !privacy.readReceipts { return }
            applyReceipt(state, for: messageID, in: chatID)
        }
    }

    /// Merge a delivery receipt, never regressing progress (via the state machine).
    func applyReceipt(_ incoming: MessageState, for messageID: UUID, in chatID: UUID) {
        guard let pm = persistedMessage(messageID) else { return }
        pm.state = MessageStateMachine.merge(current: pm.state, incoming: incoming)
        save()
        reloadMessages(chatID)
    }

    func markRead(_ chatID: UUID) {
        guard let pc = persistedChat(chatID) else { return }
        pc.unreadCount = 0
        save(); reloadChats()
        // Only publish a read receipt to the backend when the user shares them.
        if privacy.readReceipts { readSink?(chatID) }
    }

    func togglePin(_ chatID: UUID) {
        guard let pc = persistedChat(chatID) else { return }
        pc.isPinned.toggle()
        save(); reloadChats()
    }

    func toggleMute(_ chatID: UUID) {
        guard let pc = persistedChat(chatID) else { return }
        pc.isMuted.toggle()
        pc.mutedUntil = pc.isMuted ? Date().addingTimeInterval(8 * 3600) : nil
        save(); reloadChats()
    }

    func toggleArchive(_ chatID: UUID) {
        guard let pc = persistedChat(chatID) else { return }
        pc.isArchived.toggle()
        save(); reloadChats()
    }

    func toggleStar(_ messageID: UUID, in chatID: UUID) {
        guard let pm = persistedMessage(messageID) else { return }
        pm.isStarred.toggle()
        save(); reloadMessages(chatID)
    }

    /// Pin/unpin a message inside its chat (local, like starring). The chat screen
    /// shows the most recently pinned message in a banner above the transcript.
    func togglePinMessage(_ messageID: UUID, in chatID: UUID) {
        guard let pm = persistedMessage(messageID) else { return }
        pm.isPinned.toggle()
        save(); reloadMessages(chatID)
    }

    /// Retry a failed outgoing message: back to `.sending` and through the backend
    /// sink again (the sink re-encrypts and re-uploads any attachment).
    func resend(_ messageID: UUID, in chatID: UUID) {
        guard let pm = persistedMessage(messageID), pm.isOutgoing, pm.state == .failed else { return }
        pm.state = .sending
        save(); reloadMessages(chatID)
        remoteSink?(pm.toDomain())
    }

    func addReaction(_ emoji: String, to messageID: UUID, in chatID: UUID) {
        guard let pm = persistedMessage(messageID) else { return }
        // Tapping the same emoji again removes it; a different one replaces it. The
        // resulting value (nil == removed) is what gets published to the other devices.
        var published: String? = emoji
        if let idx = pm.reactions.firstIndex(where: { $0.userID == currentUser.id }) {
            if pm.reactions[idx].emoji == emoji {
                pm.reactions.remove(at: idx)
                published = nil
            } else {
                pm.reactions[idx].emoji = emoji
            }
        } else {
            pm.reactions.append(Reaction(emoji: emoji, userID: currentUser.id))
        }
        save(); reloadMessages(chatID)
        reactionSink?(messageID, chatID, published)
    }

    /// Merge the complete set of reactions the server holds for a chat, keyed by message
    /// id. The snapshot is authoritative: a message absent from `incoming` has had every
    /// reaction removed, which is how an un-react propagates to other devices.
    ///
    /// Reactions the local user made are included in `incoming` too — Firestore replays
    /// our own pending write in the very first snapshot, so this converges without ever
    /// blanking an optimistic reaction the user just tapped.
    func ingest(remoteReactions incoming: [UUID: [Reaction]], in chatID: UUID) {
        var changed = false
        for pm in persistedMessages(chatID) {
            // A retracted message shows no reactions at all; leave its cleared list be.
            if pm.isRetracted { continue }
            let next = incoming[pm.id] ?? []
            // Compare by content: `Reaction.id` is regenerated on every decode, so
            // comparing the arrays directly would report a change on every snapshot and
            // rewrite the whole chat each time.
            let before = Set(pm.reactions.map { ReactionKey($0) })
            let after = Set(next.map { ReactionKey($0) })
            guard before != after else { continue }
            pm.reactions = next
            changed = true
        }
        if changed { save(); reloadMessages(chatID) }
    }

    /// Identity of a reaction for merge purposes: who reacted, and with what.
    private struct ReactionKey: Hashable {
        let userID: UUID
        let emoji: String
        init(_ r: Reaction) { userID = r.userID; emoji = r.emoji }
    }

    /// Apply a peer's read receipt: every OUTGOING message up to and including
    /// `messageID` has been read. Monotone via the state machine, so a late or
    /// out-of-order receipt can never walk a message back from read to delivered.
    func markOutgoingRead(upTo messageID: UUID, in chatID: UUID) {
        guard let target = persistedMessage(messageID) else { return }
        let cutoff = target.sentAt
        var changed = false
        for pm in persistedMessages(chatID) where pm.isOutgoing && pm.sentAt <= cutoff {
            let merged = MessageStateMachine.merge(current: pm.state, incoming: .read)
            if merged != pm.state {
                pm.state = merged
                changed = true
            }
        }
        if changed { save(); reloadMessages(chatID) }
    }

    /// "Delete for everyone": tombstone the message locally ("This message was
    /// deleted") and — for own messages with a backend — tombstone the server copy so
    /// every participant sees the same. The ingest merge treats deletion as one-way,
    /// so a later snapshot can never resurrect it.
    func deleteMessage(_ messageID: UUID, in chatID: UUID) {
        guard let pm = persistedMessage(messageID) else { return }
        // If the deleted message's voice note is currently playing, stop it — otherwise
        // the audio keeps playing with no bubble/controls left to pause it.
        if AudioPlayerService.shared.playingID == messageID { AudioPlayerService.shared.stop() }
        let wasOutgoing = pm.isOutgoing
        pm.isRetracted = true
        pm.text = ""
        pm.attachment = nil
        pm.reactions = []
        pm.kind = .text
        save(); reloadMessages(chatID)
        if wasOutgoing { messageDeleteSink?(messageID, chatID) }
    }

    /// "Delete for me": hide the message on THIS device only. A hidden row is kept in
    /// the store (so the next server snapshot can't re-insert it) but excluded from
    /// every projection.
    func hideMessage(_ messageID: UUID, in chatID: UUID) {
        guard let pm = persistedMessage(messageID) else { return }
        if AudioPlayerService.shared.playingID == messageID { AudioPlayerService.shared.stop() }
        pm.isHiddenLocally = true
        save(); reloadMessages(chatID)
    }

    func setDisappearing(seconds: Int, in chatID: UUID) {
        guard let pc = persistedChat(chatID) else { return }
        pc.disappearingSeconds = seconds
        let note = seconds == 0
            ? "You turned off disappearing messages."
            : "You set messages to disappear \(DisappearingOption.label(for: seconds).lowercased()) after they're sent."
        let system = Message(chatID: chatID, senderID: currentUser.id, kind: .system,
                             text: note, state: .read, isOutgoing: false)
        let pm = PersistedMessage(from: system)
        pm.chat = pc
        context.insert(pm)
        save(); reloadMessages(chatID); reloadChats()
    }

    func block(_ userID: UUID) {
        privacy.blockedUserIDs.insert(userID)
        blockSink?(userID, true)
    }

    func unblock(_ userID: UUID) {
        privacy.blockedUserIDs.remove(userID)
        blockSink?(userID, false)
    }

    // MARK: Blocking (local enforcement)
    //
    // Block state lives in `privacy.blockedUserIDs` (persisted). These helpers make the
    // enforcement points explicit so the UI can actually disable messaging/calling a
    // blocked contact instead of just recording a flag. Server-side enforcement is a
    // documented backend item — see APP_STORE_DEPLOYMENT_REPORT.md.

    func isBlocked(_ userID: UUID) -> Bool { privacy.blockedUserIDs.contains(userID) }

    /// The counterpart in a direct chat (nil for groups or self-only chats).
    func otherParticipant(in chat: Chat) -> InditalkUser? {
        guard chat.kind == .direct else { return nil }
        let id = chat.participantIDs.first { $0 != currentUser.id }
        return id.flatMap { users[$0] }
    }

    /// True when a direct chat's counterpart is blocked — messaging and calling that
    /// contact must be disabled in the UI until they're unblocked.
    func isBlockedChat(_ chatID: UUID) -> Bool {
        guard let chat = chat(chatID), let other = otherParticipant(in: chat) else { return false }
        return isBlocked(other.id)
    }

    // MARK: Account deletion (local wipe)

    /// Erase ALL locally persisted user data, then re-seed a fresh store. Used by
    /// account deletion (AccountDeletionService). Re-seeding immediately (rather than
    /// waiting for the next cold launch) keeps the live @Published `currentUser` valid,
    /// so profile editing and other flows don't silently no-op on a dangling user after
    /// deletion. Best-effort — never throws.
    func wipeAllLocalData() {
        for pm in (try? context.fetch(FetchDescriptor<PersistedMessage>())) ?? [] { context.delete(pm) }
        for pc in (try? context.fetch(FetchDescriptor<PersistedChat>())) ?? [] { context.delete(pc) }
        for pu in (try? context.fetch(FetchDescriptor<PersistedUser>())) ?? [] { context.delete(pu) }
        for pcall in (try? context.fetch(FetchDescriptor<PersistedCall>())) ?? [] { context.delete(pcall) }
        for ps in (try? context.fetch(FetchDescriptor<PersistedStatus>())) ?? [] { context.delete(ps) }
        for psc in (try? context.fetch(FetchDescriptor<PersistedScheduledCall>())) ?? [] { context.delete(psc) }
        save()
        if persistent {
            UserDefaults.standard.removeObject(forKey: Self.privacyKey)
            UserDefaults.standard.removeObject(forKey: Self.currentUserIDKey)
        }
        _privacy = PrivacySettings()
        // Leave the store genuinely empty — the account is gone, so there is nothing
        // truthful to show. A fresh local identity keeps `currentUser` non-dangling
        // until the next sign-in calls `adoptIdentity`.
        currentUserID = UUID()
        currentUser = InditalkUser(id: currentUserID, displayName: "", phoneNumber: "")
        reloadAll()
    }

    // MARK: Chat / group creation

    /// Open the existing 1:1 with `user`, or create + persist a new one (inheriting
    /// the account-wide default disappearing timer).
    @discardableResult
    func startDirectChat(with user: InditalkUser) -> Chat {
        // Guard against "chat with yourself": every direct chat contains currentUser.id,
        // so a `contains(user.id)` match on the current user would return an arbitrary
        // existing conversation with someone else. Callers should block this UI-side too.
        guard user.id != currentUser.id else {
            return chats.first { $0.kind == .direct && $0.participantIDs.contains(user.id) }
                ?? Chat(kind: .direct, title: user.displayName, participantIDs: [currentUser.id],
                        lastActivity: Date())
        }
        if let existing = chats.first(where: {
            $0.kind == .direct && $0.participantIDs.contains(user.id) && $0.participantIDs.contains(currentUser.id)
        }) { return existing }

        if persistedUser(user.id) == nil { context.insert(PersistedUser(from: user)) }
        let chat = Chat(kind: .direct, title: user.displayName, avatarAsset: user.avatarAsset,
                        participantIDs: [currentUser.id, user.id], isVerified: user.isVerified,
                        lastActivity: Date(),
                        disappearingSeconds: privacy.defaultDisappearingSeconds)
        let pc = PersistedChat(from: chat)
        context.insert(pc)
        insertDefaultTimerNoticeIfNeeded(into: pc)
        save(); reloadUsers(); reloadChats(); reloadMessages(chat.id)
        return chat
    }

    /// Create + persist a new group with the current user as owner/admin (inheriting
    /// the account-wide default disappearing timer).
    @discardableResult
    func createGroup(title: String, memberIDs: [UUID]) -> Chat {
        var participants = Set(memberIDs)
        participants.insert(currentUser.id)
        let group = GroupInfo(
            descriptionText: "", adminIDs: [currentUser.id], ownerID: currentUser.id,
            inviteCode: String(UUID().uuidString.prefix(8)), createdAt: Date(),
            permissions: GroupPermissions())
        let chat = Chat(kind: .group, title: title, participantIDs: Array(participants),
                        lastActivity: Date(), group: group,
                        disappearingSeconds: privacy.defaultDisappearingSeconds)
        let pc = PersistedChat(from: chat)
        context.insert(pc)
        let system = Message(chatID: chat.id, senderID: currentUser.id, kind: .system,
                             text: "You created the group “\(title)”.", state: .read, isOutgoing: false)
        let pm = PersistedMessage(from: system)
        pm.chat = pc
        context.insert(pm)
        insertDefaultTimerNoticeIfNeeded(into: pc)
        save(); reloadChats(); reloadMessages(chat.id)
        return chat
    }

    /// Standard system notice when a new chat inherits the default disappearing timer.
    private func insertDefaultTimerNoticeIfNeeded(into pc: PersistedChat) {
        let seconds = privacy.defaultDisappearingSeconds
        guard seconds > 0 else { return }
        let note = "You use a default timer for disappearing messages in new chats. "
            + "New messages will disappear \(DisappearingOption.label(for: seconds).lowercased()) after they're sent."
        let system = Message(chatID: pc.id, senderID: currentUser.id, kind: .system,
                             text: note, state: .read, isOutgoing: false)
        let pm = PersistedMessage(from: system)
        pm.chat = pc
        context.insert(pm)
    }

    // MARK: Group membership

    /// Add members to a group (deduped), with a "You added…" system notice.
    func addMembers(_ userIDs: [UUID], to chatID: UUID) {
        guard let pc = persistedChat(chatID), pc.kind == .group else { return }
        let added = userIDs.filter { !pc.participantIDs.contains($0) }
        guard !added.isEmpty else { return }
        for id in added where persistedUser(id) == nil {
            if let known = users[id] { context.insert(PersistedUser(from: known)) }
        }
        pc.participantIDs.append(contentsOf: added)
        let note = added.count == 1 ? "You added 1 person." : "You added \(added.count) people."
        let system = Message(chatID: chatID, senderID: currentUser.id, kind: .system,
                             text: note, state: .read, isOutgoing: false)
        let pm = PersistedMessage(from: system)
        pm.chat = pc
        context.insert(pm)
        // BACKEND INTEGRATION: push the membership change to the chat doc when
        // AppConfig.usesFirebase (FirestoreService participant update).
        save(); reloadUsers(); reloadChats(); reloadMessages(chatID)
    }

    /// Leave a group: drop the current user from participants/admins, hand ownership
    /// to the first remaining admin (or first member) if we owned it.
    func leaveGroup(_ chatID: UUID) {
        guard let pc = persistedChat(chatID), pc.kind == .group,
              pc.participantIDs.contains(currentUser.id) else { return }
        pc.participantIDs.removeAll { $0 == currentUser.id }
        var admins = Set(pc.groupAdminIDs ?? [])
        admins.remove(currentUser.id)
        if pc.groupOwnerID == currentUser.id {
            let successor = pc.participantIDs.first(where: { admins.contains($0) })
                ?? pc.participantIDs.first
            if let successor {
                pc.groupOwnerID = successor
                admins.insert(successor)
            }
        }
        pc.groupAdminIDs = Array(admins)
        let system = Message(chatID: chatID, senderID: currentUser.id, kind: .system,
                             text: "You left", state: .read, isOutgoing: false)
        let pm = PersistedMessage(from: system)
        pm.chat = pc
        context.insert(pm)
        // BACKEND INTEGRATION: push the membership change to the chat doc when
        // AppConfig.usesFirebase (FirestoreService participant update).
        save(); reloadChats(); reloadMessages(chatID)
    }

    /// Toggle the group's "approve new members" switch.
    func setGroupApproveNewMembers(_ on: Bool, in chatID: UUID) {
        guard let pc = persistedChat(chatID), pc.kind == .group else { return }
        pc.groupApproveNewMembers = on
        save(); reloadChats()
    }

    // MARK: Call history

    /// Append a finished call to the history (durable).
    func logCall(_ record: CallRecord) {
        context.insert(PersistedCall(from: record))
        save(); reloadCalls()
    }

    func deleteCall(_ id: UUID) {
        guard let pc = persistedCall(id) else { return }
        context.delete(pc)
        save(); reloadCalls()
    }

    // MARK: Profile

    func updateProfile(name: String, about: String) {
        guard let pu = persistedUser(currentUser.id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pu.displayName = trimmed }
        pu.about = about
        save(); reloadUsers()
        if let u = users[currentUser.id] { currentUser = u }
        profileSink?(currentUser)
    }

    /// Persist the phone number the user actually verified during onboarding so the
    /// Profile/Settings header shows it instead of the seeded placeholder.
    func updatePhoneNumber(_ phoneE164: String) {
        let trimmed = phoneE164.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pu = persistedUser(currentUser.id) else { return }
        pu.phoneNumber = trimmed
        save(); reloadUsers()
        if let u = users[currentUser.id] { currentUser = u }
        profileSink?(currentUser)
    }

    /// Set (or, with nil, remove) the current user's profile photo. The bytes are
    /// already in MediaStore; this just re-points the profile and cleans up the old file.
    func updateAvatar(localName: String?) {
        guard let pu = persistedUser(currentUser.id) else { return }
        if let old = pu.avatarLocalName, old != localName { MediaStore.delete(old) }
        pu.avatarLocalName = localName
        save(); reloadUsers()
        if let u = users[currentUser.id] { currentUser = u }
        // BACKEND INTEGRATION: upload the photo via FirebaseStorageService and update
        // the profile doc when AppConfig.usesFirebase.
        profileSink?(currentUser)
    }

    // MARK: Favorites

    func toggleFavorite(_ userID: UUID) {
        guard let pu = persistedUser(userID) else { return }
        pu.isFavorite.toggle()
        save(); reloadUsers()
    }

    var favoriteUsers: [InditalkUser] {
        users.values.filter(\.isFavorite)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: Contacts

    /// Add a contact by name + phone. Dedupes on normalized phone number so saving an
    /// existing contact twice returns the original user.
    @discardableResult
    func addContact(name: String, phone: String) -> InditalkUser {
        if let existing = user(withPhone: phone) { return existing }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = InditalkUser(displayName: trimmed.isEmpty ? phone : trimmed,
                               phoneNumber: phone,
                               presence: .init(isOnline: false, lastSeen: nil, shares: false))
        context.insert(PersistedUser(from: contact))
        save(); reloadUsers()
        // BACKEND INTEGRATION: look the number up in the user directory when
        // AppConfig.usesFirebase so the contact links to a real account.
        return contact
    }

    /// Find a known user by phone number (digits-only, last-10 comparison).
    func user(withPhone phone: String) -> InditalkUser? {
        let target = ContactsService.normalized(phone: phone)
        guard !target.isEmpty else { return nil }
        return users.values.first {
            ContactsService.phonesMatch(ContactsService.normalized(phone: $0.phoneNumber), target)
        }
    }

    // MARK: Status updates

    /// Post a status from the current user (expires 24h from now).
    @discardableResult
    func postStatus(kind: StatusKind, text: String, localName: String?, paletteIndex: Int) -> StatusUpdate {
        let status = StatusUpdate(userID: currentUser.id, kind: kind, text: text,
                                  localName: localName, paletteIndex: paletteIndex)
        context.insert(PersistedStatus(from: status))
        save(); reloadStatuses()
        statusSink?(status)   // upload media + publish to contacts (Firebase mode)
        return status
    }

    /// The current user's non-expired statuses, oldest first.
    var myActiveStatuses: [StatusUpdate] {
        statuses.filter { $0.userID == currentUser.id && !$0.isExpired }
    }

    /// Other users' non-expired statuses grouped per author (updates oldest first),
    /// authors with the freshest update first.
    var othersActiveStatuses: [(user: InditalkUser, updates: [StatusUpdate])] {
        let active = statuses.filter { $0.userID != currentUser.id && !$0.isExpired }
        return Dictionary(grouping: active, by: \.userID)
            .compactMap { userID, updates -> (user: InditalkUser, updates: [StatusUpdate])? in
                guard let user = users[userID] else { return nil }
                return (user, updates)
            }
            .sorted { ($0.updates.last?.createdAt ?? .distantPast) > ($1.updates.last?.createdAt ?? .distantPast) }
    }

    func markStatusViewed(_ id: UUID) {
        guard let ps = persistedStatus(id), ps.userID != currentUser.id else { return }
        let status = ps.toDomain()
        if !ps.isViewed {
            ps.isViewed = true
            save(); reloadStatuses()
        }
        // Fires even when the local flag was already set: the receipt is a merge-upsert,
        // so re-opening a status is how a publish that failed while offline recovers.
        statusViewedSink?(status)
    }

    /// Replace the "seen by" list for one of the current user's statuses (author side).
    func setStatusViewers(_ viewers: [StatusViewer], for statusID: UUID) {
        statusViewers[statusID] = viewers.sorted { $0.viewedAt > $1.viewedAt }
    }

    /// The people who watched `statusID`, newest first. Empty for others' statuses.
    func viewers(of statusID: UUID) -> [StatusViewer] { statusViewers[statusID] ?? [] }

    func deleteStatus(_ id: UUID) {
        guard let ps = persistedStatus(id) else { return }
        let isMine = ps.userID == currentUser.id
        if let localName = ps.localName { MediaStore.delete(localName) }
        context.delete(ps)
        statusViewers.removeValue(forKey: id)
        save(); reloadStatuses()
        if isMine { statusDeleteSink?(id) }   // remove the published copy too
    }

    /// Merge one remote author's ACTIVE statuses (the server snapshot is the complete
    /// truth for that author): upsert by id, preserve the local viewed flag, and drop
    /// local rows the server no longer has — deleted by the author or expired.
    func ingest(remoteStatuses incoming: [StatusUpdate], from userID: UUID) {
        guard userID != currentUser.id else { return }
        let existing = (try? context.fetch(FetchDescriptor<PersistedStatus>(
            predicate: #Predicate { $0.userID == userID }))) ?? []
        let incomingIDs = Set(incoming.map(\.id))

        for ps in existing where !incomingIDs.contains(ps.id) {
            if let localName = ps.localName { MediaStore.delete(localName) }
            context.delete(ps)
        }
        for status in incoming {
            if let ps = existing.first(where: { $0.id == status.id }) {
                ps.text = status.text
                ps.paletteIndex = status.paletteIndex
                ps.expiresAt = status.expiresAt
                // A media file that arrived since the last snapshot fills in; never
                // detach one we already have.
                if ps.localName == nil { ps.localName = status.localName }
                // isViewed stays local — the server doesn't know what we've seen.
            } else {
                context.insert(PersistedStatus(from: status))
            }
        }
        save(); reloadStatuses()
    }

    /// Point an already-ingested status at its downloaded media file and refresh, so
    /// the Updates tab re-renders the moment the bytes land.
    func attachDownloadedStatusMedia(statusID: UUID, localName: String) {
        guard let ps = persistedStatus(statusID), ps.localName == nil else { return }
        ps.localName = localName
        save(); reloadStatuses()
    }

    // MARK: Scheduled calls

    func scheduleCall(_ call: ScheduledCall) {
        context.insert(PersistedScheduledCall(from: call))
        save(); reloadScheduledCalls()
    }

    func deleteScheduledCall(_ id: UUID) {
        guard let psc = persistedScheduledCall(id) else { return }
        context.delete(psc)
        save(); reloadScheduledCalls()
    }

    // MARK: Remote ingestion (Firebase sync bridge)
    //
    // The FirebaseSyncCoordinator maps + decrypts remote docs into these domain
    // values, so this layer stays free of any backend types. Both methods upsert
    // (dedup by id) so re-delivered snapshots don't create duplicates.

    func ingest(remoteChats incoming: [Chat]) {
        for chat in incoming {
            if let pc = persistedChat(chat.id) {
                pc.title = chat.title
                pc.participantIDs = chat.participantIDs
                pc.lastActivity = chat.lastActivity
                pc.disappearingSeconds = chat.disappearingSeconds
                pc.avatarAsset = chat.avatarAsset
                pc.isVerified = chat.isVerified
            } else {
                context.insert(PersistedChat(from: chat))
            }
        }
        save(); reloadChats()
    }

    /// Merge server-side profiles for people we share chats with. Server data wins for
    /// presence and identity, but a locally chosen contact name is preserved — the user
    /// naming someone "Mum" shouldn't be overwritten by their own display name.
    func ingest(remoteUsers incoming: [InditalkUser]) {
        for user in incoming {
            guard user.id != currentUserID else { continue }
            if let pu = persistedUser(user.id) {
                if pu.displayName.isEmpty { pu.displayName = user.displayName }
                if pu.phoneNumber.isEmpty { pu.phoneNumber = user.phoneNumber }
                pu.about = user.about
                pu.isOnline = user.presence.isOnline
                pu.lastSeen = user.presence.lastSeen
                pu.sharesPresence = user.presence.shares
                pu.remoteUID = user.remoteUID ?? pu.remoteUID
                // Server value wins outright — nil means the photo was removed.
                pu.avatarURL = user.avatarURL
            } else {
                context.insert(PersistedUser(from: user))
            }
        }
        save(); reloadUsers()
    }

    func ingest(remoteMessages incoming: [Message], in chatID: UUID) {
        let chatRef = persistedChat(chatID)
        for message in incoming {
            // A blocked contact must not be able to reach you. They are never told they
            // were blocked (so their client keeps writing to the chat) — the enforcement
            // that matters is here, on the receiving device: their messages are dropped
            // instead of persisted, so they never appear or raise an unread badge.
            if !message.isOutgoing, isBlocked(message.senderID) { continue }
            if let pm = persistedMessage(message.id) {
                pm.state = MessageStateMachine.merge(current: pm.state, incoming: message.state)
                // Deletion is ONE-WAY: a tombstone (remote "delete for everyone", or a
                // local delete whose server write hasn't echoed yet) must never be
                // resurrected by a later snapshot re-delivering the original body.
                if message.isDeleted, !pm.isRetracted {
                    pm.isRetracted = true
                    pm.text = ""
                    pm.attachment = nil
                    pm.reactions = []
                }
                if pm.isRetracted { continue }
                // Never replace real plaintext with the decrypt-failure placeholder —
                // a transient key miss must not destroy an already-decrypted message.
                // The reverse (placeholder -> plaintext) always applies, which is how
                // persisted failures self-heal once the key agreement succeeds.
                let clobbersPlaintext = message.text == Message.failedDecryptionText
                    && !pm.text.isEmpty && pm.text != Message.failedDecryptionText
                if !clobbersPlaintext { pm.text = message.text }
                // A reply link that only decrypted/arrived on a later snapshot fills in.
                if pm.replyToID == nil { pm.replyToID = message.replyToID }
                // Attachment metadata that decrypted on a later snapshot (e.g. after a
                // key agreement) fills in, and a metadata-only row upgrades once the
                // media file exists locally. An attachment that already has its file is
                // never replaced — the sender's own local copy stays authoritative.
                if pm.attachment == nil {
                    pm.attachment = message.attachment
                } else if pm.attachment?.localName == nil,
                          let incoming = message.attachment, incoming.localName != nil {
                    pm.attachment = incoming
                }
            } else {
                let pm = PersistedMessage(from: message)
                pm.chat = chatRef
                context.insert(pm)
            }
        }
        save(); reloadMessages(chatID)
    }

    /// The media file a message already references, if any. The sync layer checks this
    /// before scheduling a download so bytes this device already holds are never fetched
    /// (and stored) a second time.
    func attachmentLocalName(for messageID: UUID) -> String? {
        persistedMessage(messageID)?.attachment?.localName
    }

    /// Point an already-ingested message's attachment at its downloaded media file and
    /// refresh the chat, so the bubble re-renders the moment the bytes land.
    func attachDownloadedMedia(messageID: UUID, in chatID: UUID, localName: String) {
        guard let pm = persistedMessage(messageID),
              var attachment = pm.attachment, attachment.localName == nil else { return }
        attachment.localName = localName
        pm.attachment = attachment
        save(); reloadMessages(chatID)
    }

    // MARK: Storage management

    /// Drop references to media files that have been deleted from disk, so nothing
    /// renders an attachment whose bytes are gone. The message itself is kept — only its
    /// attachment is detached — because deleting freed-up media shouldn't erase the
    /// conversation.
    /// Where a stored media file came from, for the Storage browser's per-file label.
    /// A file can be referenced by several messages once identical media is stored once
    /// (see MediaStore's content addressing), so `chatTitles` may hold more than one.
    struct MediaOrigin {
        var chatTitles: [String] = []
        var senderName: String = ""
        var sentAt: Date = .distantPast
        var referenceCount = 0

        var label: String {
            guard !chatTitles.isEmpty else { return "Not in any chat" }
            let where_ = chatTitles.count == 1 ? chatTitles[0]
                                               : "\(chatTitles[0]) +\(chatTitles.count - 1) more"
            return senderName.isEmpty ? where_ : "\(senderName) • \(where_)"
        }
    }

    /// Map every stored media file to the message(s) referencing it. One pass over the
    /// persisted messages, so the Storage screen doesn't query per file.
    func mediaOrigins() -> [String: MediaOrigin] {
        var origins: [String: MediaOrigin] = [:]
        let chatTitle = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0.title) })

        for pm in (try? context.fetch(FetchDescriptor<PersistedMessage>())) ?? [] {
            guard let localName = pm.attachment?.localName else { continue }
            var origin = origins[localName] ?? MediaOrigin()
            origin.referenceCount += 1
            if let chatID = pm.chat?.id, let title = chatTitle[chatID],
               !origin.chatTitles.contains(title) {
                origin.chatTitles.append(title)
            }
            if pm.sentAt > origin.sentAt {
                origin.sentAt = pm.sentAt
                origin.senderName = pm.isOutgoing ? "You"
                    : (users[pm.senderID]?.displayName ?? "")
            }
            origins[localName] = origin
        }

        for ps in (try? context.fetch(FetchDescriptor<PersistedStatus>())) ?? [] {
            guard let localName = ps.localName else { continue }
            var origin = origins[localName] ?? MediaOrigin()
            origin.referenceCount += 1
            if !origin.chatTitles.contains("Status") { origin.chatTitles.append("Status") }
            origins[localName] = origin
        }
        return origins
    }

    func detachDeletedMedia(named removed: [String]) {
        guard !removed.isEmpty else { return }
        let gone = Set(removed)

        var touchedChats: Set<UUID> = []
        for pm in (try? context.fetch(FetchDescriptor<PersistedMessage>())) ?? [] {
            guard let localName = pm.attachment?.localName, gone.contains(localName) else { continue }
            pm.attachment = nil
            if let chatID = pm.chat?.id { touchedChats.insert(chatID) }
        }

        for ps in (try? context.fetch(FetchDescriptor<PersistedStatus>())) ?? [] {
            guard let localName = ps.localName, gone.contains(localName) else { continue }
            context.delete(ps)   // a photo/video status with no media has nothing to show
        }

        save()
        for chatID in touchedChats { reloadMessages(chatID) }
        reloadStatuses()
    }

    // MARK: Helpers

    private func disappearingExpiry(for chatID: UUID) -> Date? {
        guard let seconds = chat(chatID)?.disappearingSeconds, seconds > 0 else { return nil }
        return Date().addingTimeInterval(TimeInterval(seconds))
    }

    private static let privacyKey = "cove.privacy.v1"
    private static let currentUserIDKey = "cove.currentUserID"
    private static func savePrivacy(_ p: PrivacySettings) {
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: privacyKey) }
    }
    private static func loadPrivacy() -> PrivacySettings? {
        guard let data = UserDefaults.standard.data(forKey: privacyKey) else { return nil }
        return try? JSONDecoder().decode(PrivacySettings.self, from: data)
    }
}

extension Message {
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }
}
