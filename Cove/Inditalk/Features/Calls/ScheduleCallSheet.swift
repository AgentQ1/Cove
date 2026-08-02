//
//  ScheduleCallSheet.swift
//  Inditalk
//
//  "Schedule call" flow from the Calls tab: pick a contact, voice/video, a future
//  date, and an optional title. Saved calls appear in the Calls tab "Upcoming"
//  section (DataStore.scheduledCalls, past entries filtered out of the projection).
//

import SwiftUI

struct ScheduleCallSheet: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var contact: InditalkUser?
    @State private var media: CallMedia = .voice
    @State private var date = Date().addingTimeInterval(3600)
    @State private var title = ""
    @State private var showContactPicker = false

    private var defaultTitle: String {
        "Call with \(contact?.displayName ?? "…")"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Who") {
                    Button { showContactPicker = true } label: { contactRow }
                        .buttonStyle(.plain)
                }
                .listRowBackground(Palette.surface)

                Section("Details") {
                    TextField(defaultTitle, text: $title)
                        .foregroundStyle(Palette.textPrimary)
                    Picker("Call type", selection: $media) {
                        Text("Voice").tag(CallMedia.voice)
                        Text("Video").tag(CallMedia.video)
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Time", selection: $date, in: Date()...,
                               displayedComponents: [.date, .hourAndMinute])
                        .tint(Palette.pine)
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Schedule call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.pine)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .tint(Palette.pine)
                        .fontWeight(.semibold)
                        .disabled(contact == nil)
                }
            }
            .sheet(isPresented: $showContactPicker) {
                ScheduleContactPicker(selected: $contact)
            }
        }
        .tint(Palette.pine)
    }

    private var contactRow: some View {
        HStack(spacing: 12) {
            if let contact {
                AvatarView(name: contact.displayName, imageName: contact.avatarAsset,
                           localName: contact.avatarLocalName, size: Metrics.avatarSmall)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName).foregroundStyle(Palette.textPrimary)
                    Text(contact.phoneNumber)
                        .font(.inditalkCaption()).foregroundStyle(Palette.textSecondary)
                }
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 24)).foregroundStyle(Palette.pine)
                    .frame(width: Metrics.avatarSmall, height: Metrics.avatarSmall)
                Text("Choose contact").foregroundStyle(Palette.pine)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(contact.map { "Contact: \($0.displayName)" } ?? "Choose contact")
    }

    private func save() {
        guard let contact else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let call = ScheduledCall(
            title: trimmed.isEmpty ? "Call with \(contact.displayName)" : trimmed,
            chatID: store.chats.first { $0.kind == .direct && $0.participantIDs.contains(contact.id) }?.id,
            contactID: contact.id,
            displayName: contact.displayName,
            media: media,
            date: max(date, Date().addingTimeInterval(60)))   // never save into the past
        store.scheduleCall(call)
        // BACKEND INTEGRATION: sync the scheduled call to the backend (FirestoreService
        // doc under both participants) and register a local/push reminder notification
        // for `call.date` when AppConfig.usesFirebase.
        Haptics.impact(.light)
        ToastCenter.shared.show("Call scheduled for \(CallsViewModel.upcomingStamp(call.date))",
                                symbol: "calendar.badge.checkmark", pending: false)
        dismiss()
    }
}

/// Searchable single-select contact list (everyone except the local user).
private struct ScheduleContactPicker: View {
    @Binding var selected: InditalkUser?

    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [InditalkUser] {
        let base = store.users.values.filter { $0.id != store.currentUser.id }
        let filtered = query.isEmpty ? Array(base)
            : base.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        return filtered.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(candidates) { user in
                    Button {
                        selected = user
                        Haptics.selection()
                        dismiss()
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
                            if selected?.id == user.id {
                                Image(systemName: "checkmark").foregroundStyle(Palette.pine)
                            }
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
            .navigationTitle("Choose contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.pine)
                }
            }
        }
        .tint(Palette.pine)
    }
}

#Preview {
    ScheduleCallSheet().environmentObject(DataStore.inMemory())
}
