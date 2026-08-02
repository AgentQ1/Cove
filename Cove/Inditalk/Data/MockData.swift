//
//  MockData.swift
//  Inditalk
//
//  TEST/PREVIEW FIXTURES ONLY — compiled out of release builds entirely.
//
//  Inditalk has no demo mode: the shipping app starts empty and is populated exclusively
//  from Firebase (see DataStore.init, which passes `seed: nil`). This fixture exists
//  so unit tests and SwiftUI previews have deterministic content to render, and is
//  fenced in `#if DEBUG` so it can never reach a real app flow or the App Store.
//

import Foundation

#if DEBUG

@MainActor
final class MockData: SeedData {
    static let shared = MockData()

    let currentUser: InditalkUser
    let usersByID: [UUID: InditalkUser]
    let chats: [Chat]
    let calls: [CallRecord]
    let messagesByChat: [UUID: [Message]]
    let statuses: [StatusUpdate]
    let privacy: PrivacySettings

    // Stable IDs so chats/messages/calls can cross-reference contacts.
    static let me = UUID()
    static let jisnu = UUID()
    static let bipin = UUID()
    static let neel = UUID()          // shown as "…" (hidden name) in references
    static let admissions = UUID()    // verified org channel
    static let soham = UUID()
    static let inditalkTeam = UUID()      // official app channel (replaces WhatsApp row)
    static let cadence = UUID()
    static let unknownNumber = UUID()
    static let alexandra = UUID()

    private init() {
        func ago(days: Double = 0, hours: Double = 0, minutes: Double = 0) -> Date {
            Date().addingTimeInterval(-(days * 86_400 + hours * 3_600 + minutes * 60))
        }

        // MARK: Users
        let me = InditalkUser(id: Self.me, displayName: "You", phoneNumber: "+1 (415) 555-0102",
                          about: "On Inditalk", isVerified: false,
                          presence: .init(isOnline: true, lastSeen: nil, shares: true))
        let jisnu = InditalkUser(id: Self.jisnu, displayName: "Jisnu", phoneNumber: "+91 98450 11223",
                             about: "Busy", presence: .init(isOnline: true, lastSeen: nil, shares: true))
        let bipin = InditalkUser(id: Self.bipin, displayName: "Bipin", phoneNumber: "+91 99001 44556",
                             about: "At the gym 🏋️", presence: .init(isOnline: false, lastSeen: ago(hours: 3), shares: true))
        let neel = InditalkUser(id: Self.neel, displayName: "Neel", phoneNumber: "+91 90080 77220",
                            about: "Available", presence: .init(isOnline: false, lastSeen: ago(hours: 20), shares: false))
        let admissions = InditalkUser(id: Self.admissions, displayName: "Crest Admissions",
                                  phoneNumber: "+1 (800) 555-0190", about: "Official admissions desk",
                                  isVerified: true, presence: .init(isOnline: false, lastSeen: nil, shares: false))
        let soham = InditalkUser(id: Self.soham, displayName: "Soham • Illinois Tech",
                             phoneNumber: "+1 (312) 555-7781", about: "Grad student",
                             presence: .init(isOnline: false, lastSeen: ago(days: 2), shares: true))
        let inditalkTeam = InditalkUser(id: Self.inditalkTeam, displayName: "Inditalk Team",
                                phoneNumber: "", about: "Official Inditalk updates", isVerified: true,
                                presence: .init(isOnline: false, lastSeen: nil, shares: false))
        let cadence = InditalkUser(id: Self.cadence, displayName: "Cadence",
                               phoneNumber: "+1 (628) 555-3314", about: "Beach days 🏖️",
                               presence: .init(isOnline: false, lastSeen: ago(days: 1, hours: 2), shares: true))
        let unknown = InditalkUser(id: Self.unknownNumber, displayName: "+91 62091 13218",
                               phoneNumber: "+91 62091 13218", about: "Available",
                               presence: .init(isOnline: false, lastSeen: nil, shares: false))
        let alexandra = InditalkUser(id: Self.alexandra, displayName: "Alexandra Peifer",
                                 phoneNumber: "+1 (206) 555-4820", about: "🌷",
                                 presence: .init(isOnline: false, lastSeen: ago(hours: 5), shares: true))

        let everyone = [me, jisnu, bipin, neel, admissions, soham, inditalkTeam, cadence, unknown, alexandra]
        self.currentUser = me
        self.usersByID = Dictionary(uniqueKeysWithValues: everyone.map { ($0.id, $0) })

        // MARK: Chats (order + subtitles mirror the reference list structure)
        let bipinGroup = GroupInfo(
            descriptionText: "Weekend football crew ⚽️",
            adminIDs: [Self.me, Self.bipin], ownerID: Self.bipin,
            inviteCode: "k7fQ2m", createdAt: ago(days: 40),
            permissions: GroupPermissions()
        )

        let cJisnu = Chat(id: UUID(), title: "Jisnu", participantIDs: [Self.me, Self.jisnu],
                          unreadCount: 0, lastActivity: ago(days: 1, hours: 1))
        let cBipin = Chat(id: UUID(), kind: .group, title: "Bipin", participantIDs: [Self.me, Self.bipin, Self.neel],
                          unreadCount: 0, lastActivity: ago(days: 1, hours: 2), group: bipinGroup)
        let cNeel = Chat(id: UUID(), title: "Neel", participantIDs: [Self.me, Self.neel],
                         unreadCount: 0, lastActivity: ago(days: 1, hours: 3))
        let cAdm = Chat(id: UUID(), title: "Crest Admissions", participantIDs: [Self.me, Self.admissions],
                        isVerified: true, unreadCount: 0, lastActivity: ago(days: 1, hours: 4))
        let cSoham = Chat(id: UUID(), title: "Soham • Illinois Tech", participantIDs: [Self.me, Self.soham],
                          unreadCount: 0, lastActivity: ago(days: 2))
        let cInditalk = Chat(id: UUID(), title: "Inditalk Team", participantIDs: [Self.me, Self.inditalkTeam],
                         isVerified: true, unreadCount: 1, lastActivity: ago(days: 13))
        let cCadence = Chat(id: UUID(), title: "Cadence", participantIDs: [Self.me, Self.cadence],
                            unreadCount: 1, lastActivity: ago(days: 14))
        let cUnknown = Chat(id: UUID(), title: "+91 62091 13218", participantIDs: [Self.me, Self.unknownNumber],
                            lastActivity: ago(days: 16))
        let cAlex = Chat(id: UUID(), title: "Alexandra Peifer", participantIDs: [Self.me, Self.alexandra],
                         isPinned: false, unreadCount: 0, lastActivity: ago(days: 3, hours: 1))

        self.chats = [cJisnu, cBipin, cNeel, cAdm, cSoham, cInditalk, cCadence, cUnknown, cAlex]

        // MARK: Messages
        func sys(_ chat: UUID, _ text: String, _ date: Date) -> Message {
            Message(chatID: chat, senderID: Self.me, kind: .system, text: text,
                    sentAt: date, state: .read, isOutgoing: false)
        }
        func inbound(_ chat: UUID, _ from: UUID, _ text: String, _ date: Date, kind: MessageKind = .text) -> Message {
            Message(chatID: chat, senderID: from, kind: kind, text: text, sentAt: date,
                    state: .read, isOutgoing: false)
        }
        func outbound(_ chat: UUID, _ text: String, _ date: Date, _ state: MessageState = .read) -> Message {
            Message(chatID: chat, senderID: Self.me, text: text, sentAt: date, state: state, isOutgoing: true)
        }

        var m: [UUID: [Message]] = [:]

        // Call-log style previews (appear as the last row line in the chat list).
        m[cJisnu.id] = [sys(cJisnu.id, "Voice call", ago(days: 1, hours: 1))]
        m[cBipin.id] = [sys(cBipin.id, "Video call", ago(days: 1, hours: 2))]
        m[cNeel.id] = [sys(cNeel.id, "Missed video call", ago(days: 1, hours: 3))]
        m[cAdm.id] = [sys(cAdm.id, "Voice call", ago(days: 1, hours: 4))]
        m[cSoham.id] = [sys(cSoham.id, "Voice call", ago(days: 2))]
        m[cInditalk.id] = [inbound(cInditalk.id, Self.inditalkTeam,
                               "New: send message history to people you add to a group, and help new members catch up.",
                               ago(days: 13))]
        m[cCadence.id] = [
            outbound(cCadence.id, "Sorry I had to bail on Saturday — rain check?", ago(days: 14, hours: 1)),
            inbound(cCadence.id, Self.cadence, "No worries! I understand. Maybe we could hit the beach at some point",
                    ago(days: 14))
        ]
        m[cUnknown.id] = [inbound(cUnknown.id, Self.unknownNumber, "Hi, is this the right number for the apartment listing?",
                                  ago(days: 16))]

        // Rich one-to-one thread (mirrors the reference chat detail structure).
        let a = cAlex.id
        m[a] = [
            sys(a, "🔒 Messages and calls are end-to-end encrypted. Only people in this chat can read, listen to, or share them.", ago(days: 6)),
            sys(a, "You use a default timer for disappearing messages in new chats. New messages will disappear 24 hours after they're sent, except when kept.", ago(days: 6, minutes: -1)),
            sys(a, "Alexandra is a contact.", ago(days: 6, minutes: -2)),
            sys(a, "You turned off disappearing messages.", ago(days: 6, minutes: -3)),
            inbound(a, Self.alexandra, "Hi! Oh no, I think you could take it to the mailroom probably!", ago(days: 6, hours: -1)),
            outbound(a, "Hey I went to the postal desk but it was closed so I'll most likely give them the key on Monday. Also keep me updated about tomorrow and what time we're heading ✓", ago(days: 4)),
            inbound(a, Self.alexandra, "Okay yeah that sounds good! You could also give it to me tomorrow if you want and I can give it to the mailroom for you.", ago(days: 3, hours: 2)),
            inbound(a, Self.alexandra, "Tomorrow let's meet at the transit center at 11:20 and leave from there!", ago(days: 3, hours: 1))
        ]

        self.messagesByChat = m

        // MARK: Call history (mirrors the Recent list structure)
        self.calls = [
            CallRecord(chatID: cJisnu.id, displayName: "Jisnu", direction: .outgoing, media: .voice, date: ago(days: 1)),
            CallRecord(chatID: cBipin.id, displayName: "Bipin", direction: .incoming, media: .video,
                       date: ago(days: 1, hours: 1), durationSeconds: 742),
            CallRecord(chatID: cNeel.id, displayName: "Neel", direction: .missed, media: .video, date: ago(days: 1, hours: 2)),
            CallRecord(chatID: cAdm.id, displayName: "Crest Admissions", direction: .outgoing, media: .voice,
                       date: ago(days: 1, hours: 3), durationSeconds: 96, isVerified: true),
            CallRecord(chatID: cAdm.id, displayName: "Crest Admissions", direction: .missed, media: .voice,
                       date: ago(days: 1, hours: 4), isVerified: true),
            CallRecord(chatID: cJisnu.id, displayName: "Jisnu", direction: .missed, media: .voice, date: ago(days: 4)),
            CallRecord(chatID: cBipin.id, displayName: "Bipin", direction: .missed, media: .voice, date: ago(days: 6)),
            CallRecord(chatID: cNeel.id, displayName: "Neel", direction: .outgoing, media: .voice, date: ago(days: 7), durationSeconds: 410),
            CallRecord(chatID: cNeel.id, displayName: "Neel", direction: .missed, media: .voice, date: ago(days: 7, hours: 1)),
            CallRecord(chatID: cSoham.id, displayName: "Soham • Illinois Tech", direction: .missed, media: .voice,
                       date: ago(days: 8))
        ]

        // MARK: Status updates (Updates tab) — a few active text cards from contacts,
        // none for the local user, each expiring 24h after it was "posted".
        self.statuses = [
            StatusUpdate(userID: Self.alexandra, kind: .text, text: "Beach day 🌊",
                         paletteIndex: 2, createdAt: ago(hours: 2),
                         expiresAt: ago(hours: 2).addingTimeInterval(86_400)),
            StatusUpdate(userID: Self.alexandra, kind: .text, text: "Tulip season starts this weekend 🌷",
                         paletteIndex: 4, createdAt: ago(hours: 1),
                         expiresAt: ago(hours: 1).addingTimeInterval(86_400)),
            StatusUpdate(userID: Self.bipin, kind: .text, text: "New deadlift PR at the gym today 🏋️",
                         paletteIndex: 1, createdAt: ago(hours: 5),
                         expiresAt: ago(hours: 5).addingTimeInterval(86_400))
        ]

        self.privacy = PrivacySettings()
    }
}

#endif
