//
//  EmptyStateView.swift
//  Inditalk
//
//  Reusable empty/placeholder state used across lists (starred, blocked, updates,
//  communities). Accessible and theme-aware.
//

import SwiftUI

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Palette.textSecondary.opacity(0.6))
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.ink)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}

/// Small inline loading state.
struct LoadingStateView: View {
    var label: String = "Loading…"
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Palette.ink)
            Text(label).font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}
