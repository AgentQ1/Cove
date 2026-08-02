//
//  PickChatSheet.swift
//  Inditalk
//
//  A reusable single-select chat picker. Used to choose a destination for a captured
//  photo ("share to…") and to choose who to call from the Calls tab.
//

import SwiftUI

struct PickChatSheet: View {
    let title: String
    /// Restricts the list to 1:1 chats. Calling passes `true`: there is no group calling,
    /// so offering a group here would only lead to a dead end.
    var directOnly: Bool = false
    let onPick: (Chat) -> Void

    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var chats: [Chat] {
        // Exclude blocked contacts — they can't receive shares or calls.
        var all = store.visibleChats.filter { !store.isBlockedChat($0.id) }
        if directOnly { all = all.filter { $0.kind == .direct } }
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(query.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(chats) { chat in
                    Button {
                        onPick(chat)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: chat.title, imageName: chat.avatarAsset,
                                       systemImage: chat.kind == .group ? "person.2.fill" : nil,
                                       size: Metrics.avatarSmall)
                            Text(chat.title).foregroundStyle(Palette.textPrimary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Palette.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.ink)
                }
            }
        }
        .tint(Palette.ink)
    }
}
