//
//  AttachmentPreview.swift
//  Inditalk
//
//  WhatsApp-style pre-send review. Every attachment (photo, video, file, audio,
//  location, contact) flows through this full-screen dark preview — paged when
//  multiple — where the user can add a caption before anything is actually sent.
//  `AttachmentSender` is the single funnel that persists drafts via MediaStore
//  and hands them to DataStore.
//

import SwiftUI
import UIKit
import AVKit
import AVFoundation
import PDFKit
import MapKit
import UniformTypeIdentifiers

// MARK: - Draft model

/// One pending attachment awaiting the WhatsApp-style preview/caption screen.
struct AttachmentDraft: Identifiable {
    enum Content {
        case image(UIImage)
        case video(URL)                          // local or security-scoped-copied file URL
        case file(URL, displayName: String)      // document or audio file already copied into a readable location
        case audioRecording(localName: String, duration: TimeInterval, waveform: [Float])
        case location(latitude: Double, longitude: Double)
        case contact(name: String, phone: String)
    }
    let id = UUID()
    var content: Content
}

// MARK: - Preview sheet

/// Full-screen preview + "Add a caption..." field + send button. Vertical, dark, WhatsApp-style.
struct AttachmentPreviewSheet: View {
    let drafts: [AttachmentDraft]
    let destinationTitle: String                 // e.g. chat title, shown near send
    var allowCaption: Bool = true
    let onSend: ([AttachmentDraft], String) -> Void   // (drafts, caption)
    let onCancel: () -> Void

    @State private var caption = ""
    @State private var pageIndex = 0
    @FocusState private var captionFocused: Bool

    init(drafts: [AttachmentDraft],
         destinationTitle: String,
         allowCaption: Bool = true,
         onSend: @escaping ([AttachmentDraft], String) -> Void,
         onCancel: @escaping () -> Void) {
        self.drafts = drafts
        self.destinationTitle = destinationTitle
        self.allowCaption = allowCaption
        self.onSend = onSend
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        // The preview is always dark (media-first), so resolve Palette tokens in
        // their dark variants regardless of the system appearance.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onDisappear {
            // Stop any draft audio still playing when the sheet goes away.
            if let playing = AudioPlayerService.shared.playingID,
               drafts.contains(where: { $0.id == playing }) {
                AudioPlayerService.shared.stop()
            }
        }
    }

    private var topBar: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(destinationTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if drafts.count > 1 {
                    Text("\(min(pageIndex, drafts.count - 1) + 1) of \(drafts.count)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 60)

            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Cancel")
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder private var content: some View {
        if drafts.count > 1 {
            TabView(selection: $pageIndex) {
                ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                    DraftPreviewPage(draft: draft)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let draft = drafts.first {
            DraftPreviewPage(draft: draft)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.black
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if allowCaption {
                TextField("", text: $caption,
                          prompt: Text("Add a caption...").foregroundStyle(.white.opacity(0.55)),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused($captionFocused)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(Color.white.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                Spacer()
            }

            Button {
                onSend(drafts, caption)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(width: 46, height: 46)
                    .background(Palette.ink, in: Circle())
            }
            .accessibilityLabel("Send to \(destinationTitle)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

// MARK: - Per-kind preview pages

private struct DraftPreviewPage: View {
    let draft: AttachmentDraft

    var body: some View {
        switch draft.content {
        case .image(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .video(let url):
            VideoDraftPage(url: url)
        case .file(let url, let displayName):
            FileDraftPage(url: url, displayName: displayName, draftID: draft.id)
        case .audioRecording(let localName, let duration, let waveform):
            AudioDraftPage(url: MediaStore.url(for: localName), draftID: draft.id,
                           knownDuration: duration, waveform: waveform)
        case .location(let latitude, let longitude):
            LocationDraftPage(latitude: latitude, longitude: longitude)
        case .contact(let name, let phone):
            ContactDraftPage(name: name, phone: phone)
        }
    }
}

/// Inline playable video preview (native controls, starts paused).
private struct VideoDraftPage: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                Color.black
            }
        }
        .onAppear { if player == nil { player = AVPlayer(url: url) } }
        .onDisappear { player?.pause() }
    }
}

/// Document preview: PDFs render their first page, audio gets a play row,
/// everything else shows a big icon + name + size.
private struct FileDraftPage: View {
    let url: URL
    let displayName: String
    let draftID: UUID
    @State private var pdfImage: UIImage?

    private var utType: UTType? { UTType(filenameExtension: url.pathExtension) }

    var body: some View {
        if utType?.conforms(to: .audio) == true {
            AudioDraftPage(url: url, draftID: draftID, knownDuration: nil, waveform: nil)
        } else if utType?.conforms(to: .pdf) == true {
            Group {
                if let pdfImage {
                    Image(uiImage: pdfImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(20)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .task { pdfImage = await PreviewRender.pdfFirstPage(url: url) }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.85))
                Text(displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let bytes = fileBytes(at: url) {
                    Text(MediaStore.sizeLabel(bytes))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(30)
        }
    }

    private func fileBytes(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }
}

/// Audio preview: play/pause + waveform (flat placeholder for imported files) + duration.
private struct AudioDraftPage: View {
    let url: URL
    let draftID: UUID
    let knownDuration: TimeInterval?
    let waveform: [Float]?
    @ObservedObject private var player = AudioPlayerService.shared
    @State private var resolvedDuration: TimeInterval?

    private var isCurrent: Bool { player.playingID == draftID }
    private var duration: TimeInterval { knownDuration ?? resolvedDuration ?? 0 }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Button {
                    player.togglePlay(id: draftID, url: url)
                } label: {
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Palette.textOnAccent)
                        .frame(width: 48, height: 48)
                        .background(Palette.ink, in: Circle())
                }
                .accessibilityLabel(isCurrent && player.isPlaying ? "Pause" : "Play")

                VoiceWaveformBars(samples: waveform ?? [],
                                  progress: isCurrent ? player.progress : 0,
                                  playedTint: .white,
                                  restTint: .white.opacity(0.35),
                                  maxHeight: 30)

                Text(mmss(duration))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(22)
            .background(Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(26)
        .task {
            if knownDuration == nil {
                resolvedDuration = await PreviewRender.mediaDuration(url: url)
            }
        }
    }
}

private struct LocationDraftPage: View {
    let latitude: Double
    let longitude: Double

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))) {
            Marker("Current location", coordinate: coordinate)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(16)
    }
}

private struct ContactDraftPage: View {
    let name: String
    let phone: String

    var body: some View {
        VStack(spacing: 14) {
            AvatarView(name: name, size: 72)
            Text(name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(phone)
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 30)
        .background(Color.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(26)
    }
}

// MARK: - Sender

/// Persists drafts via MediaStore and sends them into a chat (caption on the last item).
@MainActor enum AttachmentSender {
    static func send(_ drafts: [AttachmentDraft], caption: String, to chatID: UUID, store: DataStore) {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        // One sequential task so multi-draft sends land in pick order even when a
        // video needs an async duration probe first.
        Task { @MainActor in
            for (index, draft) in drafts.enumerated() {
                let itemCaption = index == drafts.count - 1 ? trimmed : ""
                await sendOne(draft, caption: itemCaption, to: chatID, store: store)
            }
            Haptics.impact(.light)
        }
    }

    /// Delete a staged copy once it has been re-imported into MediaStore — but only if
    /// it lives in the temp dir, so a security-scoped original is never touched.
    private static func removeTempCopy(_ url: URL) {
        guard url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func sendOne(_ draft: AttachmentDraft, caption: String,
                                to chatID: UUID, store: DataStore) async {
        // BACKEND INTEGRATION: when AppConfig.usesFirebase, upload the persisted bytes
        // via FirebaseStorageService and attach the remote URL before sending.
        switch draft.content {
        case .image(let image):
            guard let saved = MediaStore.saveImage(image) else {
                ToastCenter.shared.show("Couldn't save that photo", pending: false)
                return
            }
            store.sendAttachment(kind: .image,
                                 attachment: Attachment(localName: saved.name, byteSize: saved.bytes),
                                 caption: caption, to: chatID)

        case .video(let url):
            guard let saved = MediaStore.importMovie(from: url) else {
                ToastCenter.shared.show("Couldn't save that video", pending: false)
                return
            }
            removeTempCopy(url)
            let duration = await PreviewRender.mediaDuration(url: MediaStore.url(for: saved.name))
            store.sendAttachment(kind: .video,
                                 attachment: Attachment(localName: saved.name,
                                                        durationSeconds: duration,
                                                        byteSize: saved.bytes),
                                 caption: caption, to: chatID)

        case .file(let url, let displayName):
            let isAudio = UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
            guard let saved = MediaStore.importFile(from: url) else {
                ToastCenter.shared.show("Couldn't import that file", pending: false)
                return
            }
            removeTempCopy(url)
            if isAudio {
                let duration = await PreviewRender.mediaDuration(url: MediaStore.url(for: saved.name))
                store.sendAttachment(kind: .voiceNote,
                                     attachment: Attachment(localName: saved.name,
                                                            durationSeconds: duration,
                                                            fileName: displayName,
                                                            byteSize: saved.bytes),
                                     caption: caption, to: chatID)
            } else {
                store.sendAttachment(kind: .document,
                                     attachment: Attachment(localName: saved.name,
                                                            fileName: displayName,
                                                            byteSize: saved.bytes),
                                     caption: caption, to: chatID)
            }

        case .audioRecording(let localName, let duration, let waveform):
            let bytes = (try? MediaStore.url(for: localName)
                .resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            store.sendAttachment(kind: .voiceNote,
                                 attachment: Attachment(localName: localName,
                                                        durationSeconds: duration,
                                                        waveform: waveform,
                                                        byteSize: bytes),
                                 caption: caption, to: chatID)

        case .location(let latitude, let longitude):
            store.sendAttachment(kind: .location,
                                 attachment: Attachment(latitude: latitude, longitude: longitude),
                                 caption: caption, to: chatID)

        case .contact(let name, let phone):
            store.sendAttachment(kind: .contactCard,
                                 attachment: Attachment(contactName: name, contactPhone: phone),
                                 caption: caption, to: chatID)
        }
    }
}

// MARK: - Off-main rendering helpers

/// Async media probes used by the preview pages and the sender. Nonisolated so the
/// PDF/AVFoundation work stays off the main actor.
private enum PreviewRender {
    static func pdfFirstPage(url: URL) async -> UIImage? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        return page.thumbnail(of: CGSize(width: 900, height: 1273), for: .mediaBox)
    }

    static func mediaDuration(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds > 0.1 ? seconds : nil
    }
}

private func mmss(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}
