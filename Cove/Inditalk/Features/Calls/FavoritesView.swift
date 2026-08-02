//
//  FavoritesView.swift
//  Inditalk
//
//  The Calls tab Favorites sheet: one-tap voice/video calling for pinned contacts,
//  swipe to unfavorite, and an "add favorite" picker over the remaining contacts.
//

import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if store.favoriteUsers.isEmpty {
                    EmptyStateView(symbol: "heart",
                                   title: "No favorites yet",
                                   message: "Add your frequent contacts for one-tap calls.",
                                   actionTitle: "Add favorite") { showAdd = true }
                } else {
                    list
                }
            }
            .background(Palette.background)
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(Palette.pine)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Palette.pine)
                    .accessibilityLabel("Add favorite")
                }
            }
        }
        .tint(Palette.pine)
        .sheet(isPresented: $showAdd) { AddFavoriteSheet() }
    }

    private var list: some View {
        List {
            ForEach(store.favoriteUsers) { user in
                row(user)
                    .listRowBackground(Palette.surface)
                    .swipeActions(edge: .trailing) {
                        Button { store.toggleFavorite(user.id) } label: {
                            Label("Remove", systemImage: "heart.slash")
                        }
                        .tint(Palette.danger)
                    }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
    }

    private func row(_ user: InditalkUser) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: user.displayName, imageName: user.avatarAsset,
                       localName: user.avatarLocalName, size: Metrics.avatarSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(user.about)
                    .font(.inditalkCaption()).foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { call(user, media: .voice) } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 17)).foregroundStyle(Palette.pine)
                    .frame(width: 38, height: 38)
                    .background(Palette.pine.opacity(0.10), in: Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Voice call \(user.displayName)")
            Button { call(user, media: .video) } label: {
                Image(systemName: "video.fill")
                    .font(.system(size: 16)).foregroundStyle(Palette.pine)
                    .frame(width: 38, height: 38)
                    .background(Palette.pine.opacity(0.10), in: Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Video call \(user.displayName)")
        }
        .padding(.vertical, 2)
    }

    private func call(_ user: InditalkUser, media: CallMedia) {
        // Real call via CallCenter (RootView presents LiveCallView off its state);
        // CallLauncher explains every unreachable case instead of faking a call.
        CallLauncher.call(user: user, video: media == .video, store: store)
    }
}

/// Picker over contacts who aren't favorites yet; tapping hearts them immediately,
/// so several can be added in one pass.
private struct AddFavoriteSheet: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [InditalkUser] {
        let base = store.users.values.filter { !$0.isFavorite && $0.id != store.currentUser.id }
        let filtered = query.isEmpty ? Array(base)
            : base.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        return filtered.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty && query.isEmpty {
                    EmptyStateView(symbol: "heart.fill",
                                   title: "All contacts added",
                                   message: "Everyone you know is already a favorite.")
                } else {
                    List {
                        ForEach(candidates) { user in
                            Button {
                                store.toggleFavorite(user.id)
                                Haptics.selection()
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarView(name: user.displayName, imageName: user.avatarAsset,
                                               localName: user.avatarLocalName, size: Metrics.avatarSmall)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(user.displayName).foregroundStyle(Palette.textPrimary)
                                        Text(user.about)
                                            .font(.inditalkCaption())
                                            .foregroundStyle(Palette.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "heart").foregroundStyle(Palette.pine)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Palette.surface)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(Palette.background)
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search contacts")
                }
            }
            .background(Palette.background)
            .navigationTitle("Add favorite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.pine)
                }
            }
        }
        .tint(Palette.pine)
    }
}

#Preview {
    FavoritesView().environmentObject(DataStore.inMemory())
}
