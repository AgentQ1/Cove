//
//  ForwardSheet.swift
//  Inditalk
//
//  Chat picker for forwarding a message. Multi-select the destination conversations;
//  each gets a new outgoing copy of the message (text or attachment) via
//  DataStore.forward.
//

import SwiftUI

struct ForwardSheet: View {
    let message: Message
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var query = ""

    private var chats: [Chat] {
        // Blocked contacts' chats can't receive messages, so don't offer them as targets.
        let all = store.visibleChats.filter { !store.isBlockedChat($0.id) }
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(query.lowercased()) }
    }

    /// A media message whose bytes haven't finished downloading can't be re-uploaded —
    /// forwarding it would deliver a permanently empty bubble to the destination.
    private var mediaNotReady: Bool {
        switch message.kind {
        case .image, .video, .document, .voiceNote:
            guard let attachment = message.attachment else { return true }
            if let localName = attachment.localName, MediaStore.exists(localName) { return false }
            return attachment.assetName == nil   // bundled sample assets forward fine
        default:
            return false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search sits at the TOP, like WhatsApp's forward picker. A `.searchable`
                // modifier would be pinned to the BOTTOM bar on iOS 26, which reads as a
                // different screen entirely.
                searchField
                messageSummary

                List {
                    Section {
                        ForEach(chats) { chat in
                            Button { toggle(chat.id) } label: { row(chat) }
                                .buttonStyle(.plain)
                                .listRowBackground(Palette.surface)
                        }
                    } header: {
                        Text(query.isEmpty ? "Recent chats" : "Results")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Palette.background)

                // The send control lives in a bottom bar that appears with the first
                // selection (WhatsApp), rather than a nav-bar "Send".
                if !selected.isEmpty { sendBar }
            }
            .background(Palette.background)
            .navigationTitle("Forward to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.ink)
                }
            }
        }
        .tint(Palette.ink)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textSecondary)
            TextField("Search chats", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Palette.textPrimary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.searchCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.searchCorner).strokeBorder(Palette.separator, lineWidth: 1))
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.vertical, 12)
    }

    /// What's being forwarded — a compact chip above the list, so the preview never
    /// competes with the recipient rows for space.
    private var messageSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let symbol = MessageBubbleView.summarySymbol(for: message) {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ochre)
                }
                Text(MessageBubbleView.summaryText(for: message))
                    .font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            if mediaNotReady {
                Label("Wait for the media to finish downloading before forwarding.",
                      systemImage: "arrow.down.circle")
                    .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.bottom, 4)
    }

    /// Selected recipients on the left, one filled circular send button on the right.
    private var sendBar: some View {
        HStack(spacing: 12) {
            Text(selectionSummary)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(width: 48, height: 48)
                    .background(Palette.ink, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(mediaNotReady)
            .opacity(mediaNotReady ? 0.5 : 1)
            .accessibilityLabel("Send to \(selected.count) chat\(selected.count == 1 ? "" : "s")")
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Palette.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.separator).frame(height: 0.5)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Names of the chosen chats, collapsing to a count once the list would overflow.
    private var selectionSummary: String {
        let names = store.visibleChats.filter { selected.contains($0.id) }.map(\.title)
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }

    private func row(_ chat: Chat) -> some View {
        let isSelected = selected.contains(chat.id)
        return HStack(spacing: 12) {
            AvatarView(name: chat.title,
                       imageName: chat.avatarAsset,
                       localName: store.otherParticipant(in: chat)?.avatarLocalName,
                       remoteURL: store.otherParticipant(in: chat)?.avatarURL,
                       systemImage: chat.kind == .group ? "person.2.fill" : nil,
                       size: Metrics.avatarSmall)
            Text(chat.title).foregroundStyle(Palette.textPrimary)
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(isSelected ? Palette.ink : Palette.textSecondary.opacity(0.5))
        }
        .contentShape(Rectangle())
    }

    private func toggle(_ id: UUID) {
        withAnimation(.snappy(duration: 0.2)) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        }
        Haptics.selection()
    }

    private func send() {
        store.forward(message, to: Array(selected))
        Haptics.impact(.light)
        ToastCenter.shared.show("Forwarded to \(selected.count) chat\(selected.count == 1 ? "" : "s")",
                                pending: false)
        dismiss()
    }
}
