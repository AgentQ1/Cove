//
//  PrivacySettingsView.swift
//  Inditalk
//
//  Settings › Privacy. Visibility choices (Last Seen, Profile Photo, About) route
//  to the shared VisibilityPickerView; Read Receipts and the default disappearing
//  timer are enforced by DataStore; Blocked opens the real blocked-contact manager.
//

import SwiftUI

struct PrivacySettingsView: View {
    @EnvironmentObject private var store: DataStore

    var body: some View {
        List {
            Section {
                visibilityRow("Last Seen & Online", footer:
                    "Choose who can see when you were last online. "
                    + "If you don't share your Last Seen, you won't see other people's.",
                    keyPath: \.lastSeen)
                visibilityRow("Profile Photo", footer:
                    "Choose who can see your profile photo.",
                    keyPath: \.profilePhoto)
                visibilityRow("About", footer:
                    "Choose who can see your About line.",
                    keyPath: \.about)
                // BACKEND INTEGRATION: these visibility choices are stored with the
                // profile and must be enforced server-side (presence/profile reads)
                // when AppConfig.usesFirebase.
            } header: {
                Text("Who can see my info")
            }
            .listRowBackground(Palette.surface)

            Section {
                Toggle("Read Receipts", isOn: Binding(
                    get: { store.privacy.readReceipts },
                    set: { store.privacy.readReceipts = $0; Haptics.selection() }))
                .tint(Palette.pine)
            } footer: {
                Text("If turned off, you won't send read receipts and your sent "
                     + "messages stop showing as read. Takes effect immediately for "
                     + "new messages.")
            }
            .listRowBackground(Palette.surface)

            Section {
                Picker("Default Timer", selection: Binding(
                    get: { store.privacy.defaultDisappearingSeconds },
                    set: { store.privacy.defaultDisappearingSeconds = $0 })) {
                    ForEach(DisappearingOption.allCases) { opt in
                        Text(opt.label).tag(opt.rawValue)
                    }
                }
            } header: {
                Text("Disappearing Messages")
            } footer: {
                Text("New chats you start will use this timer automatically. "
                     + "Existing chats keep their own setting.")
            }
            .listRowBackground(Palette.surface)

            Section {
                NavigationLink { BlockedContactsView() } label: {
                    SettingsRow(symbol: "hand.raised.fill", tint: Palette.danger, title: "Blocked",
                                trailing: "\(store.privacy.blockedUserIDs.count)")
                }
            } footer: {
                Text("Blocked contacts can't call you or send you messages.")
            }
            .listRowBackground(Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Row showing the current visibility value; navigates to the shared radio picker.
    private func visibilityRow(_ title: String, footer: String,
                               keyPath: WritableKeyPath<PrivacySettings, PrivacySettings.Visibility>) -> some View {
        NavigationLink {
            VisibilityPickerView(title: title, footer: footer, selection: Binding(
                get: { store.privacy[keyPath: keyPath] },
                set: { store.privacy[keyPath: keyPath] = $0 }))
        } label: {
            HStack {
                Text(title).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(store.privacy[keyPath: keyPath].label)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}
