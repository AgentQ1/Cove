//
//  Palette.swift
//  Inditalk
//
//  Inditalk's ORIGINAL visual identity. This is a warm, parchment-toned messenger.
//
//  NOTE ON ORIGINALITY: This palette deliberately does NOT use WhatsApp's brand
//  green (#25D366 / #075E54), its logo, or its proprietary iconography. Inditalk uses
//  a warm parchment background, a deep slate-blue primary accent, a muted ochre
//  secondary, and a distinct deep-pine accent for the Calls section. The layout
//  language (circular avatars, bottom tabs, per-section accent tinting) is a common
//  product pattern; the exact colors here are Inditalk's own.
//

import SwiftUI

/// Semantic color tokens for Inditalk. Every color is theme-aware (light/dark) so the
/// UI reads correctly in both appearances.
enum Palette {

    // MARK: Surfaces
    /// Warm parchment app background.
    static let background = Color(light: 0xF6F1E8, dark: 0x141210)
    /// Slightly raised surface (search field, cards, quick-action tray).
    static let surface = Color(light: 0xFBF8F1, dark: 0x201D19)
    /// Incoming message bubble.
    static let bubbleIncoming = Color(light: 0xFFFFFF, dark: 0x262320)
    /// Outgoing message bubble (warm cream tint).
    static let bubbleOutgoing = Color(light: 0xEFE6D2, dark: 0x33422F)
    /// System / info bubble (encryption notice, disappearing-message notes).
    static let bubbleSystem = Color(light: 0xF3EEDF, dark: 0x211E1A)

    // MARK: Text
    static let textPrimary = Color(light: 0x1D2433, dark: 0xF2EEE6)
    static let textSecondary = Color(light: 0x6B6559, dark: 0xA8A092)
    static let textOnAccent = Color(light: 0xFFFFFF, dark: 0xFFFFFF)

    // MARK: Accents
    /// Primary brand accent — deep slate blue (used across Chats + app chrome).
    static let ink = Color(light: 0x26324F, dark: 0x8CA2CF)
    /// Warm secondary — muted ochre (call-type glyphs, timers, highlights).
    static let ochre = Color(light: 0xB0842F, dark: 0xD9B063)
    /// Calls-section accent — deep pine (intentionally NOT WhatsApp green).
    static let pine = Color(light: 0x2F5D50, dark: 0x7FB9A6)

    // MARK: Status
    static let danger = Color(light: 0xC0453B, dark: 0xE58379)   // missed calls, failed sends
    static let success = Color(light: 0x2F5D50, dark: 0x7FB9A6)
    static let separator = Color(light: 0xE7DFD0, dark: 0x2E2A24)

    /// Unread badge fill.
    static let badge = ink
}

// MARK: - Hex convenience

extension Color {
    /// Create a color from separate light/dark hex values so tokens adapt to appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        })
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}
