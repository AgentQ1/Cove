//
//  SupportScreens.swift
//  Inditalk
//
//  Minimal but real Settings detail screens that replace the old placeholder stubs.
//  These are the release-appropriate versions: Help & Support (support contact +
//  policy links — an App Review requirement for UGC apps), Storage & Data (real
//  on-device usage), and Notifications (live UNUserNotificationCenter permission
//  state: request when undecided, deep link to iOS Settings when denied, honest
//  per-setting summary when authorized).
//

import SwiftUI
import UIKit
import UserNotifications

/// Central place for Inditalk's public URLs. These pages themselves are a manual/legal
/// deliverable (see APP_STORE_DEPLOYMENT_REPORT.md) — the app just links to them.
enum InditalkLinks {
    static let support = URL(string: "mailto:moomolab@gmail.com")!
    static let privacy = URL(string: "https://inditalk.web.app/privacy")!
    static let terms = URL(string: "https://inditalk.web.app/terms")!
    static let guidelines = URL(string: "https://inditalk.web.app/guidelines")!
    static let help = URL(string: "https://inditalk.web.app/help")!
}

struct HelpSupportView: View {
    var body: some View {
        List {
            Section("Get help") {
                Link(destination: InditalkLinks.support) {
                    SettingsRow(symbol: "envelope.fill", tint: Palette.ink, title: "Contact Support")
                }
                Link(destination: InditalkLinks.help) {
                    SettingsRow(symbol: "questionmark.circle.fill", tint: Palette.pine, title: "Help Center")
                }
            }
            .listRowBackground(Palette.surface)

            Section {
                Link(destination: InditalkLinks.guidelines) {
                    SettingsRow(symbol: "checkmark.shield.fill", tint: Palette.pine, title: "Community Guidelines")
                }
                Link(destination: InditalkLinks.terms) {
                    SettingsRow(symbol: "doc.text.fill", tint: Palette.ink, title: "Terms of Service")
                }
                Link(destination: InditalkLinks.privacy) {
                    SettingsRow(symbol: "lock.doc.fill", tint: Palette.ochre, title: "Privacy Policy")
                }
            } header: {
                Text("Safety & policies")
            } footer: {
                Text("Report abuse from any chat: open the contact, then Report. Reports are "
                     + "reviewed by the Inditalk safety team. In an emergency, contact local authorities.")
            }
            .listRowBackground(Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Help & Support")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StorageSettingsView: View {
    @EnvironmentObject private var store: DataStore

    /// Every stored file, read once per appearance — the totals, the per-category sizes
    /// and the file counts are all derived from this so they can never disagree.
    @State private var items: [MediaStore.Item] = []
    /// Category awaiting confirmation; nil means "clear everything".
    @State private var pendingClear: PendingClear?

    private struct PendingClear: Identifiable {
        let category: MediaStore.Category?     // nil == all media
        var id: String { category?.rawValue ?? "all" }

        var title: String {
            guard let category else { return "Clear all media?" }
            return "Clear \(category.title.lowercased())?"
        }

        var message: String {
            let what = category.map { $0.title.lowercased() } ?? "photos, videos, voice messages, and documents"
            return "This permanently deletes \(what) stored on this device. "
                 + "Your messages stay, but the media in them can't be reopened."
        }
    }

    private var usedBytes: Int { items.reduce(0) { $0 + $1.bytes } }

    private var sortedCategories: [(category: MediaStore.Category, bytes: Int, count: Int)] {
        MediaStore.Category.allCases
            .compactMap { category in
                let inCategory = items.filter { $0.category == category }
                guard !inCategory.isEmpty else { return nil }
                return (category, inCategory.reduce(0) { $0 + $1.bytes }, inCategory.count)
            }
            .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Media stored", value: MediaStore.sizeLabel(usedBytes))
            } header: {
                Text("On this device")
            } footer: {
                Text("Photos, videos, and files you've sent or received are stored on this "
                     + "device. Deleting your account removes all of it.")
            }
            .listRowBackground(Palette.surface)

            if sortedCategories.isEmpty {
                Section {
                    Text("No media stored yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.textSecondary)
                }
                .listRowBackground(Palette.surface)
            } else {
                Section {
                    // Opens the actual files rather than clearing the whole category
                    // blind: you pick what goes. Bulk clearing is still one tap away
                    // via the swipe action and "Clear all media" below.
                    ForEach(sortedCategories, id: \.category) { entry in
                        NavigationLink {
                            MediaBrowserView(category: entry.category)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.category.symbol)
                                    .foregroundStyle(Palette.ink)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.category.title)
                                        .foregroundStyle(Palette.textPrimary)
                                    Text("\(entry.count) file\(entry.count == 1 ? "" : "s")")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.textSecondary)
                                }
                                Spacer()
                                Text(MediaStore.sizeLabel(entry.bytes))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            .frame(minHeight: 44)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingClear = PendingClear(category: entry.category)
                            } label: {
                                Label("Clear", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Manage by type")
                } footer: {
                    Text("Tap a category to browse the files and delete just the ones you "
                         + "pick, or swipe a row to clear the whole category.")
                }
                .listRowBackground(Palette.surface)

                Section {
                    Button(role: .destructive) {
                        pendingClear = PendingClear(category: nil)
                    } label: {
                        Text("Clear all media")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Storage and Data")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .alert(item: $pendingClear) { pending in
            Alert(
                title: Text(pending.title),
                message: Text(pending.message),
                primaryButton: .destructive(Text("Delete")) { performClear(pending.category) },
                secondaryButton: .cancel()
            )
        }
    }

    private func refresh() { items = MediaStore.items() }

    /// Delete the bytes, then detach any message/status still pointing at them so the UI
    /// never shows an attachment whose file is gone.
    private func performClear(_ category: MediaStore.Category?) {
        let removed: [String]
        if let category {
            removed = MediaStore.clear(category)
        } else {
            removed = MediaStore.Category.allCases.flatMap { MediaStore.clear($0) }
        }
        store.detachDeletedMedia(named: removed)
        refresh()
        ToastCenter.shared.show(removed.isEmpty ? "Nothing to clear" : "Freed up space", pending: false)
    }
}

struct NotificationsSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase

    /// The slice of UNNotificationSettings this screen surfaces, captured as plain
    /// values so state stays Sendable under strict concurrency.
    private struct PermissionSnapshot: Equatable {
        var authorization: UNAuthorizationStatus
        var alerts: Bool
        var sounds: Bool
        var badges: Bool
    }

    @State private var snapshot: PermissionSnapshot?
    @State private var isRequesting = false

    var body: some View {
        List {
            Section {
                Text("Inditalk uses push notifications to tell you about new messages and "
                     + "incoming calls. Notification content stays private — pushes carry "
                     + "only a nudge, and the message itself is fetched and decrypted on "
                     + "your device.")
                    .font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
            }
            .listRowBackground(Palette.background)

            statusSections
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Returning from the Settings app must reflect any change immediately.
            if phase == .active { Task { await refresh() } }
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if let snapshot {
            switch snapshot.authorization {
            case .notDetermined:
                Section {
                    Button { requestAuthorization() } label: {
                        SettingsRow(symbol: "bell.badge.fill", tint: Palette.pine,
                                    title: isRequesting ? "Requesting…" : "Enable Notifications")
                    }
                    .buttonStyle(.plain)
                    .disabled(isRequesting)
                } footer: {
                    Text("You haven't decided yet. Enabling asks iOS for permission to "
                         + "show alerts, play sounds, and badge the app icon.")
                }
                .listRowBackground(Palette.surface)

            case .denied:
                Section {
                    openSettingsLink(title: "Open Settings")
                } header: {
                    Text("Notifications are off")
                } footer: {
                    Text("Notifications are turned off for Inditalk in iOS Settings, so you "
                         + "won't hear about new messages or calls. Open Settings and "
                         + "allow notifications to turn them back on.")
                }
                .listRowBackground(Palette.surface)

            default: // .authorized, .provisional, .ephemeral
                Section {
                    statusRow("Alerts", enabled: snapshot.alerts)
                    statusRow("Sounds", enabled: snapshot.sounds)
                    statusRow("Badges", enabled: snapshot.badges)
                } header: {
                    Text("Notifications are on")
                } footer: {
                    Text("These reflect your current iOS notification settings for Inditalk.")
                }
                .listRowBackground(Palette.surface)

                Section {
                    openSettingsLink(title: "Open iOS Notification Settings")
                } footer: {
                    Text("Adjust alert style, sounds, and badges in the iOS Settings app.")
                }
                .listRowBackground(Palette.surface)
            }
        } else {
            Section {
                HStack(spacing: 10) {
                    ProgressView().tint(Palette.ink)
                    Text("Checking notification status…")
                        .font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
                }
            }
            .listRowBackground(Palette.surface)
        }
    }

    private func statusRow(_ title: String, enabled: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(Palette.textPrimary)
            Spacer()
            Text(enabled ? "On" : "Off")
                .foregroundStyle(enabled ? Palette.pine : Palette.textSecondary)
        }
    }

    @ViewBuilder
    private func openSettingsLink(title: String) -> some View {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            Link(destination: url) {
                SettingsRow(symbol: "gearshape.fill", tint: Palette.ink, title: title)
            }
        }
    }

    private func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        snapshot = PermissionSnapshot(
            authorization: settings.authorizationStatus,
            alerts: settings.alertSetting == .enabled,
            sounds: settings.soundSetting == .enabled,
            badges: settings.badgeSetting == .enabled)
    }

    private func requestAuthorization() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            defer { isRequesting = false }
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if granted {
                Haptics.notify(.success)
                ToastCenter.shared.show("Notifications enabled", pending: false)
                // APNs registration only matters with a live backend; the FCM token
                // upload is handled by AppDelegate/PushService.
                if AppConfig.usesFirebase { UIApplication.shared.registerForRemoteNotifications() }
            }
            await refresh()
        }
    }
}
