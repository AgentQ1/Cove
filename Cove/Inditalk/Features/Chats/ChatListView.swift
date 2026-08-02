//
//  ChatListView.swift
//  Inditalk
//
//  The Chats destination. Static serif header + search + archived entry, then a
//  scrolling list of conversations with swipe actions. Mirrors the reference's
//  chats screen structure with Inditalk's own identity.
//

import SwiftUI
import UIKit

struct ChatListView: View {
    @EnvironmentObject private var store: DataStore
    @EnvironmentObject private var tabBar: TabBarVisibility
    @StateObject private var vm = ChatListViewModel()
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var showCamera = false
    @State private var capturedMedia: CapturedMedia?
    @State private var pendingCapture: PendingCapture?
    @State private var path = NavigationPath()

    /// NavigationPath token for the archived-chats screen (chats push as themselves).
    private struct ArchivedRoute: Hashable {}

    /// A fresh capture (photo OR video) waiting for its destination chat to be picked.
    private struct CapturedMedia: Identifiable {
        let id = UUID()
        let content: AttachmentDraft.Content
    }

    /// A capture staged for the preview/caption screen, bound to its destination.
    private struct PendingCapture: Identifiable {
        let id = UUID()
        let content: AttachmentDraft.Content
        let chat: Chat
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                searchField
                if store.archivedChats.isEmpty == false {
                    archivedRow
                    Divider().background(Palette.separator).padding(.leading, 68)
                }
                chatList
            }
            .background(Palette.background)
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chatID: chat.id)
            }
            .navigationDestination(for: ArchivedRoute.self) { _ in
                ArchivedChatsView { chat in path.append(chat) }
            }
            // Hide the floating tab bar while a chat detail (or deeper) is open so it
            // doesn't cover the composer; restore it back at the list root.
            .onChange(of: path.count) { _, depth in tabBar.isHidden = depth > 0 }
            .sheet(isPresented: $showNewChat) {
                NewChatView { chat in
                    showNewChat = false
                    path.append(chat)
                }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView { chat in
                    showNewGroup = false
                    path.append(chat)
                }
            }
            .sheet(item: $capturedMedia) { media in
                PickChatSheet(title: "Send to") { chat in
                    stagePreview(media.content, for: chat)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                InditalkCameraView { capture in
                    capturedMedia = CapturedMedia(content: capture.draftContent)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $pendingCapture) { capture in
                AttachmentPreviewSheet(
                    drafts: [AttachmentDraft(content: capture.content)],
                    destinationTitle: capture.chat.title,
                    onSend: { drafts, caption in
                        AttachmentSender.send(drafts, caption: caption, to: capture.chat.id, store: store)
                        Haptics.impact(.light)
                        pendingCapture = nil
                        path.append(capture.chat)
                    },
                    onCancel: { pendingCapture = nil }
                )
            }
        }
        .tint(Palette.ink)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    Button { showNewGroup = true } label: { Label("New group", systemImage: "person.2") }
                    Button { markAllRead() } label: { Label("Mark all read", systemImage: "checkmark.circle") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 42, height: 42)
                        .background(Palette.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.separator, lineWidth: 1))
                }
                .accessibilityLabel("More")
                Spacer()
                CircleButton(symbol: "camera") { captureFromCamera() }
                CircleButton(symbol: "plus", filled: true, tint: Palette.ink) { showNewChat = true }
            }
            Text("Chats")
                .font(.inditalkTitle())
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 8)
    }

    // MARK: Header actions

    private func markAllRead() {
        for chat in store.visibleChats where chat.unreadCount > 0 { store.markRead(chat.id) }
        Haptics.selection()
    }

    private func captureFromCamera() {
        guard InditalkCameraView.isAvailable else {
            ToastCenter.shared.show("Camera isn't available on the Simulator")
            return
        }
        Task {
            if await PermissionsManager.shared.requestCamera() {
                showCamera = true
            } else {
                ToastCenter.shared.show("Camera access is off — enable it in Settings")
            }
        }
    }

    /// Hand a captured photo to the WhatsApp-style preview/caption screen once the
    /// chat-picker sheet has finished dismissing (avoids competing presentations).
    private func stagePreview(_ content: AttachmentDraft.Content, for chat: Chat) {
        capturedMedia = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            pendingCapture = PendingCapture(content: content, chat: chat)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textSecondary)
            TextField("Search or start a new chat", text: $vm.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Palette.textPrimary)
            if !vm.searchText.isEmpty {
                Button { vm.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.searchCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.searchCorner).strokeBorder(Palette.separator, lineWidth: 1))
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.vertical, 12)
    }

    private var archivedRow: some View {
        Button {
            path.append(ArchivedRoute())
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "archivebox")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.ochre)
                    .frame(width: Metrics.avatar, height: Metrics.avatar)
                Text("Archived")
                    .font(.inditalkRowName())
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(store.archivedChats.count)")
                    .font(.inditalkCaption())
                    .foregroundStyle(Palette.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Archived chats, \(store.archivedChats.count)")
    }

    // MARK: List

    private var chatList: some View {
        List {
            ForEach(vm.rows(store: store)) { row in
                Button {
                    path.append(row.chat)
                    store.markRead(row.chat.id)
                } label: {
                    ChatRowView(row: row)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: Metrics.screenPadding, bottom: 0, trailing: Metrics.screenPadding))
                .listRowBackground(Palette.background)
                .listRowSeparatorTint(Palette.separator)
                .alignmentGuide(.listRowSeparatorLeading) { _ in Metrics.avatar + 12 }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { store.togglePin(row.chat.id) } label: {
                        Label(row.chat.isPinned ? "Unpin" : "Pin", systemImage: "pin")
                    }.tint(Palette.ochre)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { store.toggleArchive(row.chat.id) } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button { store.toggleMute(row.chat.id) } label: {
                        Label(row.chat.isMuted ? "Unmute" : "Mute", systemImage: "bell.slash")
                    }.tint(Palette.ink)
                }
            }

            if vm.rows(store: store).isEmpty {
                emptyState
            }
        }
        .safeAreaPadding(.bottom, TabBarMetrics.reservedHeight)   // clear the floating tab bar
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(Palette.textSecondary.opacity(0.6))
            Text(vm.searchText.isEmpty ? "No chats yet" : "No results for “\(vm.searchText)”")
                .font(.inditalkRowName())
                .foregroundStyle(Palette.textPrimary)
            if vm.searchText.isEmpty {
                Text("Tap + to start a new conversation.")
                    .font(.inditalkRowSubtitle())
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .listRowBackground(Palette.background)
        .listRowSeparator(.hidden)
    }
}

#Preview {
    ChatListView()
        .environmentObject(DataStore.inMemory())
        .environmentObject(TabBarVisibility())
}
