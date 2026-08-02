//
//  NewChatView.swift
//  Inditalk
//
//  Contact picker for starting a new conversation. Quick actions (new group, new
//  contact, new community), Inditalk users, and the device address book — loaded via
//  ContactsService with permission — all searchable by name or number.
//

import SwiftUI
import UIKit
import Contacts

struct NewChatView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var contactsService = ContactsService.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @State private var query = ""
    @State private var showNewGroup = false
    @State private var showAddContact = false
    @State private var showNewCommunity = false
    let onSelect: (Chat) -> Void

    var body: some View {
        NavigationStack {
            List {
                quickActionsSection
                onInditalkSection
                addressBookSection
                fallbackSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search name or number")
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.ink)
                }
            }
            .task {
                // Ask + load unless the user has already said no (the recovery card
                // handles that path). Covers notDetermined, authorized, and limited.
                let status = permissions.contacts
                if status != .denied && status != .restricted {
                    await contactsService.requestAndLoad()
                }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView { chat in
                    showNewGroup = false
                    onSelect(chat)
                }
            }
            .sheet(isPresented: $showAddContact) {
                AddContactView { chat in
                    showAddContact = false
                    onSelect(chat)
                }
            }
            .sheet(isPresented: $showNewCommunity) {
                CreateCommunityView { chat in
                    showNewCommunity = false
                    onSelect(chat)
                }
            }
        }
        .tint(Palette.ink)
    }

    // MARK: Sections

    private var quickActionsSection: some View {
        Section {
            Button { showNewGroup = true } label: {
                quickAction("person.2.fill", Palette.pine, "New group")
            }.buttonStyle(.plain)
            Button { showAddContact = true } label: {
                quickAction("person.crop.circle.badge.plus", Palette.ink, "New contact")
            }.buttonStyle(.plain)
            Button { showNewCommunity = true } label: {
                quickAction("person.3.fill", Palette.ochre, "New community")
            }.buttonStyle(.plain)
        }
        .listRowBackground(Palette.surface)
    }

    @ViewBuilder private var onInditalkSection: some View {
        let users = onInditalkUsers
        if !users.isEmpty {
            Section("Contacts on Inditalk") {
                ForEach(users) { user in
                    Button { start(with: user) } label: { contactRow(user) }
                        .buttonStyle(.plain)
                }
            }
            .listRowBackground(Palette.surface)
        }
    }

    @ViewBuilder private var addressBookSection: some View {
        if accessBlocked {
            Section { permissionCard }
                .listRowBackground(Palette.surface)
        } else {
            switch contactsService.state {
            case .loading:
                Section("From your address book") {
                    HStack(spacing: 10) {
                        ProgressView().tint(Palette.ink)
                        Text("Loading your contacts…")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .listRowBackground(Palette.surface)
            case .failed:
                Section("From your address book") {
                    HStack {
                        Text("Couldn't load your contacts.")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Button("Retry") {
                            Task { await contactsService.requestAndLoad() }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .tint(Palette.ink)
                    }
                }
                .listRowBackground(Palette.surface)
            default:
                let contacts = addressBookContacts
                if !contacts.isEmpty {
                    Section("From your address book") {
                        ForEach(contacts) { contact in
                            Button { start(with: contact) } label: { deviceContactRow(contact) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Palette.surface)
                }
            }
        }
    }

    /// Empty / no-results states when neither contact section has rows.
    @ViewBuilder private var fallbackSection: some View {
        if showsFallback {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    EmptyStateView(symbol: "person.crop.circle.badge.questionmark",
                                   title: "No contacts yet",
                                   message: "Add a contact to start your first conversation.",
                                   actionTitle: "New contact") { showAddContact = true }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    Text("No matches for “\(query)”")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    // MARK: Data

    /// Store-known users plus device contacts that resolve to an Inditalk account,
    /// deduped by user id.
    private var onInditalkUsers: [InditalkUser] {
        let storeUsers = Array(store.users.values)
        var seen = Set<UUID>()
        var merged: [InditalkUser] = []
        let mine = storeUsers
            .filter { $0.id != store.currentUser.id }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        for user in mine where seen.insert(user.id).inserted {
            merged.append(user)
        }
        for contact in contactsService.deviceContacts {
            if let match = contactsService.matchUser(for: contact, in: storeUsers),
               match.id != store.currentUser.id,
               seen.insert(match.id).inserted {
                merged.append(match)
            }
        }
        return merged.filter { matchesQuery(name: $0.displayName, phones: [$0.phoneNumber]) }
    }

    /// Device contacts with a phone number that don't map to any Inditalk user.
    private var addressBookContacts: [ContactsService.DeviceContact] {
        let storeUsers = Array(store.users.values)
        return contactsService.deviceContacts.filter { contact in
            contact.primaryPhone != nil
                && contactsService.matchUser(for: contact, in: storeUsers) == nil
                && matchesQuery(name: contact.fullName, phones: contact.phoneNumbers)
        }
    }

    private var accessBlocked: Bool {
        switch contactsService.state {
        case .denied, .restricted: return true
        default: break
        }
        return permissions.contacts == .denied || permissions.contacts == .restricted
    }

    private var showsFallback: Bool {
        guard !accessBlocked else { return false }
        switch contactsService.state {
        case .loading, .failed: return false
        default: return onInditalkUsers.isEmpty && addressBookContacts.isEmpty
        }
    }

    /// Search matches on name (case-insensitive) or digits of any phone number.
    private func matchesQuery(name: String, phones: [String]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if name.localizedCaseInsensitiveContains(trimmed) { return true }
        let digits = ContactsService.normalized(phone: trimmed)
        guard !digits.isEmpty else { return false }
        return phones.contains { ContactsService.normalized(phone: $0).contains(digits) }
    }

    // MARK: Rows

    private func quickAction(_ symbol: String, _ tint: Color, _ title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(tint, in: Circle())
            Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.textPrimary)
        }
    }

    private func contactRow(_ user: InditalkUser) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: user.displayName, imageName: user.avatarAsset,
                       localName: user.avatarLocalName, remoteURL: user.avatarURL,
                       size: Metrics.avatarSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName).font(.system(size: 16)).foregroundStyle(Palette.textPrimary)
                Text(user.about).font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func deviceContactRow(_ contact: ContactsService.DeviceContact) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: contact.fullName, size: Metrics.avatarSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.fullName).font(.system(size: 16)).foregroundStyle(Palette.textPrimary)
                Text(contact.primaryPhone ?? "")
                    .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// True when access is restricted by device policy (Screen Time / MDM), where the
    /// Contacts toggle doesn't exist in Settings so "Open Settings" can't help.
    private var contactsRestricted: Bool {
        contactsService.state == .restricted || permissions.contacts == .restricted
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Inditalk can't see your contacts", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            if contactsRestricted {
                Text("Contact access is restricted on this device — a Screen Time limit or device profile is blocking it. You can still add contacts by number.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Text("Allow contact access so friends from your address book show up here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open Settings").font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.ink)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Actions

    private func start(with user: InditalkUser) {
        // Opens the existing 1:1 or creates + persists a new one.
        onSelect(store.startDirectChat(with: user))
    }

    private func start(with contact: ContactsService.DeviceContact) {
        guard let phone = contact.primaryPhone else { return }
        // addContact dedupes by normalized phone, so re-taps reuse the same user.
        let user = store.addContact(name: contact.fullName, phone: phone)
        onSelect(store.startDirectChat(with: user))
    }
}
