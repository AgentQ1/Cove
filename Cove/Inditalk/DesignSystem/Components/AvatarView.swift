//
//  AvatarView.swift
//  Inditalk
//
//  Circular avatar treatment used everywhere. Falls back to deterministic initials
//  on a tinted disc when there's no image (all data here is local mock data).
//

import SwiftUI

struct AvatarView: View {
    let name: String
    var imageName: String? = nil          // asset name for mock avatars
    var localName: String? = nil          // MediaStore photo (user-set avatar) — wins over imageName
    var remoteURL: String? = nil          // contact's uploaded photo (users/{uid}.avatarURL)
    var systemImage: String? = nil        // SF Symbol fallback (e.g. group icon)
    var size: CGFloat = Metrics.avatar
    var ring: Color? = nil                // optional presence/selection ring

    var body: some View {
        ZStack {
            if let localName, let photo = MediaStore.image(named: localName) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else if let remoteURL, let url = URL(string: remoteURL) {
                // Contacts' photos come from Storage; the initials disc shows while
                // loading and stays on failure, so the row never looks broken.
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack { fallbackDisc }
                    }
                }
            } else if let imageName, UIImage(named: imageName) != nil {
                Image(imageName)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackDisc
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(ring ?? Palette.separator.opacity(0.6),
                                  lineWidth: ring == nil ? 0.5 : 2)
        )
        .accessibilityHidden(true)
    }

    /// The tinted disc with initials / symbol — the no-photo (or still-loading) state.
    @ViewBuilder private var fallbackDisc: some View {
        Circle().fill(discColor)
        if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Palette.textOnAccent.opacity(0.95))
        } else {
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.textOnAccent)
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.joined().uppercased()
    }

    /// Deterministic warm disc color derived from the name so an avatar is stable.
    private var discColor: Color {
        let palette: [UInt32] = [0x26324F, 0x2F5D50, 0xB0842F, 0x8A5A3B, 0x5B4A78, 0x3E6B7A]
        let hash = abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return Color(hex: palette[hash % palette.count])
    }
}

/// Small presence dot overlaid on avatars (online state).
struct PresenceDot: View {
    var isOnline: Bool
    var body: some View {
        Circle()
            .fill(isOnline ? Palette.success : Color.clear)
            .frame(width: 13, height: 13)
            .overlay(Circle().strokeBorder(Palette.background, lineWidth: 2.5))
            .opacity(isOnline ? 1 : 0)
    }
}
