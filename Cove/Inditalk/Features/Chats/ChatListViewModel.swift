//
//  ChatListViewModel.swift
//  Inditalk
//
//  Owns chat-list UI state (search text, scope) and the pure filtering/sorting
//  logic. Kept free of SwiftUI so it is unit-testable (see ChatListViewModelTests).
//

import Foundation
import Combine

@MainActor
final class ChatListViewModel: ObservableObject {
    @Published var searchText: String = ""

    struct Row: Identifiable, Equatable {
        let chat: Chat
        let preview: String
        let previewGlyph: PreviewGlyph?   // leading icon for attachment / call-log rows
        let stamp: String
        let isDelivered: Bool          // show receipt tick on our own last message
        let avatarURL: String?         // direct chats: the peer's uploaded profile photo
        var id: UUID { chat.id }
    }

    /// Build display rows from the store's chats, applying search + pin ordering.
    func rows(store: DataStore, now: Date = Date()) -> [Row] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = store.visibleChats

        let filtered = query.isEmpty ? source : source.filter { chat in
            chat.title.lowercased().contains(query)
                || store.messages(in: chat.id).contains { $0.text.lowercased().contains(query) }
        }

        return filtered.map { makeRow(for: $0, store: store, now: now) }
    }

    /// Rows for the Archived screen (no search scope; store already sorts them).
    func archivedRows(store: DataStore, now: Date = Date()) -> [Row] {
        store.archivedChats.map { makeRow(for: $0, store: store, now: now) }
    }

    private func makeRow(for chat: Chat, store: DataStore, now: Date) -> Row {
        let last = store.messages(in: chat.id).last
        return Row(
            chat: chat,
            preview: store.previewLine(for: chat),
            previewGlyph: glyph(for: last, kind: chat.kind),
            stamp: RelativeDate.listStamp(chat.lastActivity, now: now),
            isDelivered: (last?.isOutgoing ?? false),
            avatarURL: store.otherParticipant(in: chat)?.avatarURL
        )
    }

    /// Attachments and call-log rows get a leading glyph; plain text doesn't.
    private func glyph(for message: Message?, kind: ChatKind) -> PreviewGlyph? {
        guard let message, !message.isDeleted else { return nil }

        if let attachment = PreviewGlyph.attachment(for: message.kind) { return attachment }
        guard message.kind == .system else { return nil }

        switch message.text {
        case "Voice call":        return PreviewGlyph(symbol: "phone.arrow.up.right", style: .call)
        case "Group call":        return PreviewGlyph(symbol: "video.fill", style: .call)
        case "Missed video call": return PreviewGlyph(symbol: "video.slash.fill", style: .missedCall)
        case "Missed voice call": return PreviewGlyph(symbol: "phone.arrow.down.left", style: .missedCall)
        default:                  return nil
        }
    }
}

/// The small icon in front of a chat row's preview line.
struct PreviewGlyph: Equatable {
    /// How it is tinted: an attachment icon sits with the preview text, a call-log icon
    /// is an accent, and a missed call is a warning.
    enum Style { case attachment, call, missedCall }

    let symbol: String
    let style: Style
    // No colour here on purpose: this file stays SwiftUI-free so it remains unit
    // testable. ChatRowView maps the style to a tint.

    /// The icon standing in for an attachment's content ("Photo", "Video", a file name).
    /// nil for text, which needs no icon. Shared by every list that shows messages out
    /// of context, so they can't drift apart.
    static func attachment(for kind: MessageKind) -> PreviewGlyph? {
        switch kind {
        case .image:       return PreviewGlyph(symbol: "camera.fill", style: .attachment)
        case .video:       return PreviewGlyph(symbol: "video.fill", style: .attachment)
        case .document:    return PreviewGlyph(symbol: "doc.fill", style: .attachment)
        case .voiceNote:   return PreviewGlyph(symbol: "mic.fill", style: .attachment)
        case .location:    return PreviewGlyph(symbol: "location.fill", style: .attachment)
        case .contactCard: return PreviewGlyph(symbol: "person.crop.circle.fill", style: .attachment)
        case .text, .system: return nil
        }
    }
}
