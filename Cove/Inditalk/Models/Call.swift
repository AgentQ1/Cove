//
//  Call.swift
//  Inditalk
//

import Foundation

/// A row in the call history screen. Groups of back-to-back calls with the same
/// peer are collapsed with a `groupCount` (e.g. "Bipin (2)").
struct CallRecord: Identifiable, Hashable, Codable {
    let id: UUID
    var chatID: UUID?             // link back to a conversation if one exists
    var displayName: String
    var avatarAsset: String?
    var direction: CallDirection
    var media: CallMedia
    var date: Date
    var durationSeconds: Int?    // nil for missed
    var isVerified: Bool
    var groupCount: Int          // consecutive calls collapsed into this row
    var participantsSummary: String?   // e.g. "Bipin & 2 others" for group calls

    init(
        id: UUID = UUID(),
        chatID: UUID? = nil,
        displayName: String,
        avatarAsset: String? = nil,
        direction: CallDirection,
        media: CallMedia,
        date: Date,
        durationSeconds: Int? = nil,
        isVerified: Bool = false,
        groupCount: Int = 1,
        participantsSummary: String? = nil
    ) {
        self.id = id
        self.chatID = chatID
        self.displayName = displayName
        self.avatarAsset = avatarAsset
        self.direction = direction
        self.media = media
        self.date = date
        self.durationSeconds = durationSeconds
        self.isVerified = isVerified
        self.groupCount = groupCount
        self.participantsSummary = participantsSummary
    }
}
