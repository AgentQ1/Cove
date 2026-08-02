//
//  ArchivedChatsView.swift
//  Inditalk
//
//  Pushed from the chat list's "Archived" row. Shows archived conversations with
//  the same row treatment as the main list; swipe to unarchive, tap to open.
//

import SwiftUI

struct ArchivedChatsView: View {
    @EnvironmentObject private var store: DataStore
    @StateObject private var vm = ChatListViewModel()
    /// Called with the tapped chat so the caller can push its detail screen.
    let onOpen: (Chat) -> Void

    var body: some View {
        Group {
            if store.archivedChats.isEmpty {
                EmptyStateView(symbol: "archivebox",
                               title: "No archived chats",
                               message: "Chats you archive wait here, out of the way of your day-to-day conversations.")
            } else {
                List {
                    ForEach(vm.archivedRows(store: store)) { row in
                        Button {
                            onOpen(row.chat)
                            store.markRead(row.chat.id)
                        } label: {
                            ChatRowView(row: row)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: Metrics.screenPadding, bottom: 0, trailing: Metrics.screenPadding))
                        .listRowBackground(Palette.background)
                        .listRowSeparatorTint(Palette.separator)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in Metrics.avatar + 12 }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                store.toggleArchive(row.chat.id)
                                Haptics.selection()
                            } label: {
                                Label("Unarchive", systemImage: "tray.and.arrow.up")
                            }.tint(Palette.pine)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.background)
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ArchivedChatsView { _ in }
            .environmentObject(DataStore.inMemory())
    }
}
