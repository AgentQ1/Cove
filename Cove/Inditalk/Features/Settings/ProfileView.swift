//
//  ProfileView.swift
//  Inditalk
//
//  Edit the local user's profile. The photo (camera / library / remove) applies
//  instantly through MediaStore + DataStore.updateAvatar; name and about have
//  live length limits and persist on Save. Also hosts StarredMessagesView.
//

import SwiftUI
import PhotosUI

struct ProfileView: View {
    @EnvironmentObject private var store: DataStore
    @State private var name = ""
    @State private var about = ""
    @State private var hasLoadedDrafts = false
    @State private var showPhotoDialog = false
    @State private var showPhotoLibrary = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    /// A picked/captured photo waiting to be framed. Every photo goes through the
    /// move-and-scale step — an uncropped one lands in the circle arbitrarily.
    @State private var pendingCrop: PendingCrop?

    /// UIImage isn't Identifiable, and `fullScreenCover(item:)` needs identity.
    private struct PendingCrop: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private let nameLimit = 25
    private let aboutLimit = 139

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedAbout: String { about.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isDirty: Bool {
        trimmedName != store.currentUser.displayName || trimmedAbout != store.currentUser.about
    }
    private var isValid: Bool { !trimmedName.isEmpty }

    var body: some View {
        List {
            photoSection
            nameSection
            aboutSection
            Section("Phone") {
                Text(store.currentUser.phoneNumber).foregroundStyle(Palette.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.tint(Palette.ink).disabled(!isDirty || !isValid)
            }
        }
        // Seed the drafts only once — .fullScreenCover (camera/photo) removes the
        // presenter from the hierarchy, so re-firing onAppear would clobber in-progress
        // name/about edits with the stored values.
        .onAppear {
            guard !hasLoadedDrafts else { return }
            name = store.currentUser.displayName
            about = store.currentUser.about
            hasLoadedDrafts = true
        }
        .confirmationDialog("Profile Photo", isPresented: $showPhotoDialog, titleVisibility: .visible) {
            if CameraPicker.isAvailable {
                Button("Take Photo") { takePhoto() }
            }
            Button("Choose Photo") { showPhotoLibrary = true }
            if store.currentUser.avatarLocalName != nil {
                Button("Remove Photo", role: .destructive) { removePhoto() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoLibrary, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await applyPicked(item) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in pendingCrop = PendingCrop(image: image) }
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $pendingCrop) { pending in
            AvatarCropView(image: pending.image) { cropped in setAvatar(cropped) }
        }
    }

    // MARK: Sections

    private var photoSection: some View {
        Section {
            VStack(spacing: 12) {
                Button { showPhotoDialog = true } label: {
                    AvatarView(name: store.currentUser.displayName,
                               imageName: store.currentUser.avatarAsset,
                               localName: store.currentUser.avatarLocalName,
                               size: Metrics.avatarLarge)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change profile photo")
                Button("Edit") { showPhotoDialog = true }
                    .font(.system(size: 15, weight: .medium)).tint(Palette.ink)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Palette.background)
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Your name", text: $name)
                .foregroundStyle(Palette.textPrimary)
                .onChange(of: name) { _, value in
                    if value.count > nameLimit { name = String(value.prefix(nameLimit)) }
                }
        } header: { Text("Name") } footer: {
            HStack(alignment: .top) {
                if trimmedName.isEmpty {
                    Text("Your name can't be empty.").foregroundStyle(Palette.danger)
                } else {
                    Text("This is not your username or PIN. This name will be visible to your Inditalk contacts.")
                }
                Spacer()
                Text("\(name.count)/\(nameLimit)").monospacedDigit()
            }
        }
    }

    private var aboutSection: some View {
        Section {
            TextField("About", text: $about, axis: .vertical)
                .lineLimit(1...4)
                .foregroundStyle(Palette.textPrimary)
                .onChange(of: about) { _, value in
                    if value.count > aboutLimit { about = String(value.prefix(aboutLimit)) }
                }
        } header: { Text("About") } footer: {
            HStack(alignment: .top) {
                Text("A short line shown on your profile.")
                Spacer()
                Text("\(about.count)/\(aboutLimit)").monospacedDigit()
            }
        }
    }

    // MARK: Actions

    private func save() {
        store.updateProfile(name: trimmedName, about: trimmedAbout)
        // BACKEND INTEGRATION: DataStore.profileSink pushes this change to the
        // Firestore profile doc (wired by FirebaseSyncCoordinator when
        // AppConfig.usesFirebase) — keep routing edits through updateProfile.
        name = store.currentUser.displayName
        about = store.currentUser.about
        Haptics.impact(.light)
        ToastCenter.shared.show("Profile updated", pending: false)
    }

    private func takePhoto() {
        Task {
            if await PermissionsManager.shared.requestCamera() {
                showCamera = true
            } else {
                ToastCenter.shared.show("Camera access is off — enable it in Settings")
            }
        }
    }

    private func applyPicked(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            ToastCenter.shared.show("Couldn't load that photo")
            return
        }
        pendingCrop = PendingCrop(image: image)
    }

    /// Photo changes apply instantly — no Save step, matching platform conventions.
    private func setAvatar(_ image: UIImage) {
        // `dedupe: false`: replacing the avatar DELETES the old file, so it must own its
        // copy outright — sharing one with a chat attachment would delete that too.
        guard let saved = MediaStore.saveImage(image, dedupe: false) else {
            ToastCenter.shared.show("Couldn't save that photo")
            return
        }
        store.updateAvatar(localName: saved.name)
        Haptics.impact(.light)
        ToastCenter.shared.show("Profile photo updated", pending: false)
    }

    private func removePhoto() {
        store.updateAvatar(localName: nil)
        Haptics.impact(.light)
        ToastCenter.shared.show("Profile photo removed", pending: false)
    }
}

struct StarredMessagesView: View {
    @EnvironmentObject private var store: DataStore

    var body: some View {
        Group {
            let starred = store.allStarred()
            if starred.isEmpty {
                EmptyStateView(symbol: "star", title: "No starred messages",
                               message: "Tap and hold any message, then Star it to save it here.")
            } else {
                List(starred) { m in
                    // Tapping opens the conversation AT that message — a starred list you
                    // can't jump from is just a list of things you have to go find.
                    NavigationLink {
                        ChatDetailView(chatID: m.chatID, focusMessageID: m.id)
                    } label: {
                        row(for: m)
                    }
                    .listRowBackground(Palette.surface)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.toggleStar(m.id, in: m.chatID)
                        } label: {
                            Label("Unstar", systemImage: "star.slash")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Palette.background)
            }
        }
        .navigationTitle("Starred Messages")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Who sent it, where, what it said, and when. The body used to be `message.text`,
    /// which is EMPTY for a photo or a file — the row rendered blank.
    private func row(for message: Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(sender(of: message))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                if let chatTitle = store.chat(message.chatID)?.title,
                   chatTitle != sender(of: message) {
                    Text("in \(chatTitle)")
                        .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 4) {
                if let glyph = PreviewGlyph.attachment(for: message.kind) {
                    Image(systemName: glyph.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
                Text(store.preview(for: message))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
            }
            Text(RelativeDate.messageTime(message.sentAt))
                .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func sender(of message: Message) -> String {
        message.isOutgoing ? "You" : (store.users[message.senderID]?.displayName ?? "Unknown")
    }
}
