//
//  Enums.swift
//  Inditalk
//
//  Shared enumerations used across the domain models.
//

import Foundation

/// Delivery lifecycle of an outgoing message. Drives the check-mark UI.
/// Transition graph (see MessageStateMachine in Phase 2):
/// composing -> sending -> sent -> delivered -> read
///                     \-> failed (-> retry -> sending)
enum MessageState: String, Codable, CaseIterable {
    case sending      // in outbox, not yet acked by server
    case sent         // server acked (single check)
    case delivered    // reached recipient device (double check)
    case read         // recipient opened (double check, accent-tinted)
    case failed       // send failed, retry available
}

/// What a message carries.
enum MessageKind: String, Codable {
    case text
    case image
    case video
    case document
    case voiceNote
    case location
    case contactCard
    case system       // encryption notice, "you turned off disappearing messages", etc.
}

/// Direction of a call as shown in history.
enum CallDirection: String, Codable {
    case incoming
    case outgoing
    case missed
}

enum CallMedia: String, Codable {
    case voice
    case video
}

/// Live call state machine (Phase 4 / CallKit).
enum CallState: String, Codable {
    case idle, dialing, ringing, connecting, active, held, ended, failed
}

enum ChatKind: String, Codable {
    case direct
    case group
    case broadcast   // official/business style (verified) channels
}

/// Presence shown in chat headers ("online", "last seen …").
enum Presence: Equatable {
    case online
    case lastSeen(Date)
    case hidden          // user disabled last-seen sharing (privacy setting)
}
