//
//  MessageBubbleView.swift
//  Inditalk
//
//  Renders one message: incoming (white, left) vs outgoing (cream, right), with
//  time + delivery receipt, reactions, reply quote, edited/deleted states. Every
//  attachment kind renders and opens: images (full-screen viewer + share), video
//  (thumbnail -> player), documents (QuickLook), voice notes (inline playback),
//  locations (map -> Apple Maps), and contact cards (save to contacts).
//

import SwiftUI
import UIKit
import MapKit
import CoreLocation

struct MessageBubbleView: View {
    let message: Message
    let replyPreview: Message?
    var senderName: String? = nil          // group chats show sender name

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 44) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                bubble
                if !message.reactions.isEmpty { reactionsRow }
            }

            if !message.isOutgoing { Spacer(minLength: 44) }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.vertical, 2)
    }

    /// The bubble hugs its content, so its width is the widest child. The timestamp row
    /// should therefore sit at the trailing edge of the *content*, which trailing
    /// alignment gives us for free — no infinite frame (which would stretch every bubble
    /// to the full row width, leaving a short message like "Hi" with a huge gap).
    ///
    /// A sender name or reply quote reads as a header and must stay left-aligned, so
    /// those bubbles align leading instead; their content is virtually always wider than
    /// the timestamp, so the footer still lands where it should.
    private var contentAlignment: HorizontalAlignment {
        let hasLeadingHeader = (senderName != nil && !message.isOutgoing) || replyPreview != nil
        return hasLeadingHeader ? .leading : .trailing
    }

    private var bubble: some View {
        VStack(alignment: contentAlignment, spacing: 5) {
            if let senderName, !message.isOutgoing {
                Text(senderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }

            if let replyPreview {
                replyQuote(replyPreview)
            }

            if message.isDeleted {
                Label("This message was deleted", systemImage: "nosign")
                    .font(.system(size: 15).italic())
                    .foregroundStyle(Palette.textSecondary)
            } else {
                if let attachment = message.attachment {
                    attachmentView(attachment)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.textPrimary)
                        // Wrapped lines always read left-to-right, independent of how the
                        // bubble aligns its children.
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
            }

            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(message.isOutgoing ? Palette.bubbleOutgoing : Palette.bubbleIncoming,
                    in: BubbleShape(isOutgoing: message.isOutgoing))
        .overlay(
            BubbleShape(isOutgoing: message.isOutgoing)
                .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if message.isStarred {
                Image(systemName: "star.fill")
                    .font(.system(size: 10)).foregroundStyle(Palette.ochre)
            }
            if message.editedAt != nil {
                Text("edited").font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
            }
            Text(RelativeDate.messageTime(message.sentAt))
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
            if message.isOutgoing { ReceiptTicks(state: message.state) }
        }
    }

    /// Renders the attachment for every message kind; caption text (message.text)
    /// is drawn below by the bubble body.
    @ViewBuilder private func attachmentView(_ attachment: Attachment) -> some View {
        switch message.kind {
        case .image:
            ImageBubbleContent(messageID: message.id, attachment: attachment)
        case .video:
            VideoBubbleContent(messageID: message.id, attachment: attachment)
        case .document:
            DocumentBubbleContent(messageID: message.id, attachment: attachment)
        case .voiceNote:
            VoiceNoteBubbleContent(messageID: message.id, attachment: attachment)
        case .location:
            if let latitude = attachment.latitude, let longitude = attachment.longitude {
                LocationBubbleContent(latitude: latitude, longitude: longitude)
            } else {
                mediaFallback("location.fill", "Location")
            }
        case .contactCard:
            ContactCardBubbleContent(name: attachment.contactName ?? "Contact",
                                     phone: attachment.contactPhone ?? "")
        default:
            EmptyView()
        }
    }

    private func mediaFallback(_ symbol: String, _ label: String) -> some View {
        Label(label, systemImage: symbol)
            .font(.system(size: 15)).foregroundStyle(Palette.textSecondary)
    }

    private func replyQuote(_ replied: Message) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.ink).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(replied.isOutgoing ? "You" : "Reply")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                HStack(spacing: 4) {
                    if let symbol = Self.summarySymbol(for: replied) {
                        Image(systemName: symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Text(Self.summaryText(for: replied))
                        .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(6)
        .background(Palette.bubbleSystem, in: RoundedRectangle(cornerRadius: 8))
    }

    private var reactionsRow: some View {
        HStack(spacing: 2) {
            ForEach(message.reactions) { r in Text(r.emoji).font(.system(size: 14)) }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: 0.5))
    }

    private var accessibilityText: String {
        let who = message.isOutgoing ? "You said" : (senderName ?? "They said")
        var body = message.text
        if body.isEmpty { body = Self.summaryText(for: message) }
        return "\(who): \(body). \(RelativeDate.messageTime(message.sentAt))"
    }

    // MARK: Shared kind summaries (reply quotes, forward preview, composer banner)

    /// Compact one-line description of a message for quotes and pickers.
    static func summaryText(for message: Message) -> String {
        if !message.text.isEmpty { return message.text }
        switch message.kind {
        case .image: return "Photo"
        case .video: return "Video"
        case .voiceNote:
            if let duration = message.attachment?.durationSeconds {
                return "Voice message (\(mmss(duration)))"
            }
            return "Voice message"
        case .document: return message.attachment?.fileName ?? "Document"
        case .location: return "Location"
        case .contactCard: return message.attachment?.contactName ?? "Contact"
        default: return "Message"
        }
    }

    /// SF Symbol shown next to the summary; nil for plain text messages.
    static func summarySymbol(for message: Message) -> String? {
        guard message.text.isEmpty else { return nil }
        switch message.kind {
        case .image: return "photo"
        case .video: return "video.fill"
        case .voiceNote: return "mic.fill"
        case .document: return "doc.fill"
        case .location: return "location.fill"
        case .contactCard: return "person.crop.circle"
        default: return nil
        }
    }
}

// MARK: - Per-kind bubble contents

/// Shared placeholder tile for media whose bytes aren't on this device yet:
/// spinner while the download runs, tap-to-retry after a failure.
struct MediaDownloadPlaceholder: View {
    let messageID: UUID
    let symbol: String            // kind glyph shown behind the state ("photo", "film")
    @EnvironmentObject private var store: DataStore

    var body: some View {
        ZStack {
            Rectangle().fill(Palette.bubbleSystem)
            switch store.mediaPhases[messageID] {
            case .downloading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Downloading…")
                        .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                }
            case .failed:
                Button { store.retryMediaDownload(messageID) } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 30)).foregroundStyle(Palette.ink)
                        Text("Tap to retry")
                            .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download failed, double tap to retry")
            case nil:
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.textSecondary.opacity(0.5))
            }
        }
        .frame(width: 240, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Photo: renders a downsampled thumbnail (decoded once, off-main) and opens the
/// full-screen zoom/share viewer on tap. While the blob is still syncing it shows
/// the shared download placeholder instead of an empty bubble.
private struct ImageBubbleContent: View {
    let messageID: UUID
    let attachment: Attachment
    @State private var showViewer = false
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Button { showViewer = true } label: {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 240, maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Photo, double tap to view full screen")
                .fullScreenCover(isPresented: $showViewer) {
                    // Full resolution only for the one-shot viewer, never the bubble.
                    if let name = attachment.localName, let full = MediaStore.image(named: name) {
                        ImageViewerScreen(image: full)
                    } else {
                        ImageViewerScreen(image: thumbnail)
                    }
                }
            } else {
                MediaDownloadPlaceholder(messageID: messageID, symbol: "photo")
            }
        }
        .task(id: attachment.localName) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        if let name = attachment.localName, MediaStore.exists(name) {
            thumbnail = await MediaStore.downsampledImage(named: name, maxPixels: 800)
        } else if let asset = attachment.assetName {
            thumbnail = UIImage(named: asset)
        }
    }
}

/// Video: async thumbnail with play overlay + duration badge; tap opens the
/// full-screen AVKit player. Shows the shared download placeholder until the
/// blob is on disk.
private struct VideoBubbleContent: View {
    let messageID: UUID
    let attachment: Attachment
    @State private var thumbnail: UIImage?
    @State private var showPlayer = false

    private var fileURL: URL? {
        guard let name = attachment.localName, MediaStore.exists(name) else { return nil }
        return MediaStore.url(for: name)
    }

    var body: some View {
        Group {
            if fileURL != nil {
                Button { showPlayer = true } label: {
                    ZStack {
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Rectangle().fill(Palette.bubbleSystem)
                        }

                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .frame(width: 240, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if let duration = attachment.durationSeconds {
                            Text(mmss(duration))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(6)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Video, double tap to play")
            } else {
                MediaDownloadPlaceholder(messageID: messageID, symbol: "film")
            }
        }
        .task(id: attachment.localName) { await loadThumbnail() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let fileURL {
                VideoPlayerScreen(url: fileURL)
            }
        }
    }

    private func loadThumbnail() async {
        guard thumbnail == nil, let fileURL else { return }
        thumbnail = await VideoTools.thumbnail(for: fileURL)
    }
}

/// Document chip: filename + size + kind icon. Tap opens QuickLook when the file is
/// on disk; while it syncs, the trailing accessory shows a spinner (downloading) or
/// a retry arrow (failed), so a receiver is never stuck with a dead chip.
private struct DocumentBubbleContent: View {
    let messageID: UUID
    let attachment: Attachment
    @State private var showPreview = false
    @EnvironmentObject private var store: DataStore

    private var fileURL: URL? {
        guard let name = attachment.localName, MediaStore.exists(name) else { return nil }
        return MediaStore.url(for: name)
    }

    var body: some View {
        Button { tap() } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill").font(.system(size: 22)).foregroundStyle(Palette.ochre)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName ?? "Document")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if let bytes = attachment.byteSize {
                        Text(MediaStore.sizeLabel(bytes))
                            .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer(minLength: 4)
                accessory
            }
            .padding(8)
            .frame(maxWidth: 240, alignment: .leading)
            .background(Palette.bubbleSystem, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Document \(attachment.fileName ?? ""), double tap to preview")
        .sheet(isPresented: $showPreview) {
            if let fileURL {
                QuickLookPreview(url: fileURL)
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private var accessory: some View {
        if fileURL != nil {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
        } else {
            switch store.mediaPhases[messageID] {
            case .downloading:
                ProgressView().controlSize(.small)
            case .failed, nil:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.ink)
            }
        }
    }

    private func tap() {
        if fileURL != nil {
            showPreview = true
        } else if case .failed = store.mediaPhases[messageID] {
            store.retryMediaDownload(messageID)
        }
    }
}

/// Voice note: play/pause + waveform with progress fill + duration, driven by the
/// shared AudioPlayerService keyed on the message ID.
private struct VoiceNoteBubbleContent: View {
    let messageID: UUID
    let attachment: Attachment
    @ObservedObject private var player = AudioPlayerService.shared

    private var isCurrent: Bool { player.playingID == messageID }
    private var fileURL: URL? {
        guard let name = attachment.localName, MediaStore.exists(name) else { return nil }
        return MediaStore.url(for: name)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                guard let fileURL else { return }
                player.togglePlay(id: messageID, url: fileURL)
            } label: {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(width: 36, height: 36)
                    .background(fileURL == nil ? Palette.textSecondary : Palette.ink, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(fileURL == nil)
            .accessibilityLabel(isCurrent && player.isPlaying
                                ? "Pause voice message" : "Play voice message")

            VoiceWaveformBars(samples: attachment.waveform ?? [],
                              progress: isCurrent ? player.progress : 0)

            Text(timeLabel)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private var timeLabel: String {
        let duration = attachment.durationSeconds ?? 0
        if isCurrent && player.progress > 0 {
            return mmss(player.progress * duration)
        }
        return mmss(duration)
    }
}

/// Location: static mini-map with a marker; tap opens Apple Maps at the pin.
private struct LocationBubbleContent: View {
    let latitude: Double
    let longitude: Double
    @Environment(\.openURL) private var openURL

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var body: some View {
        Button { openInMaps() } label: {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))),
                interactionModes: []) {
                Marker("Shared location", coordinate: coordinate)
            }
            .frame(width: 230, height: 140)
            .allowsHitTesting(false)
            .overlay(alignment: .bottomLeading) {
                Label("Open in Maps", systemImage: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shared location, double tap to open in Maps")
    }

    private func openInMaps() {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: "Shared Location"),
        ]
        if let url = components?.url { openURL(url) }
    }
}

/// Contact card: avatar initials + name + phone with a real "Save contact" action.
private struct ContactCardBubbleContent: View {
    let name: String
    let phone: String
    @EnvironmentObject private var store: DataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AvatarView(name: name, size: Metrics.avatarSmall)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(phone)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }

            Divider()

            Button {
                store.addContact(name: name, phone: phone)
                Haptics.impact(.light)
                ToastCenter.shared.show("Saved \(name) to contacts",
                                        symbol: "person.crop.circle.badge.checkmark",
                                        pending: false)
            } label: {
                Text("Save contact")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 230, alignment: .leading)
        .background(Palette.bubbleSystem, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Contact card for \(name), \(phone)")
    }
}

/// Delivery receipt ticks: single (sent), double (delivered), accent double (read).
struct ReceiptTicks: View {
    let state: MessageState
    var body: some View {
        switch state {
        case .sending:
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
        case .sent:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
        case .delivered:
            doubleCheck(Palette.textSecondary)
        case .read:
            doubleCheck(Palette.ink)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11))
                .foregroundStyle(Palette.danger)
        }
    }
    private func doubleCheck(_ color: Color) -> some View {
        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .overlay(Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color).offset(x: 4))
            .padding(.trailing, 4)
            .accessibilityLabel(color == Palette.ink ? "Read" : "Delivered")
    }
}

/// Asymmetric rounded bubble with a subtle tail side.
struct BubbleShape: InsettableShape {
    let isOutgoing: Bool
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = Metrics.bubbleCorner
        let corners: UIRectCorner = isOutgoing
            ? [.topLeft, .topRight, .bottomLeft]
            : [.topLeft, .topRight, .bottomRight]
        return Path(UIBezierPath(roundedRect: r, byRoundingCorners: corners,
                                 cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self; copy.inset += amount; return copy
    }
}

fileprivate func mmss(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}
