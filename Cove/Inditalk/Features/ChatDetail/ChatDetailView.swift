//
//  ChatDetailView.swift
//  Inditalk
//
//  One conversation. Custom header (back + avatar + name + presence + call buttons),
//  a scrollable transcript with day separators / system notices / message bubbles,
//  and the composer pinned to the bottom — swapped for the voice recording/preview
//  bars while a voice message is being captured. Mirrors the reference chat screen.
//

import SwiftUI
import UIKit

struct ChatDetailView: View {
    let chatID: UUID
    /// Open scrolled to a specific message instead of the bottom, and flash it — how you
    /// arrive here from Starred Messages (and anywhere else that links to one message).
    var focusMessageID: UUID?
    @EnvironmentObject private var store: DataStore
    @StateObject private var vm = ChatDetailViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showInfo = false
    @State private var forwarding: Message?
    @State private var infoMessage: Message?
    @State private var sharing: SharePayload?
    @State private var showCamera = false
    @State private var cameraBatch: DraftBatch?
    @State private var showMicSettingsAlert = false
    @State private var showCameraSettingsAlert = false
    /// The message being pointed at, tinted until it has been seen.
    @State private var highlightedMessageID: UUID?

    /// Wraps captured drafts so `.fullScreenCover(item:)` drives the preview screen.
    private struct DraftBatch: Identifiable {
        let id = UUID()
        let drafts: [AttachmentDraft]
    }

    /// What to hand the system share sheet, wrapped so `.sheet(item:)` drives it.
    private struct SharePayload: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    private var chat: Chat? { store.chat(chatID) }
    private var isBlocked: Bool { store.isBlockedChat(chatID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Palette.separator)
            transcript
            if isBlocked {
                blockedBar
            } else {
                composerArea
            }
        }
        .background(Palette.background)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $vm.showAttachments) {
            MediaPickerView(chatID: chatID) { vm.showAttachments = false }
                .presentationDetents([.medium])
        }
        .sheet(item: $forwarding) { message in
            ForwardSheet(message: message)
        }
        .sheet(item: $infoMessage) { message in
            MessageInfoSheet(message: message)
                .presentationDetents([.medium])
        }
        .sheet(item: $sharing) { payload in
            ShareSheet(items: payload.items)
        }
        .fullScreenCover(isPresented: $showCamera) {
            InditalkCameraView { capture in queueCameraPreview(capture) }
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $cameraBatch) { batch in
            AttachmentPreviewSheet(
                drafts: batch.drafts,
                destinationTitle: chat?.title ?? "Chat",
                onSend: { drafts, caption in
                    AttachmentSender.send(drafts, caption: caption, to: chatID, store: store)
                    cameraBatch = nil
                },
                onCancel: { cameraBatch = nil }
            )
        }
        .navigationDestination(isPresented: $showInfo) {
            if let chat { ContactDetailView(chat: chat) }
        }
        .alert("Microphone access is off", isPresented: $showMicSettingsAlert) {
            Button("Open Settings") { openAppSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Inditalk needs the microphone to record voice messages. Allow access in Settings.")
        }
        .alert("Camera access is off", isPresented: $showCameraSettingsAlert) {
            Button("Open Settings") { openAppSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow camera access in Settings to take photos in Inditalk.")
        }
        .onAppear { store.markRead(chatID) }
        .onDisappear { vm.cancelVoiceRecording() }
    }

    // MARK: Composer area (text composer or voice capture bars)

    @ViewBuilder private var composerArea: some View {
        switch vm.voiceState {
        case .idle, .starting:
            ComposerView(
                vm: vm,
                onSend: { vm.send(into: chatID, store: store) },
                onAttach: { vm.showAttachments = true },
                onVoiceStart: { startVoiceNote() },
                onCamera: { captureFromCamera() }
            )
        case .recording:
            VoiceRecordingBar(
                recorder: vm.recorder,
                onCancel: { vm.cancelVoiceRecording() },
                onStop: { vm.finishVoiceRecording() }
            )
        case .preview(let recording):
            VoicePreviewBar(
                recording: recording,
                playbackID: vm.voicePreviewID,
                onDelete: { vm.cancelVoiceRecording() },
                onSend: { vm.sendVoiceNote(to: chatID, store: store) }
            )
        }
    }

    // MARK: Calling

    /// Place a REAL call: resolve the peer's Firebase uid, take the permissions iOS
    /// requires, then hand off to CallCenter (WebRTC + Firestore signaling) and present
    /// the live call screen. Every failure path says what went wrong instead of opening
    /// a screen that only looks like a call.
    private func startCall(video: Bool) {
        // Call buttons are shown for 1:1 chats only, so anything else is simply an
        // unresolvable target rather than a separate "groups aren't supported" case.
        guard let chat, chat.kind == .direct, let peer = peerUser else {
            ToastCenter.shared.show("Couldn't find who to call in this chat", pending: false)
            return
        }
        guard let peerUID = peer.remoteUID, !peerUID.isEmpty else {
            ToastCenter.shared.show("\(peer.displayName) isn't on Inditalk yet", pending: false)
            return
        }

        Task {
            guard await PermissionsManager.shared.requestMicrophone() else {
                showMicSettingsAlert = true
                return
            }
            if video, await PermissionsManager.shared.requestCamera() == false {
                showCameraSettingsAlert = true
                return
            }
            // RootView presents LiveCallView globally off CallCenter state, so this
            // works for calls placed from ANY screen and for answered incoming calls.
            CallCenter.shared.placeCall(to: peerUID, peerName: peer.displayName, video: video)
        }
    }

    /// The other person in a direct chat.
    private var peerUser: InditalkUser? {
        guard let chat else { return nil }
        return chat.participantIDs
            .first { $0 != store.currentUser.id }
            .flatMap { store.users[$0] }
    }

    // MARK: Composer actions

    private func captureFromCamera() {
        guard InditalkCameraView.isAvailable else {
            ToastCenter.shared.show("Camera isn't available on the Simulator", pending: false)
            return
        }
        Task {
            if await PermissionsManager.shared.requestCamera() {
                showCamera = true
            } else {
                showCameraSettingsAlert = true
            }
        }
    }

    /// Captures route through the preview/caption screen — nothing sends without it.
    /// Small delay lets the camera cover finish dismissing first.
    private func queueCameraPreview(_ capture: InditalkCameraView.Capture) {
        let content = capture.draftContent
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            cameraBatch = DraftBatch(drafts: [AttachmentDraft(content: content)])
        }
    }

    private func startVoiceNote() {
        Task {
            if await PermissionsManager.shared.requestMicrophone() {
                if !(await vm.beginVoiceRecording()) {
                    ToastCenter.shared.show("Couldn't start recording", pending: false)
                }
            } else {
                showMicSettingsAlert = true
            }
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                HStack(spacing: 2) {
                    // Styled as the SYSTEM back control (the one the navigation bar draws
                    // on the screens that keep it, e.g. ContactDetailView) rather than as
                    // an ochre chevron: this header replaces the nav bar, so a second,
                    // differently-coloured back affordance was the only thing making
                    // "back" look like two different buttons in the same app.
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                    if store.totalUnread > 0 {
                        Text("\(store.totalUnread)").font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundStyle(Palette.ink)
            }
            .accessibilityLabel("Back")

            Button { showInfo = true } label: {
                HStack(spacing: 10) {
                    AvatarView(name: chat?.title ?? "", imageName: chat?.avatarAsset,
                               localName: peerUser?.avatarLocalName,
                               remoteURL: peerUser?.avatarURL,
                               systemImage: chat?.kind == .group ? "person.2.fill" : nil,
                               size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(chat?.title ?? "")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            if chat?.isVerified == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 13)).foregroundStyle(Palette.ink)
                            }
                        }
                        if let line = presenceLine {
                            Text(line).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Group calling has no SFU yet, so the buttons are hidden in group chats
            // rather than shown and then refused — an offered control that always fails
            // reads as a broken feature (and App Review treats it as one).
            if !isBlocked, chat?.kind != .group {
                HStack(spacing: 4) {
                    CircleButton(symbol: "video", tint: Palette.ink) { startCall(video: true) }
                    CircleButton(symbol: "phone", tint: Palette.ink) { startCall(video: false) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.background)
    }

    /// Replaces the composer for a blocked contact — messaging/calling is disabled
    /// until the user unblocks them (App Review UGC expectation: blocking is enforced,
    /// not cosmetic).
    private var blockedBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(Palette.danger)
            Text("You blocked this contact.")
                .font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
            Spacer()
            if let other = chat.flatMap({ store.otherParticipant(in: $0) }) {
                Button("Unblock") { store.unblock(other.id); Haptics.impact(.light) }
                    .font(.system(size: 15, weight: .semibold)).tint(Palette.ink)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Palette.surface)
        .overlay(alignment: .top) { Divider().background(Palette.separator) }
    }

    private var presenceLine: String? {
        guard let chat, chat.kind == .direct,
              let otherID = chat.participantIDs.first(where: { $0 != store.currentUser.id }),
              let user = store.users[otherID] else {
            if chat?.kind == .group { return "\(chat?.participantIDs.count ?? 0) members" }
            return nil
        }
        // Last Seen reciprocity: if you don't share your last seen, you don't see theirs
        // (mirrors the read-receipts reciprocity and the privacy screen's promise).
        if store.privacy.lastSeen == .nobody { return nil }
        return RelativeDate.presenceLine(user.presence.resolved)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if let pinned = pinnedMessage {
                    pinnedBanner(pinned) {
                        withAnimation { proxy.scrollTo(pinned.id, anchor: .center) }
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(vm.sections(store.messages(in: chatID))) { section in
                            Pill { Text(section.title).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.textSecondary) }
                                .padding(.vertical, 8)

                            ForEach(section.messages) { message in
                                if message.kind == .system {
                                    SystemNotice(text: message.text)
                                } else {
                                    MessageBubbleView(
                                        message: message,
                                        replyPreview: replyPreview(for: message),
                                        senderName: senderName(for: message)
                                    )
                                    .id(message.id)
                                    .background(highlightedMessageID == message.id
                                                ? Palette.ochre.opacity(0.18) : .clear)
                                    .animation(.easeOut(duration: 0.45), value: highlightedMessageID)
                                    .contextMenu { messageMenu(message) }
                                }
                            }
                        }
                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.top, 8)
                }
                .background(Palette.background)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.messages(in: chatID).count) { _, _ in
                    // A new message must not yank the view away from a message you were
                    // sent here to read.
                    guard highlightedMessageID == nil else { return }
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear {
                    guard let focusMessageID else {
                        proxy.scrollTo("bottom", anchor: .bottom)
                        return
                    }
                    // One layout pass first: the target's row doesn't exist yet on the
                    // very first frame, so scrolling to it immediately does nothing.
                    DispatchQueue.main.async {
                        proxy.scrollTo(focusMessageID, anchor: .center)
                        highlightedMessageID = focusMessageID
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        highlightedMessageID = nil
                    }
                }
            }
        }
    }

    /// The most recently pinned, still-visible message (drives the banner).
    private var pinnedMessage: Message? {
        store.messages(in: chatID).last { $0.isPinned && !$0.isDeleted }
    }

    /// Compact strip above the transcript for the pinned message; tap scrolls to it.
    private func pinnedBanner(_ message: Message, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12)).foregroundStyle(Palette.ochre)
                if let symbol = MessageBubbleView.summarySymbol(for: message) {
                    Image(systemName: symbol)
                        .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                }
                Text(MessageBubbleView.summaryText(for: message))
                    .font(.system(size: 13)).foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    store.togglePinMessage(message.id, in: chatID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unpin")
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, 8)
            .background(Palette.surface)
            .overlay(alignment: .bottom) { Divider().background(Palette.separator) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pinned: \(MessageBubbleView.summaryText(for: message))")
    }

    /// Activity items for the system share sheet, or nil when there's nothing to share.
    ///
    /// Media is shared as its FILE URL rather than a decoded `UIImage`: the URL keeps
    /// the original bytes and filename, which is what "Save Image", "Save to Files" and
    /// AirDrop need. Bundled sample assets have no file on disk, so those fall back to
    /// the image itself; text messages share their text.
    private func shareItems(for message: Message) -> [Any]? {
        guard !message.isDeleted else { return nil }

        if let attachment = message.attachment {
            if let localName = attachment.localName, MediaStore.exists(localName) {
                return [MediaStore.url(for: localName)]
            }
            if let assetName = attachment.assetName, let image = UIImage(named: assetName) {
                return [image]
            }
        }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : [text]
    }

    @ViewBuilder private func messageMenu(_ message: Message) -> some View {
        // Reaction row (compact horizontal strip at the top of the menu).
        ControlGroup {
            ForEach(["👍","❤️","😂","😮","😢","🙏"], id: \.self) { e in
                Button(e) { store.addReaction(e, to: message.id, in: chatID) }
            }
        }
        .controlGroupStyle(.compactMenu)

        Button { vm.replyingTo = message } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        if message.isOutgoing && message.state == .failed {
            Button { store.resend(message.id, in: chatID) } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
        }
        Button { forwarding = message } label: {
            Label("Forward", systemImage: "arrowshape.turn.up.right")
        }
        if let payload = shareItems(for: message) {
            Button { sharing = SharePayload(items: payload) } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        if !message.text.isEmpty && !message.isDeleted {
            Button { UIPasteboard.general.string = message.text } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        Button { store.toggleStar(message.id, in: chatID) } label: {
            Label(message.isStarred ? "Unstar" : "Star",
                  systemImage: message.isStarred ? "star.slash" : "star")
        }
        Button { store.togglePinMessage(message.id, in: chatID) } label: {
            Label(message.isPinned ? "Unpin" : "Pin",
                  systemImage: message.isPinned ? "pin.slash" : "pin")
        }
        Button { infoMessage = message } label: { Label("Info", systemImage: "info.circle") }
        if message.isOutgoing, message.kind == .text, !message.isDeleted {
            Button { vm.beginEdit(message) } label: { Label("Edit", systemImage: "pencil") }
        }
        Divider()
        if message.isOutgoing && !message.isDeleted {
            Button(role: .destructive) { store.deleteMessage(message.id, in: chatID) } label: {
                Label("Delete for Everyone", systemImage: "trash")
            }
        }
        Button(role: .destructive) { store.hideMessage(message.id, in: chatID) } label: {
            Label("Delete for Me", systemImage: "trash")
        }
    }

    private func replyPreview(for message: Message) -> Message? {
        guard let id = message.replyToID else { return nil }
        return store.messages(in: chatID).first { $0.id == id }
    }

    private func senderName(for message: Message) -> String? {
        guard chat?.kind == .group, !message.isOutgoing else { return nil }
        return store.users[message.senderID]?.displayName
    }
}

/// Message info: delivery state + timestamps + attachment facts, WhatsApp-style.
/// Per-state receipt times need the receipts subcollection listener (a documented
/// backend item), so for now the sheet shows what the client actually knows.
struct MessageInfoSheet: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    infoRow("Sent", message.sentAt.formatted(date: .abbreviated, time: .shortened))
                    if message.isOutgoing {
                        HStack {
                            Text("Status").foregroundStyle(Palette.textSecondary)
                            Spacer()
                            ReceiptTicks(state: message.state)
                            Text(stateLabel).foregroundStyle(Palette.textPrimary)
                        }
                    }
                    if let editedAt = message.editedAt {
                        infoRow("Edited", editedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .listRowBackground(Palette.surface)

                if let attachment = message.attachment {
                    Section("Attachment") {
                        if let fileName = attachment.fileName { infoRow("File", fileName) }
                        if let bytes = attachment.byteSize { infoRow("Size", MediaStore.sizeLabel(bytes)) }
                        if let duration = attachment.durationSeconds {
                            infoRow("Duration", RelativeDate.duration(Int(duration)))
                        }
                    }
                    .listRowBackground(Palette.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Message info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.ink)
                }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Palette.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var stateLabel: String {
        switch message.state {
        case .sending:   return "Sending…"
        case .sent:      return "Sent"
        case .delivered: return "Delivered"
        case .read:      return "Read"
        case .failed:    return "Failed"
        }
    }
}

/// Centered info/system bubble (encryption notice, disappearing-message notes).
struct SystemNotice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Palette.bubbleSystem, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 320)
            .padding(.horizontal, 40)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(text)
    }
}
