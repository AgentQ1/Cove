//
//  BlockedContactsView.swift
//  Inditalk
//
//  Settings › Privacy › Blocked. The real blocked-contact manager: lists blocked
//  users from DataStore.privacy.blockedUserIDs, unblocks with a swipe, and blocks
//  new people from an Add sheet of known (non-self, non-blocked) contacts.
//

import SwiftUI

struct BlockedContactsView: View {
    @EnvironmentObject private var store: DataStore
    @State private var showAddSheet = false

    private var blockedUsers: [InditalkUser] {
        store.privacy.blockedUserIDs
            .compactMap { store.users[$0] }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        Group {
            if blockedUsers.isEmpty {
                EmptyStateView(symbol: "hand.raised.fill", title: "No blocked contacts",
                               message: "Blocked contacts can't call you or send you messages.",
                               actionTitle: "Block a Contact") { showAddSheet = true }
            } else {
                List {
                    Section {
                        ForEach(blockedUsers) { user in
                            ContactSummaryRow(user: user)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { unblock(user) } label: {
                                        Label("Unblock", systemImage: "hand.raised.slash")
                                    }
                                }
                        }
                        .listRowBackground(Palette.surface)
                    } footer: {
                        Text("Swipe a contact to unblock them. Blocked contacts aren't "
                             + "told that you blocked them.")
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Palette.background)
            }
        }
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    .tint(Palette.ink)
                    .accessibilityLabel("Block a contact")
            }
        }
        .sheet(isPresented: $showAddSheet) { BlockContactSheet() }
    }

    private func unblock(_ user: InditalkUser) {
        store.unblock(user.id)
        Haptics.selection()
        ToastCenter.shared.show("Unblocked \(user.displayName)", pending: false)
    }
}

/// Sheet listing every known, non-blocked contact so one can be blocked.
private struct BlockContactSheet: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var candidates: [InditalkUser] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return store.users.values
            .filter { $0.id != store.currentUser.id && !store.privacy.blockedUserIDs.contains($0.id) }
            .filter {
                query.isEmpty
                    || $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.phoneNumber.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    EmptyStateView(symbol: "person.crop.circle.badge.questionmark",
                                   title: "No one to block",
                                   message: searchText.isEmpty
                                       ? "All of your contacts are already blocked."
                                       : "No contacts match your search.")
                } else {
                    List {
                        Section {
                            ForEach(candidates) { user in
                                Button { block(user) } label: {
                                    ContactSummaryRow(user: user)
                                }
                                .buttonStyle(.plain)
                            }
                            .listRowBackground(Palette.surface)
                        } footer: {
                            Text("Blocking stops messages and calls from that contact "
                                 + "on this device.")
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Palette.background)
                }
            }
            .background(Palette.background)
            .navigationTitle("Block a Contact")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search contacts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.ink)
                }
            }
        }
        .tint(Palette.ink)
    }

    private func block(_ user: InditalkUser) {
        store.block(user.id)
        // BACKEND INTEGRATION: block state is local-only; server-side enforcement
        // (FirestoreService) is a documented backend item — see DataStore blocking notes.
        Haptics.impact(.light)
        ToastCenter.shared.show("Blocked \(user.displayName)", pending: false)
        dismiss()
    }
}

/// Avatar + name + phone row shared by the blocked list and the Add sheet.
private struct ContactSummaryRow: View {
    let user: InditalkUser

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: user.displayName, imageName: user.avatarAsset,
                       localName: user.avatarLocalName, size: Metrics.avatarSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(user.phoneNumber)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(user.displayName), \(user.phoneNumber)")
    }
}
