//
//  SettingsView.swift
//  Inditalk
//
//  The "You" destination. Profile header + grouped settings rows: account, privacy,
//  chats, notifications, storage, starred, help. Navigates to detail screens. The
//  search field filters the rows by title.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: DataStore
    @EnvironmentObject private var session: AppSession
    @State private var searchText = ""
    @State private var showInvite = false
    @State private var showQRCode = false

    private static let allRowTitles = [
        "Profile", "Starred Messages", "Account", "Privacy", "Storage and Data",
        "Notifications", "Help & Support", "Invite a Friend", "Sign Out",
    ]

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    private func rowMatches(_ title: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query)
    }

    private func sectionHasMatch(_ titles: [String]) -> Bool {
        titles.contains(where: rowMatches)
    }

    private var hasAnyMatch: Bool { Self.allRowTitles.contains(where: rowMatches) }

    var body: some View {
        NavigationStack {
            List {
                if rowMatches("Profile") {
                    Section {
                        NavigationLink { ProfileView() } label: { profileHeader }
                            .listRowBackground(Palette.surface)
                    }
                }

                if sectionHasMatch(["Starred Messages", "Account", "Privacy",
                                    "Storage and Data", "Notifications"]) {
                    Section {
                        if rowMatches("Starred Messages") {
                            NavigationLink { StarredMessagesView() } label: {
                                SettingsRow(symbol: "star.fill", tint: Palette.ochre, title: "Starred Messages",
                                            trailing: "\(store.allStarred().count)")
                            }
                        }
                        if rowMatches("Account") {
                            NavigationLink { AccountSettingsView() } label: {
                                SettingsRow(symbol: "key.fill", tint: Palette.ink, title: "Account")
                            }
                        }
                        if rowMatches("Privacy") {
                            NavigationLink { PrivacySettingsView() } label: {
                                SettingsRow(symbol: "lock.fill", tint: Palette.pine, title: "Privacy")
                            }
                        }
                        if rowMatches("Storage and Data") {
                            NavigationLink { StorageSettingsView() } label: {
                                SettingsRow(symbol: "arrow.up.arrow.down.circle.fill", tint: Palette.pine,
                                            title: "Storage and Data")
                            }
                        }
                        if rowMatches("Notifications") {
                            NavigationLink { NotificationsSettingsView() } label: {
                                SettingsRow(symbol: "bell.fill", tint: Palette.danger, title: "Notifications")
                            }
                        }
                    }
                    .listRowBackground(Palette.surface)
                }

                if sectionHasMatch(["Help & Support", "Invite a Friend"]) {
                    Section {
                        if rowMatches("Help & Support") {
                            NavigationLink { HelpSupportView() } label: {
                                SettingsRow(symbol: "questionmark.circle.fill", tint: Palette.ink,
                                            title: "Help & Support")
                            }
                        }
                        if rowMatches("Invite a Friend") {
                            Button { showInvite = true } label: {
                                SettingsRow(symbol: "person.2.fill", tint: Palette.ochre, title: "Invite a Friend")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Palette.surface)
                }

                if rowMatches("Sign Out") {
                    Section {
                        // Session teardown only — credential/backend sign-out lives in AppSession.
                        Button(role: .destructive) { session.signOut() } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(Palette.danger)
                        }
                    }
                    .listRowBackground(Palette.surface)
                }

                if !hasAnyMatch {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Palette.background)
                        .listRowSeparator(.hidden)
                }

                if query.isEmpty {
                    Text(versionFooter)
                        .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Palette.background)
                        .listRowSeparator(.hidden)
                }
            }
            .safeAreaPadding(.bottom, TabBarMetrics.reservedHeight)   // clear the floating tab bar
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Settings")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
            .sheet(isPresented: $showInvite) {
                ShareSheet(items: ["Join me on Inditalk — a private messenger. https://inditalk.web.app"])
            }
            .sheet(isPresented: $showQRCode) {
                ContactQRView()
            }
        }
        .tint(Palette.ink)
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            AvatarView(name: store.currentUser.displayName, imageName: store.currentUser.avatarAsset,
                       localName: store.currentUser.avatarLocalName, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.currentUser.displayName)
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                Text(store.currentUser.about).font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
                Text(store.currentUser.phoneNumber).font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button { showQRCode = true } label: {
                Image(systemName: "qrcode")
                    .foregroundStyle(Palette.ink)
                    // 44x44 minimum touch target.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Contact code")
        }
        .padding(.vertical, 6)
    }

    private var versionFooter: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        #if DEBUG
        return "Inditalk • v\(v) (\(b)) — debug build"
        #else
        return "Inditalk • v\(v) (\(b))"
        #endif
    }
}

struct SettingsRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).foregroundStyle(Palette.textPrimary)
            Spacer()
            if let trailing { Text(trailing).foregroundStyle(Palette.textSecondary) }
        }
        .padding(.vertical, 2)
    }
}
