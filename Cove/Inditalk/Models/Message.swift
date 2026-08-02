//
//  Message.swift
//  Inditalk
//

import Foundation

/// A single message in a chat.
struct Message: Identifiable, Hashable, Codable {
    /// Rendered body when a stored ciphertext cannot be opened with any available key.
    /// Central so ingest can recognize it and never overwrite good plaintext with it.
    static let failedDecryptionText = "🔒 Unable to decrypt"

    let id: UUID
    var chatID: UUID
    var senderID: UUID          // matches DataStore.currentUser.id for outgoing
    var kind: MessageKind
    var text: String            // caption for media, body for text, note for system
    var sentAt: Date
    var state: MessageState
    var isOutgoing: Bool
    var replyToID: UUID?        // threaded reply
    var reactions: [Reaction]
    var attachment: Attachment?
    var isStarred: Bool
    var isPinned: Bool          // pinned inside the chat (banner above the transcript)
    var editedAt: Date?
    var isDeleted: Bool         // "This message was deleted"
    var expiresAt: Date?        // disappearing-message expiry

    init(
        id: UUID = UUID(),
        chatID: UUID,
        senderID: UUID,
        kind: MessageKind = .text,
        text: String = "",
        sentAt: Date = Date(),
        state: MessageState = .sent,
        isOutgoing: Bool,
        replyToID: UUID? = nil,
        reactions: [Reaction] = [],
        attachment: Attachment? = nil,
        isStarred: Bool = false,
        isPinned: Bool = false,
        editedAt: Date? = nil,
        isDeleted: Bool = false,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.chatID = chatID
        self.senderID = senderID
        self.kind = kind
        self.text = text
        self.sentAt = sentAt
        self.state = state
        self.isOutgoing = isOutgoing
        self.replyToID = replyToID
        self.reactions = reactions
        self.attachment = attachment
        self.isStarred = isStarred
        self.isPinned = isPinned
        self.editedAt = editedAt
        self.isDeleted = isDeleted
        self.expiresAt = expiresAt
    }
}

/// An emoji reaction with an author.
struct Reaction: Hashable, Codable, Identifiable {
    var id: UUID = UUID()
    var emoji: String
    var userID: UUID
}

/// Media / rich attachment payload. `assetName` points at a bundled sample asset;
/// `localName` points at a file the user actually captured/imported, saved on-device
/// by `MediaStore` (real image/document sending — see MediaStore).
struct Attachment: Hashable, Codable {
    var assetName: String?      // bundled sample image/thumbnail asset
    var localName: String?      // file saved on-device by MediaStore (real user media)
    var durationSeconds: Double?    // voice note / video length
    var waveform: [Float]?          // normalized 0...1 samples for voice notes
    var fileName: String?           // documents (display name)
    var byteSize: Int?
    var latitude: Double?           // location
    var longitude: Double?
    var contactName: String?        // shared contact card
    var contactPhone: String?
}
