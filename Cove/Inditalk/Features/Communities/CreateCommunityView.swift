//
//  CreateCommunityView.swift
//  Inditalk
//
//  Create a community: name it (required) and optionally pick founding members.
//  Locally a community is a group chat persisted via DataStore.createGroup with
//  the current user as owner/admin. Callers receive the created chat via
//  `onCreate` so they can open it (presented as a sheet from Communities/Chats).
//

import SwiftUI

struct CreateCommunityView: View {
    /// Called with the created chat so the caller can dismiss and open it.
    let onCreate: (Chat) -> Void

    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected: Set<UUID> = []
    @State private var query = ""

    private var contacts: [InditalkUser] {
        let all = store.users.values
            .filter { $0.id != store.currentUser.id }
            .sorted { $0.displayName < $1.displayName }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        let digits = ContactsService.normalized(phone: trimmed)
        return all.filter { user in
            user.displayName.localizedCaseInsensitiveContains(trimmed)
                || (!digits.isEmpty && ContactsService.normalized(phone: user.phoneNumber).contains(digits))
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Stable order so the selection strip doesn't reshuffle on every tap.
    private var selectedUsers: [InditalkUser] {
        selected.compactMap { store.users[$0] }.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name your community", text: $name)
                        .foregroundStyle(Palette.textPrimary)
                } header: {
                    Text("Community name")
                } footer: {
                    Text("You can start on your own and add members any time from group info.")
                }
                .listRowBackground(Palette.surface)

                if !selectedUsers.isEmpty {
                    Section {
                        SelectedMembersStrip(users: selectedUsers) { toggle($0) }
                            .listRowInsets(EdgeInsets())
                    }
                    .listRowBackground(Palette.background)
                }

                Section("Add members (\(selected.count)) — optional") {
                    if contacts.isEmpty {
                        Text(query.isEmpty ? "No contacts on Inditalk yet."
                                           : "No contacts match “\(query)”.")
                            .font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
                    }
                    ForEach(contacts) { user in
                        Button { toggle(user.id) } label: { row(user) }
                            .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Palette.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search contacts")
            .navigationTitle("New community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.ink)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.tint(Palette.ink).disabled(!canCreate)
                }
            }
        }
        .tint(Palette.ink)
    }

    private func row(_ user: InditalkUser) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: user.displayName, imageName: user.avatarAsset,
                       localName: user.avatarLocalName, size: Metrics.avatarSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName).foregroundStyle(Palette.textPrimary)
                Text(user.about).font(.system(size: 13)).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: selected.contains(user.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected.contains(user.id) ? Palette.ink : Palette.textSecondary)
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func create() {
        let chat = store.createGroup(title: name.trimmingCharacters(in: .whitespaces),
                                     memberIDs: Array(selected))
        // BACKEND INTEGRATION: create the community document (FirestoreService) once a
        // communities schema exists; locally the community is the group chat above.
        Haptics.impact(.light)
        onCreate(chat)
    }
}
