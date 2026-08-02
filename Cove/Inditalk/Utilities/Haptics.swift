//
//  Haptics.swift
//  Inditalk
//

import UIKit

/// Thin wrapper over UIKit feedback generators. Respects the system Reduce Motion
/// setting is not required for haptics, but we keep this centralized so it can be
/// gated by a future "in-app haptics" preference.
@MainActor
enum Haptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
