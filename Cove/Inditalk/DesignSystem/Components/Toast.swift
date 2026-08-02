//
//  Toast.swift
//  Inditalk
//
//  A single lightweight, app-wide toast. Used as the honest "tracked as intentionally
//  pending" affordance: any control whose full behavior belongs to a later phase
//  (real remote calls, keypad dialer, communities backend, …) surfaces a brief
//  message here instead of being a silent no-op. Real, wired actions never use it.
//
//  Hosted once, at the app root (see InditalkApp), so any screen can call
//  `ToastCenter.shared.show(...)` without threading state through the view tree.
//

import SwiftUI

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var message: String?
    @Published private(set) var symbol: String = "clock.badge.checkmark"

    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Show a transient message. `pending: true` frames it as a not-yet-built feature.
    func show(_ message: String, symbol: String? = nil, pending: Bool = true) {
        self.symbol = symbol ?? (pending ? "hammer.fill" : "checkmark.circle.fill")
        withAnimation(.snappy) { self.message = message }
        Haptics.selection()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.message = nil }
        }
    }
}

/// Overlay host. Attach once near the app root.
struct ToastHost: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = center.message {
                HStack(spacing: 10) {
                    Image(systemName: center.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ochre)
                    Text(message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                .padding(.bottom, 120)
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(message)
            }
        }
    }
}

extension View {
    /// Hosts the app-wide toast. Applied once at the root.
    func inditalkToastHost() -> some View { modifier(ToastHost()) }
}
