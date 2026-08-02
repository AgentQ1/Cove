//
//  GroupInfoView.swift
//  Inditalk
//
//  Group settings: photo/name/description, invite link, member list with admin
//  badges, group permissions, add-members, exit, and report. Admin-only controls
//  are gated on membership. Reads the live chat from the store so membership and
//  permission changes refresh in place.
//

import SwiftUI
import UIKit

struct GroupInfoView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    let chat: Chat

    @State private var showAddMembers = false
    @State private var showExitConfirm = false
    @State private var showReport = false

    /// Live projection — the pushed-in value goes stale after membership edits.
    private var current: Chat { store.chat(chat.id) ?? chat }
    private var group: GroupInfo? { current.group }
    private var members: [InditalkUser] { current.participantIDs.compactMap { store.users[$0] } }
    private var iAmMember: Bool { current.participantIDs.contains(store.currentUser.id) }
    private var iAmAdmin: Bool { group?.adminIDs.contains(store.currentUser.id) ?? false }

    var body: some View {
        List {
            header.listRowBackground(Palette.background)

            if let group {
                Section {
                    Text(group.descriptionText).foregroundStyle(Palette.textPrimary)
                } header: { Text("Description") }
                .listRowBackground(Palette.surface)

                // "Invite via link" was removed: the app has no way to redeem an invite
                // URL (no URL scheme or universal link is registered — `onOpenURL` only
                // routes Firebase auth callbacks), so the link went nowhere. Members are
                // added through "Add members" below, which does work.

                if iAmAdmin {
                    Section("Permissions") {
                        permissionRow("Send messages", group.permissions.whoCanSend.label)
                        permissionRow("Edit group info", group.permissions.whoCanEditInfo.label)
                        permissionRow("Add members", group.permissions.whoCanAddMembers.label)
                        Toggle("Approve new members", isOn: Binding(
                            get: { current.group?.permissions.approveNewMembers ?? false },
                            set: { store.setGroupApproveNewMembers($0, in: chat.id) }))
                            .tint(Palette.pine)
                    }
                    .listRowBackground(Palette.surface)
                }
            }

            Section("\(members.count) members") {
                if iAmAdmin {
                    Button { showAddMembers = true } label: {
                        Label("Add members", systemImage: "person.badge.plus").foregroundStyle(Palette.ink)
                    }
                }
                ForEach(members) { member in memberRow(member) }
            }
            .listRowBackground(Palette.surface)

            Section {
                if iAmMember {
                    Button(role: .destructive) { showExitConfirm = true } label: {
                        Label("Exit group", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                Button(role: .destructive) { showReport = true } label: {
                    Label("Report group", systemImage: "exclamationmark.bubble.fill")
                }
            }
            .listRowBackground(Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Group info")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddMembers) {
            AddGroupMembersSheet(chat: current)
        }
        .sheet(isPresented: $showReport) {
            ReportGroupView(chat: current)
        }
        .alert("Exit group?", isPresented: $showExitConfirm) {
            Button("Exit group", role: .destructive) {
                store.leaveGroup(chat.id)
                Haptics.impact(.light)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop receiving messages from “\(current.title)”. The conversation stays in your chats list.")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AvatarView(name: current.title, systemImage: "person.2.fill", size: Metrics.avatarLarge)
            Text(current.title).font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.textPrimary)
            Text("Group • \(members.count) members").font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    private func memberRow(_ member: InditalkUser) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: member.displayName, imageName: member.avatarAsset,
                       localName: member.avatarLocalName, size: Metrics.avatarSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.id == store.currentUser.id ? "You" : member.displayName)
                    .foregroundStyle(Palette.textPrimary)
                Text(member.about).font(.system(size: 13)).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            if group?.adminIDs.contains(member.id) == true {
                Text("Admin").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.pine)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.pine.opacity(0.12), in: Capsule())
            }
        }
    }

    private func permissionRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(Palette.textSecondary) }
    }
}

// MARK: - Add members

/// Multi-select of contacts not yet in the group; commits via DataStore.addMembers.
private struct AddGroupMembersSheet: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    let chat: Chat

    @State private var selected: Set<UUID> = []
    @State private var query = ""

    private var candidates: [InditalkUser] {
        let memberIDs = Set(store.chat(chat.id)?.participantIDs ?? chat.participantIDs)
        let all = store.users.values
            .filter { !memberIDs.contains($0.id) && $0.id != store.currentUser.id }
            .sorted { $0.displayName < $1.displayName }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        let digits = ContactsService.normalized(phone: trimmed)
        return all.filter { user in
            user.displayName.localizedCaseInsensitiveContains(trimmed)
                || (!digits.isEmpty && ContactsService.normalized(phone: user.phoneNumber).contains(digits))
        }
    }

    /// Stable order so the selection strip doesn't reshuffle on every tap.
    private var selectedUsers: [InditalkUser] {
        selected.compactMap { store.users[$0] }.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty && query.isEmpty {
                    Section {
                        Text("Everyone you know on Inditalk is already in this group.")
                            .font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
                    }
                    .listRowBackground(Palette.background)
                } else {
                    if !selectedUsers.isEmpty {
                        Section {
                            SelectedMembersStrip(users: selectedUsers) { toggle($0) }
                                .listRowInsets(EdgeInsets())
                        }
                        .listRowBackground(Palette.background)
                    }
                    Section("Add to “\(chat.title)” (\(selected.count))") {
                        ForEach(candidates) { user in
                            Button { toggle(user.id) } label: { row(user) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Palette.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search contacts")
            .navigationTitle("Add members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.ink)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.tint(Palette.ink).disabled(selected.isEmpty)
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

    private func add() {
        store.addMembers(Array(selected), to: chat.id)
        Haptics.impact(.light)
        dismiss()
    }
}

// MARK: - Report group

/// Real "report this group" flow through the same Safety pipeline as contact
/// reports (ReportStore outbox + ReportService delivery). A group has no single
/// reported user, so the report is attributed to the group owner and carries the
/// chat id so moderation can map the group.
private struct ReportGroupView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    let chat: Chat

    @State private var reason: ReportReason = .spam
    @State private var note = ""
    @State private var alsoExit = false
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Tell us what's wrong with “\(chat.title)”. Reports are reviewed by "
                         + "the Inditalk safety team. In an emergency, contact local authorities.")
                        .font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
                }
                .listRowBackground(Palette.background)

                Section("Reason") {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { r in Text(r.label).tag(r) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .listRowBackground(Palette.surface)

                Section("Add detail (optional)") {
                    TextField("What happened?", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .foregroundStyle(Palette.textPrimary)
                }
                .listRowBackground(Palette.surface)

                if chat.participantIDs.contains(store.currentUser.id) {
                    Section {
                        Toggle("Also exit the group", isOn: $alsoExit)
                            .tint(Palette.pine)
                    } footer: {
                        Text("You'll stop receiving messages from this group.")
                    }
                    .listRowBackground(Palette.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Report group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.ink).disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { submit() }
                        .tint(Palette.danger).disabled(isSubmitting)
                }
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        // Attribute the report to the group's accountable party (its owner).
        let accountable = chat.group?.ownerID
            ?? chat.participantIDs.first { $0 != store.currentUser.id }
            ?? store.currentUser.id
        let report = Report(reporterID: store.currentUser.id,
                            reportedUserID: accountable,
                            chatID: chat.id, reason: reason,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        if alsoExit { store.leaveGroup(chat.id) }
        Task {
            let outcome = await ReportService.shared.submit(report)
            isSubmitting = false
            dismiss()
            switch outcome {
            case .delivered:
                ToastCenter.shared.show("Report sent to the Inditalk safety team", pending: false)
            case .queuedLocally, .queuedNeedsRetry:
                ToastCenter.shared.show("Report saved — it'll be sent when you're online", pending: false)
            }
        }
    }
}
