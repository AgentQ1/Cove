//
//  ChatRowView.swift
//  Inditalk
//

import SwiftUI

struct ChatRowView: View {
    let row: ChatListViewModel.Row

    private var chat: Chat { row.chat }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: chat.title, imageName: chat.avatarAsset,
                           remoteURL: row.avatarURL,
                           systemImage: chat.kind == .group ? "person.2.fill" : nil,
                           size: Metrics.avatar)
                if chat.disappearingSeconds > 0 {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.textOnAccent)
                        .padding(3)
                        .background(Palette.ochre, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.background, lineWidth: 2))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(chat.title)
                        .font(.inditalkRowName())
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if chat.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                    }
                    if chat.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }

                HStack(spacing: 4) {
                    if let glyph = row.previewGlyph {
                        Image(systemName: glyph.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint(for: glyph.style))
                    }
                    Text(row.preview)
                        .font(.inditalkRowSubtitle())
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text(row.stamp)
                    .font(.inditalkCaption())
                    .foregroundStyle(chat.unreadCount > 0 ? Palette.ink : Palette.textSecondary)
                HStack(spacing: 6) {
                    if chat.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textSecondary)
                            .rotationEffect(.degrees(45))
                    }
                    UnreadBadge(count: chat.unreadCount)
                }
            }
        }
        .padding(.vertical, Metrics.rowVerticalPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chat.title), \(row.preview), \(row.stamp)"
                            + (chat.unreadCount > 0 ? ", \(chat.unreadCount) unread" : ""))
    }

    private var isMissed: Bool { row.previewGlyph?.style == .missedCall }

    /// An attachment icon sits WITH the preview text (same weight as the words it is
    /// standing in for); call-log icons stay accented.
    private func tint(for style: PreviewGlyph.Style) -> Color {
        switch style {
        case .attachment: return Palette.textSecondary
        case .call:       return Palette.ochre
        case .missedCall: return Palette.danger
        }
    }
}
