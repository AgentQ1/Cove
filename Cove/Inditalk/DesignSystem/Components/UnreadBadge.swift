//
//  UnreadBadge.swift
//  Inditalk
//

import SwiftUI

/// Circular unread-count badge (used on chat rows and the Chats tab).
struct UnreadBadge: View {
    let count: Int
    var tint: Color = Palette.badge

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.inditalkBadge())
                .foregroundStyle(Palette.textOnAccent)
                .padding(.horizontal, count > 9 ? 6 : 0)
                .frame(minWidth: 20, minHeight: 20)
                .background(tint, in: Capsule())
                .accessibilityLabel("\(count) unread")
        }
    }
}

/// A pill chip used in system rows ("Alexandra is a contact.", date separators).
struct Pill<Content: View>: View {
    var background: Color = Palette.bubbleSystem
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background, in: Capsule())
    }
}
