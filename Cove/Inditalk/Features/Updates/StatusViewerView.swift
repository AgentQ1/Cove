//
//  StatusViewerView.swift
//  Inditalk
//
//  Full-screen story-style pager over one author's active statuses: segmented
//  progress bars auto-advance (~5s each, hold to pause), tap left/right halves to
//  step, swipe down to dismiss. Others' updates are marked viewed as they appear;
//  the local user can delete their own from here.
//

import AVKit
import SwiftUI
import Combine

struct StatusViewerView: View {
    let user: InditalkUser
    let isMine: Bool

    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var progress: Double = 0        // 0…1 through the current segment
    @State private var isPaused = false
    @State private var confirmDelete = false
    @State private var showViewers = false
    @State private var dragOffset: CGFloat = 0
    /// The current photo segment, decoded ONCE (downsampled, off-main) and cached.
    /// The progress ticker re-renders this body 20×/s; loading the image inside the
    /// render (the old `MediaStore.image` call) re-decoded the full-resolution photo
    /// every tick, which froze the main thread and could OOM-crash the app.
    @State private var loadedPhoto: LoadedPhoto?

    private struct LoadedPhoto: Equatable {
        let name: String
        let image: UIImage
    }

    private let segmentDuration: Double = 5
    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    /// Live projection so deletes and viewed flags stay in sync with the store.
    private var updates: [StatusUpdate] {
        isMine ? store.myActiveStatuses
               : (store.othersActiveStatuses.first { $0.user.id == user.id }?.updates ?? [])
    }

    private var current: StatusUpdate? {
        updates.indices.contains(index) ? updates[index] : nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let current {
                    content(for: current)
                }
            }
            .overlay(alignment: .top) { topChrome }
            .overlay(alignment: .bottom) { if isMine { viewersBar } }
            .contentShape(Rectangle())
            .onTapGesture { point in
                if point.x < geo.size.width / 2 { goPrevious() } else { goNext() }
            }
            .onLongPressGesture(minimumDuration: 0.2,
                                perform: {},
                                onPressingChanged: { isPaused = $0 })
        }
        .background(Color.black.ignoresSafeArea())
        .offset(y: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { dragOffset = max(0, $0.translation.height) }
                .onEnded { value in
                    if value.translation.height > 100 {
                        dismiss()
                    } else {
                        withAnimation(.snappy) { dragOffset = 0 }
                    }
                }
        )
        .onReceive(ticker) { _ in tick() }
        .onAppear {
            print("[Inditalk status] viewer opened for \(isMine ? "self" : user.displayName) "
                  + "with \(updates.count) update(s)")
            markViewedIfNeeded()
        }
        .task(id: photoKey) { await loadPhotoIfNeeded() }
        .confirmationDialog("Delete this status?",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
        } message: {
            Text("It will be removed for everyone who can see your updates.")
        }
        .sheet(isPresented: $showViewers) {
            StatusViewersSheet(viewers: currentViewers)
                .environmentObject(store)
        }
    }

    // MARK: Chrome

    private var topChrome: some View {
        VStack(spacing: 12) {
            progressBars
            header
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.5), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var progressBars: some View {
        HStack(spacing: 4) {
            ForEach(updates.indices, id: \.self) { i in
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3))
                        Capsule().fill(.white)
                            .frame(width: bar.size.width * fill(for: i))
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private func fill(for i: Int) -> CGFloat {
        if i < index { return 1 }
        if i == index { return CGFloat(min(max(progress, 0), 1)) }
        return 0
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(name: user.displayName,
                       imageName: user.avatarAsset,
                       localName: user.avatarLocalName,
                       remoteURL: user.avatarURL,
                       size: Metrics.avatarSmall)
            VStack(alignment: .leading, spacing: 1) {
                Text(isMine ? "My status" : user.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                if let current {
                    Text(StatusTime.label(current.createdAt))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            Spacer()
            if isMine {
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete status")
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: Seen-by (own statuses only)

    private var currentViewers: [StatusViewer] {
        guard let current else { return [] }
        return store.viewers(of: current.id)
    }

    /// WhatsApp-style footer: eye + count, tapping opens the full list. Shown even at
    /// zero so the author knows where the count will appear.
    private var viewersBar: some View {
        let viewers = currentViewers
        return Button {
            guard !viewers.isEmpty else { return }
            showViewers = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: viewers.isEmpty ? "eye" : "eye.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(viewers.isEmpty ? "No views yet" : "\(viewers.count)")
                    .font(.system(size: 15, weight: .semibold))
                if !viewers.isEmpty {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.45), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewers.isEmpty)
        .padding(.bottom, 28)
        .accessibilityLabel(viewers.isEmpty
                            ? "No views yet"
                            : "Viewed by \(viewers.count). Double tap to see who.")
    }

    // MARK: Status content

    @ViewBuilder
    private func content(for status: StatusUpdate) -> some View {
        switch status.kind {
        case .text:
            ZStack {
                StatusPalette.color(at: status.paletteIndex).ignoresSafeArea()
                Text(status.text)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(36)
            }
        case .photo:
            photoContent(for: status)
        case .video:
            videoContent(for: status)
        }
    }

    /// Plays a video status. Falls back to a caption card when the file is missing —
    /// media cleared from Storage settings, or a status synced before its download
    /// finished — so the viewer never shows an empty black screen.
    @ViewBuilder
    private func videoContent(for status: StatusUpdate) -> some View {
        if let localName = status.localName, MediaStore.exists(localName) {
            StatusVideoPlayer(url: MediaStore.url(for: localName))
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    if !status.text.isEmpty {
                        Text(status.text)
                            .font(.system(size: 17))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(.black.opacity(0.35))
                            .padding(.bottom, 90)
                    }
                }
        } else {
            ZStack {
                StatusPalette.color(at: status.paletteIndex).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(status.text.isEmpty ? "This video isn't available" : status.text)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                .padding(36)
            }
        }
    }

    private func photoContent(for status: StatusUpdate) -> some View {
        ZStack {
            if let loaded = loadedPhoto, loaded.name == status.localName {
                Image(uiImage: loaded.image)
                    .resizable()
                    .scaledToFit()
            } else if let localName = status.localName, MediaStore.exists(localName) {
                ProgressView().tint(.white)      // decode in flight (see loadPhotoIfNeeded)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Photo unavailable")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !status.text.isEmpty {
                Text(status.text)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .bottom)
                    )
            }
        }
    }

    // MARK: Photo loading

    /// Identity of the photo the current segment needs (nil for text/video segments).
    /// Driving `.task(id:)` off this reloads exactly when the segment's media changes —
    /// including when a pending download lands (localName nil -> filename).
    private var photoKey: String? {
        guard let current, current.kind == .photo else { return nil }
        return current.localName
    }

    private func loadPhotoIfNeeded() async {
        guard let name = photoKey else { return }
        if loadedPhoto?.name == name { return }
        guard MediaStore.exists(name) else {
            print("[Inditalk status] photo \(name) not on disk yet (download pending?)")
            return
        }
        // ~2x a portrait screen is plenty for a full-screen story photo.
        if let image = await MediaStore.downsampledImage(named: name, maxPixels: 2200) {
            loadedPhoto = LoadedPhoto(name: name, image: image)
        } else {
            print("[Inditalk status] failed to decode photo \(name)")
        }
    }

    // MARK: Playback

    private func tick() {
        guard !updates.isEmpty else { dismiss(); return }
        guard !isPaused, !confirmDelete, !showViewers, dragOffset == 0 else { return }
        progress += 0.05 / segmentDuration
        if progress >= 1 { goNext() }
    }

    private func goNext() {
        if index < updates.count - 1 {
            index += 1
            progress = 0
            markViewedIfNeeded()
        } else {
            dismiss()   // advancing past the last status closes the viewer
        }
    }

    private func goPrevious() {
        if index > 0 { index -= 1 }
        progress = 0
    }

    private func markViewedIfNeeded() {
        guard !isMine, let current else { return }
        store.markStatusViewed(current.id)
    }

    private func deleteCurrent() {
        guard let current else { return }
        store.deleteStatus(current.id)
        if updates.isEmpty {
            dismiss()
            return
        }
        index = min(index, updates.count - 1)
        progress = 0
    }
}

/// "Viewed by" list for one of the author's own statuses — who watched it and when,
/// newest first. Presented from the viewer's eye/count footer.
private struct StatusViewersSheet: View {
    let viewers: [StatusViewer]

    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewers) { viewer in
                    let contact = store.users[viewer.id]
                    HStack(spacing: 12) {
                        AvatarView(name: displayName(for: viewer),
                                   imageName: contact?.avatarAsset,
                                   localName: contact?.avatarLocalName,
                                   remoteURL: contact?.avatarURL,
                                   size: Metrics.avatarSmall)
                        Text(displayName(for: viewer))
                            .font(.system(size: 16))
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        Text(StatusTime.label(viewer.viewedAt))
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .listRowBackground(Palette.surface)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Viewed by \(viewers.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Prefer the locally known contact name (respects renames) over the name the
    /// viewer stamped on their receipt.
    private func displayName(for viewer: StatusViewer) -> String {
        let local = store.users[viewer.id]?.displayName
        if let local, !local.isEmpty { return local }
        return viewer.displayName.isEmpty ? "Unknown" : viewer.displayName
    }
}

/// Auto-playing, looping player for a video status.
///
/// Kept separate from `VideoPlayerScreen` (the chat media viewer) because a status has
/// no player chrome: it fills the screen, starts immediately, loops for as long as the
/// story segment is on screen, and is torn down when the pager moves on.
private struct StatusVideoPlayer: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        let created = AVPlayer(url: url)
        created.isMuted = false
        // Loop: statuses are short, and a frozen last frame reads as a broken video.
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: created.currentItem,
            queue: .main
        ) { _ in
            created.seek(to: .zero)
            created.play()
        }
        player = created
        created.play()
    }

    private func stop() {
        player?.pause()
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        player = nil
    }
}
