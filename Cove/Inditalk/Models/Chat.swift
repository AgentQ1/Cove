//
//  Chat.swift
//  Inditalk
//

import Foundation

/// A conversation — direct or group.
struct Chat: Identifiable, Hashable, Codable {
    let id: UUID
    var kind: ChatKind
    var title: String                 // direct: contact name; group: group name
    var avatarAsset: String?
    var participantIDs: [UUID]
    var isVerified: Bool

    // Chat-list organization (Phase 1 UI, richer behavior in Phase 2)
    var isPinned: Bool
    var isArchived: Bool
    var isMuted: Bool
    var mutedUntil: Date?
    var unreadCount: Int
    var lastActivity: Date

    // Group-only metadata
    var group: GroupInfo?

    // Per-chat disappearing-messages timer, in seconds (0 = off).
    var disappearingSeconds: Int

    init(
        id: UUID = UUID(),
        kind: ChatKind = .direct,
        title: String,
        avatarAsset: String? = nil,
        participantIDs: [UUID] = [],
        isVerified: Bool = false,
        isPinned: Bool = false,
        isArchived: Bool = false,
        isMuted: Bool = false,
        mutedUntil: Date? = nil,
        unreadCount: Int = 0,
        lastActivity: Date = Date(),
        group: GroupInfo? = nil,
        disappearingSeconds: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.avatarAsset = avatarAsset
        self.participantIDs = participantIDs
        self.isVerified = isVerified
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.isMuted = isMuted
        self.mutedUntil = mutedUntil
        self.unreadCount = unreadCount
        self.lastActivity = lastActivity
        self.group = group
        self.disappearingSeconds = disappearingSeconds
    }
}

/// Group-specific metadata: admins, invite link, permissions.
struct GroupInfo: Hashable, Codable {
    var descriptionText: String
    var adminIDs: Set<UUID>
    var ownerID: UUID
    var inviteCode: String            // /join/<code>
    var createdAt: Date
    var permissions: GroupPermissions

}

/// Who is allowed to do what in a group.
struct GroupPermissions: Hashable, Codable {
    var whoCanSend: SendPolicy = .everyone
    var whoCanEditInfo: SendPolicy = .adminsOnly
    var whoCanAddMembers: SendPolicy = .adminsOnly
    var approveNewMembers: Bool = false

    enum SendPolicy: String, Codable, CaseIterable, Identifiable {
        case everyone, adminsOnly
        var id: String { rawValue }
        var label: String { self == .everyone ? "All members" : "Only admins" }
    }
}
