//
//  NewGroupView.swift
//  Inditalk
//
//  Create a group: pick members from contacts, name it, and create. Backed by
//  DataStore.createGroup (persists a real group chat with the current user as admin).
//

import SwiftUI

struct NewGroupView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    /// Called with the created chat so the caller can open it.
    let onCreate: (Chat) -> Void

    @State private var title = ""
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
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty
    }

    /// Selection in a stable, name-sorted order so the strip doesn't reshuffle on
    /// every tap (a `Set` has no order of its own).
    private var selectedUsers: [InditalkUser] {
        selected.compactMap { store.users[$0] }.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Group name") {
                    TextField("Name this group", text: $title)
                        .foregroundStyle(Palette.textPrimary)
                }
                .listRowBackground(Palette.surface)

                if !selectedUsers.isEmpty {
                    Section {
                        SelectedMembersStrip(users: selectedUsers) { toggle($0) }
                            .listRowInsets(EdgeInsets())
                    }
                    .listRowBackground(Palette.background)
                }

                // No member cap: a group is any number of participants (the only real
                // ceiling is the chat document's own size, thousands of uids away).
                Section("Add members (\(selected.count))") {
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
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search name or number")
            .navigationTitle("New group")
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
            AvatarView(name: user.displayName, imageName: user.avatarAsset, size: Metrics.avatarSmall)
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
        let chat = store.createGroup(title: title.trimmingCharacters(in: .whitespaces),
                                     memberIDs: Array(selected))
        Haptics.impact(.light)
        onCreate(chat)
    }
}
