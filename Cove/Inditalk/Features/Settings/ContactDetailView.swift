//
//  ContactDetailView.swift
//  Inditalk
//
//  Contact / chat info screen: large avatar + quick actions, about, disappearing
//  timer, encryption/verify entry, mute toggle, block & report. For group chats it
//  surfaces the group-info screen instead.
//

import SwiftUI

struct ContactDetailView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    let chat: Chat
    @State private var showBlockConfirm = false
    @State private var showDisappearing = false
    @State private var showReport = false
    @State private var callLaunch: CallLaunch?

    struct CallLaunch: Identifiable { let id = UUID(); let isVideo: Bool }

    private var otherUser: InditalkUser? {
        guard chat.kind == .direct else { return nil }
        let id = chat.participantIDs.first { $0 != store.currentUser.id }
        return id.flatMap { store.users[$0] }
    }

    private var isBlocked: Bool {
        guard let id = otherUser?.id else { return false }
        return store.privacy.blockedUserIDs.contains(id)
    }

    var body: some View {
        List {
            header.listRowBackground(Palette.background)

            if chat.kind == .group {
                Section { NavigationLink("Group info") { GroupInfoView(chat: chat) } }
                    .listRowBackground(Palette.surface)
            }

            if let about = otherUser?.about {
                Section("About") { Text(about).foregroundStyle(Palette.textPrimary) }
                    .listRowBackground(Palette.surface)
            }

            Section {
                Button { showDisappearing = true } label: {
                    SettingsRow(symbol: "timer", tint: Palette.ochre, title: "Disappearing Messages",
                                trailing: chat.disappearingSeconds == 0 ? "Off"
                                          : DisappearingOption.label(for: chat.disappearingSeconds))
                }
                NavigationLink { SafetyNumberView(chat: chat) } label: {
                    SettingsRow(symbol: "lock.fill", tint: Palette.pine, title: "Encryption")
                }
                Toggle(isOn: Binding(get: { chat.isMuted },
                                     set: { _ in store.toggleMute(chat.id) })) {
                    Label("Mute notifications", systemImage: "bell.slash.fill")
                }.tint(Palette.pine)
            }
            .listRowBackground(Palette.surface)

            Section {
                Button { store.togglePin(chat.id) } label: {
                    Label(chat.isPinned ? "Unpin chat" : "Pin chat", systemImage: "pin")
                        .foregroundStyle(Palette.textPrimary)
                }
                Button { store.toggleArchive(chat.id) } label: {
                    Label(chat.isArchived ? "Unarchive chat" : "Archive chat", systemImage: "archivebox")
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            .listRowBackground(Palette.surface)

            if let user = otherUser {
                Section {
                    Button(role: .destructive) { showBlockConfirm = true } label: {
                        Label(store.privacy.blockedUserIDs.contains(user.id) ? "Unblock" : "Block \(user.displayName)",
                              systemImage: "hand.raised.fill")
                    }
                    Button(role: .destructive) { showReport = true } label: {
                        Label("Report \(user.displayName)", systemImage: "exclamationmark.bubble.fill")
                    }
                }
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Block this contact?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                if let id = otherUser?.id {
                    store.privacy.blockedUserIDs.contains(id) ? store.unblock(id) : store.block(id)
                }
            }
        } message: {
            Text("Blocked contacts can't call you or send you messages. They won't be notified.")
        }
        .confirmationDialog("Disappearing messages", isPresented: $showDisappearing, titleVisibility: .visible) {
            ForEach(DisappearingOption.allCases) { opt in
                Button(opt.label) { store.setDisappearing(seconds: opt.rawValue, in: chat.id) }
            }
        }
        .sheet(isPresented: $showReport) {
            if let user = otherUser {
                ReportContactView(reportedUser: user, chatID: chat.id)
            }
        }
        .fullScreenCover(item: $callLaunch) { launch in
            // Re-inject the store: on "My Mac (Designed for iPhone)" cover content is
            // hosted in a separate window that misses the app-level environmentObject.
            Group {
                if launch.isVideo {
                    VideoCallView(peerName: chat.title, avatar: chat.avatarAsset,
                                  chatID: chat.id, direction: .outgoing)
                } else {
                    VoiceCallView(peerName: chat.title, avatar: chat.avatarAsset,
                                  chatID: chat.id, direction: .outgoing)
                }
            }
            .environmentObject(store)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            AvatarView(name: chat.title, imageName: chat.avatarAsset,
                       localName: otherUser?.avatarLocalName,
                       remoteURL: otherUser?.avatarURL,
                       systemImage: chat.kind == .group ? "person.2.fill" : nil,
                       size: Metrics.avatarLarge)
            HStack(spacing: 5) {
                Text(chat.title).font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.textPrimary)
                if chat.isVerified {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.ink)
                }
            }
            if let phone = otherUser?.phoneNumber {
                Text(phone).font(.system(size: 15)).foregroundStyle(Palette.textSecondary)
            }
            HStack(spacing: 28) {
                quickAction("message.fill", "Message") {
                    isBlocked ? blockedCallToast() : dismiss()
                }
                // Hidden for groups: group calling has no SFU yet, and a control that
                // always answers "not supported" is a broken feature to a reviewer.
                if chat.kind == .direct {
                    quickAction("phone.fill", "Audio") {
                        isBlocked ? blockedCallToast() : startCall(video: false)
                    }
                    quickAction("video.fill", "Video") {
                        isBlocked ? blockedCallToast() : startCall(video: true)
                    }
                }
                NavigationLink { InChatSearchView(chat: chat) } label: {
                    quickActionLabel("magnifyingglass", "Search")
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Search")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func blockedCallToast() {
        ToastCenter.shared.show("You blocked this contact. Unblock to message or call.", pending: false)
    }

    /// Place a REAL call when the contact is addressable (Firebase uid known) — the
    /// live call screen is presented globally by RootView off CallCenter state. The
    /// simulated screens remain only for local/demo mode.
    private func startCall(video: Bool) {
        guard AppConfig.usesFirebase else {
            callLaunch = CallLaunch(isVideo: video)
            return
        }
        // Call buttons only appear on 1:1 contacts, so a non-direct chat is just an
        // unresolvable target — there is no group-calling path to explain here.
        guard chat.kind == .direct,
              let peer = otherUser, let peerUID = peer.remoteUID, !peerUID.isEmpty else {
            ToastCenter.shared.show("\(otherUser?.displayName ?? "This contact") isn't on Inditalk yet", pending: false)
            return
        }
        Task {
            guard await PermissionsManager.shared.requestMicrophone() else {
                ToastCenter.shared.show("Allow microphone access in Settings to make calls", pending: false)
                return
            }
            if video, await PermissionsManager.shared.requestCamera() == false {
                ToastCenter.shared.show("Allow camera access in Settings to make video calls", pending: false)
                return
            }
            CallCenter.shared.placeCall(to: peerUID, peerName: peer.displayName, video: video)
        }
    }

    private func quickAction(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            quickActionLabel(symbol, label)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func quickActionLabel(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Palette.ink)
                .frame(width: 48, height: 48)
                .background(Palette.ink.opacity(0.10), in: Circle())
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
        }
    }
}
