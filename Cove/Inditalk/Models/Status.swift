//
//  Status.swift
//  Inditalk
//
//  Ephemeral status updates ("Updates" tab): a text card or a photo/video that
//  expires 24 hours after posting. Value type mirrors the other domain models;
//  persistence lives in PersistedStatus behind DataStore.
//

import Foundation

/// What a status update carries.
enum StatusKind: String, Codable {
    case text
    case photo
    case video
}

/// A single ephemeral status update posted by a user.
struct StatusUpdate: Identifiable, Hashable, Codable {
    let id: UUID
    var userID: UUID
    var kind: StatusKind
    var text: String            // body for text statuses, caption for media
    var localName: String?      // MediaStore file for photo/video statuses
    var paletteIndex: Int       // background color index for text cards
    var createdAt: Date
    var expiresAt: Date
    var isViewed: Bool          // local "seen" flag for other people's updates

    init(
        id: UUID = UUID(),
        userID: UUID,
        kind: StatusKind = .text,
        text: String = "",
        localName: String? = nil,
        paletteIndex: Int = 0,
        createdAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(86_400),
        isViewed: Bool = false
    ) {
        self.id = id
        self.userID = userID
        self.kind = kind
        self.text = text
        self.localName = localName
        self.paletteIndex = paletteIndex
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isViewed = isViewed
    }

    var isExpired: Bool { expiresAt < Date() }
}

/// Someone who watched one of the current user's statuses — the "seen by" list.
///
/// Not persisted: view receipts live on the server under the status document and are
/// only meaningful while the status is alive (24h), so the store holds them in memory
/// for as long as the author's listener is attached.
struct StatusViewer: Identifiable, Hashable {
    let id: UUID            // the viewer's local (stable) user id
    var displayName: String
    var viewedAt: Date
}
