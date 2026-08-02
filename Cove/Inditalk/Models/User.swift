//
//  User.swift
//  Inditalk
//

import Foundation

/// A person on Inditalk (the local user or a contact).
struct InditalkUser: Identifiable, Hashable, Codable {
    let id: UUID
    var displayName: String
    var phoneNumber: String
    var about: String
    var avatarAsset: String?     // mock asset name; nil -> initials disc
    var avatarLocalName: String? // MediaStore photo (real user-set avatar); wins over avatarAsset
    var avatarURL: String?       // remote profile photo (users/{uid}.avatarURL) for contacts
    var isVerified: Bool         // official/business style badge
    var isFavorite: Bool         // pinned to the Calls tab "Favorites" section
    var presence: PresenceSnapshot
    /// Firebase Auth uid for this person, when known.
    ///
    /// Local ids are UUIDs derived from the uid via SHA-256 (see
    /// `FirebaseSyncCoordinator.stableUUID`), which is one-way — so anything that has to
    /// address the *server* identity (placing a call, resolving a scanned QR code,
    /// linking a contact) needs the uid kept alongside. nil for purely local contacts
    /// that have not been matched to an Inditalk account yet.
    var remoteUID: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        phoneNumber: String,
        about: String = "Available",
        avatarAsset: String? = nil,
        avatarLocalName: String? = nil,
        avatarURL: String? = nil,
        isVerified: Bool = false,
        isFavorite: Bool = false,
        presence: PresenceSnapshot = .init(isOnline: false, lastSeen: nil, shares: true),
        remoteUID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.phoneNumber = phoneNumber
        self.about = about
        self.avatarAsset = avatarAsset
        self.avatarLocalName = avatarLocalName
        self.avatarURL = avatarURL
        self.isVerified = isVerified
        self.isFavorite = isFavorite
        self.presence = presence
        self.remoteUID = remoteUID
    }
}

/// Codable snapshot of presence (the `Presence` enum is the view-facing form).
struct PresenceSnapshot: Hashable, Codable {
    var isOnline: Bool
    var lastSeen: Date?
    var shares: Bool          // privacy: does this user share last-seen with us

    var resolved: Presence {
        guard shares else { return .hidden }
        if isOnline { return .online }
        if let lastSeen { return .lastSeen(lastSeen) }
        return .hidden
    }
}

/// Privacy settings for the local account.
struct PrivacySettings: Codable, Equatable {
    enum Visibility: String, Codable, CaseIterable, Identifiable {
        case everyone, contacts, nobody
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everyone: return "Everyone"
            case .contacts: return "My Contacts"
            case .nobody: return "Nobody"
            }
        }
    }

    var lastSeen: Visibility = .contacts
    var profilePhoto: Visibility = .everyone
    var about: Visibility = .everyone
    var readReceipts: Bool = true
    var blockedUserIDs: Set<UUID> = []
    var defaultDisappearingSeconds: Int = 0   // 0 = off; e.g. 86_400 = 24h
}
