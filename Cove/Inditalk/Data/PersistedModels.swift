//
//  PersistedModels.swift
//  Inditalk
//
//  SwiftData @Model classes that back the value-type domain models. The app's
//  currency stays the plain structs (InditalkUser/Chat/Message/CallRecord) — these
//  persistent classes are an implementation detail behind DataStore. Each maps to and
//  from its domain type so the rest of the app never imports SwiftData.
//
//  String-raw enums (ChatKind, MessageKind, MessageState, …) are stored directly
//  (SwiftData supports RawRepresentable-String enums). Codable value types
//  (Reaction, Attachment) are stored as composite properties.
//

import Foundation
import SwiftData

// MARK: - User

@Model
final class PersistedUser {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var phoneNumber: String
    var about: String
    var avatarAsset: String?
    var isVerified: Bool
    var isOnline: Bool
    var lastSeen: Date?
    var sharesPresence: Bool
    // Added after first release — declaration defaults keep migration lightweight.
    var isFavorite: Bool = false
    var avatarLocalName: String? = nil
    /// Firebase Auth uid — needed to address this person on the server (calls, QR).
    var remoteUID: String? = nil
    /// Remote profile photo URL from users/{uid}.avatarURL (contacts' avatars).
    var avatarURL: String? = nil

    init(from u: InditalkUser) {
        id = u.id
        displayName = u.displayName
        phoneNumber = u.phoneNumber
        about = u.about
        avatarAsset = u.avatarAsset
        isVerified = u.isVerified
        isOnline = u.presence.isOnline
        lastSeen = u.presence.lastSeen
        sharesPresence = u.presence.shares
        isFavorite = u.isFavorite
        avatarLocalName = u.avatarLocalName
        remoteUID = u.remoteUID
        avatarURL = u.avatarURL
    }

    func toDomain() -> InditalkUser {
        InditalkUser(id: id, displayName: displayName, phoneNumber: phoneNumber, about: about,
                 avatarAsset: avatarAsset, avatarLocalName: avatarLocalName,
                 avatarURL: avatarURL,
                 isVerified: isVerified, isFavorite: isFavorite,
                 presence: PresenceSnapshot(isOnline: isOnline, lastSeen: lastSeen, shares: sharesPresence),
                 remoteUID: remoteUID)
    }
}

// MARK: - Status

@Model
final class PersistedStatus {
    @Attribute(.unique) var id: UUID = UUID()
    var userID: UUID = UUID()
    var kind: StatusKind = StatusKind.text
    var text: String = ""
    var localName: String? = nil
    var paletteIndex: Int = 0
    var createdAt: Date = Date.now
    var expiresAt: Date = Date.now
    var isViewed: Bool = false

    init(from s: StatusUpdate) {
        id = s.id
        userID = s.userID
        kind = s.kind
        text = s.text
        localName = s.localName
        paletteIndex = s.paletteIndex
        createdAt = s.createdAt
        expiresAt = s.expiresAt
        isViewed = s.isViewed
    }

    func toDomain() -> StatusUpdate {
        StatusUpdate(id: id, userID: userID, kind: kind, text: text, localName: localName,
                     paletteIndex: paletteIndex, createdAt: createdAt, expiresAt: expiresAt,
                     isViewed: isViewed)
    }
}

// MARK: - Scheduled call

@Model
final class PersistedScheduledCall {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String = ""
    var chatID: UUID? = nil
    var contactID: UUID? = nil
    var displayName: String = ""
    var media: CallMedia = CallMedia.voice
    var date: Date = Date.now

    init(from c: ScheduledCall) {
        id = c.id
        title = c.title
        chatID = c.chatID
        contactID = c.contactID
        displayName = c.displayName
        media = c.media
        date = c.date
    }

    func toDomain() -> ScheduledCall {
        ScheduledCall(id: id, title: title, chatID: chatID, contactID: contactID,
                      displayName: displayName, media: media, date: date)
    }
}

// MARK: - Chat

@Model
final class PersistedChat {
    @Attribute(.unique) var id: UUID
    var kind: ChatKind
    var title: String
    var avatarAsset: String?
    var participantIDs: [UUID]
    var isVerified: Bool
    var isPinned: Bool
    var isArchived: Bool
    var isMuted: Bool
    var mutedUntil: Date?
    var unreadCount: Int
    var lastActivity: Date
    var disappearingSeconds: Int

    // Flattened group info (nil ownerID => not a group).
    var groupDescription: String?
    var groupAdminIDs: [UUID]?
    var groupOwnerID: UUID?
    var groupInviteCode: String?
    var groupCreatedAt: Date?
    var groupWhoCanSend: GroupPermissions.SendPolicy?
    var groupWhoCanEditInfo: GroupPermissions.SendPolicy?
    var groupWhoCanAddMembers: GroupPermissions.SendPolicy?
    var groupApproveNewMembers: Bool

    @Relationship(deleteRule: .cascade, inverse: \PersistedMessage.chat)
    var messages: [PersistedMessage] = []

    init(from c: Chat) {
        id = c.id
        kind = c.kind
        title = c.title
        avatarAsset = c.avatarAsset
        participantIDs = c.participantIDs
        isVerified = c.isVerified
        isPinned = c.isPinned
        isArchived = c.isArchived
        isMuted = c.isMuted
        mutedUntil = c.mutedUntil
        unreadCount = c.unreadCount
        lastActivity = c.lastActivity
        disappearingSeconds = c.disappearingSeconds
        if let g = c.group {
            groupDescription = g.descriptionText
            groupAdminIDs = Array(g.adminIDs)
            groupOwnerID = g.ownerID
            groupInviteCode = g.inviteCode
            groupCreatedAt = g.createdAt
            groupWhoCanSend = g.permissions.whoCanSend
            groupWhoCanEditInfo = g.permissions.whoCanEditInfo
            groupWhoCanAddMembers = g.permissions.whoCanAddMembers
            groupApproveNewMembers = g.permissions.approveNewMembers
        } else {
            groupApproveNewMembers = false
        }
    }

    func toDomain() -> Chat {
        var group: GroupInfo?
        if let ownerID = groupOwnerID, let code = groupInviteCode {
            group = GroupInfo(
                descriptionText: groupDescription ?? "",
                adminIDs: Set(groupAdminIDs ?? []),
                ownerID: ownerID,
                inviteCode: code,
                createdAt: groupCreatedAt ?? .now,
                permissions: GroupPermissions(
                    whoCanSend: groupWhoCanSend ?? .everyone,
                    whoCanEditInfo: groupWhoCanEditInfo ?? .adminsOnly,
                    whoCanAddMembers: groupWhoCanAddMembers ?? .adminsOnly,
                    approveNewMembers: groupApproveNewMembers))
        }
        return Chat(id: id, kind: kind, title: title, avatarAsset: avatarAsset,
                    participantIDs: participantIDs, isVerified: isVerified,
                    isPinned: isPinned, isArchived: isArchived, isMuted: isMuted,
                    mutedUntil: mutedUntil, unreadCount: unreadCount, lastActivity: lastActivity,
                    group: group, disappearingSeconds: disappearingSeconds)
    }
}

// MARK: - Message

@Model
final class PersistedMessage {
    @Attribute(.unique) var id: UUID
    var chatID: UUID
    var senderID: UUID
    var kind: MessageKind
    var text: String
    var sentAt: Date
    var state: MessageState
    var isOutgoing: Bool
    var replyToID: UUID?
    var reactions: [Reaction]
    var attachment: Attachment?
    var isStarred: Bool
    var isPinned: Bool = false
    /// "Delete for me": the row stays persisted (so server snapshots can't re-insert
    /// the message) but is excluded from every projection.
    var isHiddenLocally: Bool = false
    var editedAt: Date?
    /// Domain `Message.isDeleted` ("this message was deleted" tombstone). Named
    /// `isRetracted` in storage because SwiftData's PersistentModel already exposes an
    /// `isDeleted` (deleted-from-the-context flag) — a stored property with that name
    /// silently loses every write, which made tombstones impossible to persist.
    var isRetracted: Bool = false
    var expiresAt: Date?

    var chat: PersistedChat?

    init(from m: Message) {
        id = m.id
        chatID = m.chatID
        senderID = m.senderID
        kind = m.kind
        text = m.text
        sentAt = m.sentAt
        state = m.state
        isOutgoing = m.isOutgoing
        replyToID = m.replyToID
        reactions = m.reactions
        attachment = m.attachment
        isStarred = m.isStarred
        isPinned = m.isPinned
        isHiddenLocally = false
        editedAt = m.editedAt
        isRetracted = m.isDeleted
        expiresAt = m.expiresAt
    }

    func toDomain() -> Message {
        Message(id: id, chatID: chatID, senderID: senderID, kind: kind, text: text,
                sentAt: sentAt, state: state, isOutgoing: isOutgoing, replyToID: replyToID,
                reactions: reactions, attachment: attachment, isStarred: isStarred,
                isPinned: isPinned, editedAt: editedAt, isDeleted: isRetracted, expiresAt: expiresAt)
    }
}

// MARK: - Call

@Model
final class PersistedCall {
    @Attribute(.unique) var id: UUID
    var chatID: UUID?
    var displayName: String
    var avatarAsset: String?
    var direction: CallDirection
    var media: CallMedia
    var date: Date
    var durationSeconds: Int?
    var isVerified: Bool
    var groupCount: Int
    var participantsSummary: String?

    init(from c: CallRecord) {
        id = c.id
        chatID = c.chatID
        displayName = c.displayName
        avatarAsset = c.avatarAsset
        direction = c.direction
        media = c.media
        date = c.date
        durationSeconds = c.durationSeconds
        isVerified = c.isVerified
        groupCount = c.groupCount
        participantsSummary = c.participantsSummary
    }

    func toDomain() -> CallRecord {
        CallRecord(id: id, chatID: chatID, displayName: displayName, avatarAsset: avatarAsset,
                   direction: direction, media: media, date: date, durationSeconds: durationSeconds,
                   isVerified: isVerified, groupCount: groupCount, participantsSummary: participantsSummary)
    }
}
