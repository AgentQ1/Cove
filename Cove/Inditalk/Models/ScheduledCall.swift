//
//  ScheduledCall.swift
//  Inditalk
//
//  A call planned for the future (Calls tab "Schedule call" flow). Purely local:
//  it links back to a chat and/or contact when one exists and is projected by
//  DataStore sorted ascending with past entries filtered out.
//

import Foundation

/// A planned voice/video call at a future date.
struct ScheduledCall: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var chatID: UUID?             // conversation to open when the call starts
    var contactID: UUID?          // counterpart for 1:1 scheduled calls
    var displayName: String       // who the call is with (row subtitle)
    var media: CallMedia
    var date: Date

    init(
        id: UUID = UUID(),
        title: String,
        chatID: UUID? = nil,
        contactID: UUID? = nil,
        displayName: String,
        media: CallMedia = .voice,
        date: Date
    ) {
        self.id = id
        self.title = title
        self.chatID = chatID
        self.contactID = contactID
        self.displayName = displayName
        self.media = media
        self.date = date
    }
}
