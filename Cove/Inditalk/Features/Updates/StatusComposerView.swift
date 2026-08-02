//
//  StatusComposerView.swift
//  Inditalk
//
//  Composing a status update. Text mode is a full-screen card editor on a curated
//  background color (cycle button top-right); photo and video modes run PhotosPicker
//  into a preview with an optional caption. All post through DataStore.postStatus,
//  with media bytes persisted by MediaStore first.
//

import AVKit
import SwiftUI
import PhotosUI

/// Which composer the chooser picked (drives the full-screen cover).
enum StatusComposerMode: String, Identifiable {
    case text, photo, video
    var id: String { rawValue }
}

struct StatusComposerView: View {
    let mode: StatusComposerMode

    var body: some View {
        switch mode {
        case .text: TextStatusComposer()
        case .photo: PhotoStatusComposer()
        case .video: VideoStatusComposer()
        }
    }
}

// MARK: - Text status

private struct TextStatusComposer: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var paletteIndex = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            StatusPalette.color(at: paletteIndex).ignoresSafeArea()

            TextField("Type a status",
                      text: $text,
                      prompt: Text("Type a status").foregroundStyle(.white.opacity(0.55)),
                      axis: .vertical)
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .tint(.white)
                .multilineTextAlignment(.center)
                .lineLimit(1...10)
                .focused($focused)
                .padding(.horizontal, 28)
        }
        .overlay(alignment: .top) { topBar }
        .safeAreaInset(edge: .bottom) { postBar }
        .onAppear { focused = true }
    }

    private var topBar: some View {
        HStack {
            ChromeCircleButton(symbol: "xmark") { dismiss() }
            Spacer()
            ChromeCircleButton(symbol: "paintpalette.fill") {
                withAnimation(.snappy) {
                    paletteIndex = (paletteIndex + 1) % StatusPalette.colors.count
                }
                Haptics.selection()
            }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 8)
    }

    private var postBar: some View {
        HStack {
            Spacer()
            Button(action: post) {
                HStack(spacing: 8) {
                    Text("Post").font(.system(size: 17, weight: .semibold))
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20, weight: .semibold))
                }
                .foregroundStyle(canPost ? Palette.textPrimary : Palette.textSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.white.opacity(canPost ? 0.95 : 0.4), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canPost)
            .accessibilityLabel("Post status")
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.bottom, 10)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canPost: Bool { !trimmed.isEmpty }

    private func post() {
        guard canPost else { return }
        store.postStatus(kind: .text, text: trimmed, localName: nil, paletteIndex: paletteIndex)
        Haptics.impact(.light)
        dismiss()
    }
}

// MARK: - Photo status

private struct PhotoStatusComposer: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = true
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var caption = ""
    @FocusState private var captionFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .top) { topBar }
        .safeAreaInset(edge: .bottom) {
            if image != nil { captionBar }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
        .onChange(of: showPicker) { _, showing in
            guard !showing else { return }
            // Give the selection binding a beat to land; if the picker was simply
            // cancelled there is nothing to compose, so close the cover.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if pickerItem == nil && image == nil { dismiss() }
            }
        }
    }

    private var topBar: some View {
        HStack {
            ChromeCircleButton(symbol: "xmark") { dismiss() }
            Spacer()
            if image != nil {
                ChromeCircleButton(symbol: "photo.on.rectangle") { showPicker = true }
            }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 8)
    }

    private var captionBar: some View {
        HStack(spacing: 10) {
            TextField("Add a caption…",
                      text: $caption,
                      prompt: Text("Add a caption…").foregroundStyle(.white.opacity(0.55)))
                .foregroundStyle(.white)
                .tint(.white)
                .focused($captionFocused)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(.white.opacity(0.15), in: Capsule())

            Button(action: post) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Palette.pine, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Post status")
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.bottom, 10)
    }

    private func load(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let ui = UIImage(data: data) else {
            ToastCenter.shared.show("Couldn't load that photo")
            dismiss()
            return
        }
        image = ui
    }

    private func post() {
        // `dedupe: false`: a status deletes its own file when it expires (24h) or is
        // removed, so it must not share one with a chat attachment that outlives it.
        guard let image, let saved = MediaStore.saveImage(image, dedupe: false) else {
            ToastCenter.shared.show("Couldn't save that photo")
            return
        }
        store.postStatus(kind: .photo,
                         text: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                         localName: saved.name,
                         paletteIndex: 0)
        Haptics.impact(.light)
        dismiss()
    }
}

// MARK: - Video status

private struct VideoStatusComposer: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = true
    @State private var pickerItem: PhotosPickerItem?
    /// MediaStore file name for the imported movie, once it has been copied in.
    @State private var localName: String?
    @State private var player: AVPlayer?
    @State private var caption = ""
    @State private var isImporting = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                // Loop the preview so the composer behaves like the viewer will.
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    if isImporting {
                        Text("Preparing video…")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
        .overlay(alignment: .top) { topBar }
        .safeAreaInset(edge: .bottom) {
            if localName != nil { captionBar }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .videos)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
        .onChange(of: showPicker) { _, showing in
            guard !showing else { return }
            // Give the selection binding a beat to land; a cancelled picker leaves
            // nothing to compose, so close the cover.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if pickerItem == nil && localName == nil { dismiss() }
            }
        }
        .onDisappear { player?.pause() }
    }

    private var topBar: some View {
        HStack {
            ChromeCircleButton(symbol: "xmark") { dismiss() }
            Spacer()
            if localName != nil {
                ChromeCircleButton(symbol: "video.badge.plus") { showPicker = true }
            }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 8)
    }

    private var captionBar: some View {
        HStack(spacing: 10) {
            TextField("Add a caption…",
                      text: $caption,
                      prompt: Text("Add a caption…").foregroundStyle(.white.opacity(0.55)))
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(.white.opacity(0.15), in: Capsule())

            Button(action: post) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Palette.ink, in: Circle())
            }
            .accessibilityLabel("Post video status")
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.bottom, 10)
    }

    /// Copy the picked movie into MediaStore. Videos are far too large to hold in
    /// memory as `Data`, so this streams through a temporary file on disk.
    private func load(_ item: PhotosPickerItem) async {
        isImporting = true
        defer { isImporting = false }

        guard let movie = try? await item.loadTransferable(type: StatusMovie.self) else {
            ToastCenter.shared.show("Couldn't load that video")
            dismiss()
            return
        }
        defer { try? FileManager.default.removeItem(at: movie.url) }

        // `dedupe: false` for the same reason as the photo path above.
        guard let saved = MediaStore.importMovie(from: movie.url, dedupe: false) else {
            ToastCenter.shared.show("Couldn't save that video")
            dismiss()
            return
        }
        localName = saved.name
        player = AVPlayer(url: MediaStore.url(for: saved.name))
    }

    private func post() {
        guard let localName else { return }
        store.postStatus(kind: .video,
                         text: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                         localName: localName,
                         paletteIndex: 0)
        Haptics.impact(.light)
        dismiss()
    }
}

/// Receives a picked video as a file URL. PhotosPicker hands over a temporary file that
/// is deleted when the transfer scope ends, so it is copied somewhere we control first.
private struct StatusMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("status-\(UUID().uuidString).\(received.file.pathExtension)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return StatusMovie(url: copy)
        }
    }
}

// MARK: - Shared chrome

/// Translucent circular chrome button used over status card / photo backgrounds
/// (the parchment-toned `CircleButton` would fight the immersive backdrop).
private struct ChromeCircleButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}
