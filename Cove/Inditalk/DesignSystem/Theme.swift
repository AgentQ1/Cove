//
//  Theme.swift
//  Inditalk
//
//  Typography, spacing, and the per-section accent concept. The attached product
//  references tint each tab a different color (the messaging section one way, the
//  calls section another); Inditalk reproduces that *behavior* with its own palette:
//  Chats/app chrome use `ink` (slate blue), Calls use `pine` (deep green).
//

import SwiftUI

// MARK: - Typography

extension Font {
    /// Large serif screen titles ("Chats", "Calls") — mirrors the reference's
    /// distinctive serif display type using Apple's New York face.
    static func inditalkTitle() -> Font { .system(size: 34, weight: .bold, design: .serif) }
    static func inditalkSectionTitle() -> Font { .system(size: 22, weight: .bold, design: .serif) }
    static func inditalkRowName() -> Font { .system(size: 18, weight: .semibold) }
    static func inditalkRowSubtitle() -> Font { .system(size: 15, weight: .regular) }
    static func inditalkCaption() -> Font { .system(size: 13, weight: .regular) }
    static func inditalkBadge() -> Font { .system(size: 12, weight: .bold) }
}

// MARK: - Metrics

enum Metrics {
    static let screenPadding: CGFloat = 16
    static let rowVerticalPadding: CGFloat = 12
    static let avatar: CGFloat = 52
    static let avatarSmall: CGFloat = 40
    static let avatarLarge: CGFloat = 96
    static let bubbleCorner: CGFloat = 18
    static let searchCorner: CGFloat = 22
    static let tapTarget: CGFloat = 44
}

// MARK: - App sections & their accent

/// The five primary destinations, matching the reference's bottom tab bar.
enum AppTab: Int, CaseIterable, Identifiable {
    case updates, calls, communities, chats, you
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .updates: return "Updates"
        case .calls: return "Calls"
        case .communities: return "Communities"
        case .chats: return "Chats"
        case .you: return "You"
        }
    }

    /// SF Symbols — Apple's system glyphs, not third-party proprietary icons.
    var symbol: String {
        switch self {
        case .updates: return "circle.dashed"
        case .calls: return "phone"
        case .communities: return "person.3"
        case .chats: return "bubble.left.and.bubble.right"
        case .you: return "person.crop.circle"
        }
    }

    var symbolFilled: String {
        switch self {
        case .updates: return "circle.dashed.inset.filled"
        case .calls: return "phone.fill"
        case .communities: return "person.3.fill"
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .you: return "person.crop.circle.fill"
        }
    }

    /// Per-section accent, reproducing the reference's per-tab tinting behavior.
    var accent: Color {
        switch self {
        case .calls: return Palette.pine
        default: return Palette.ink
        }
    }
}

// MARK: - Reusable circular chrome button (top-bar menu / camera / plus)

struct CircleButton: View {
    let symbol: String
    var filled: Bool = false
    var tint: Color = Palette.ink
    var background: Color = Palette.surface
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(filled ? Palette.textOnAccent : tint)
                .frame(width: 42, height: 42)
                .background(filled ? tint : background, in: Circle())
                .overlay(
                    Circle().strokeBorder(Palette.separator, lineWidth: filled ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}
