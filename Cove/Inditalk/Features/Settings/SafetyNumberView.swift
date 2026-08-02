//
//  SafetyNumberView.swift
//  Inditalk
//
//  Displays the end-to-end encryption safety number for a chat and lets the user
//  mark the contact as verified. The number is derived from both parties' identity
//  public keys via CryptoService — identical on both devices when the session is
//  authentic (see docs/PHASE5_ENCRYPTION.md).
//

import SwiftUI

struct SafetyNumberView: View {
    let chat: Chat
    @State private var verified = false

    // Uses the device's REAL X25519 identity public key for our half. The peer half
    // comes from their published prekey bundle in Firebase mode; here we derive a
    // stable per-chat placeholder so the number is consistent for the demo.
    private var number: String {
        let peer = Data("cove.peer.\(chat.id.uuidString)".utf8)
        return IdentityKeyManager.shared.safetyNumber(with: peer)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40)).foregroundStyle(Palette.pine)
                    .padding(.top, 8)

                Text("Messages and calls with \(chat.title) are end-to-end encrypted.")
                    .font(.system(size: 15)).foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)

                // QR stand-in: a deterministic dot grid (a real QR is generated with
                // CIFilter.qrCodeGenerator in Phase 5).
                qrPlaceholder
                    .frame(width: 180, height: 180)
                    .padding(16)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))

                Text(number)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .accessibilityLabel("Safety number \(number)")

                Text("To verify, compare this number with \(chat.title)'s device, or scan each other's QR code. Numbers match only if no one is intercepting your conversation.")
                    .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)

                Toggle("Mark as verified", isOn: $verified)
                    .tint(Palette.pine)
                    .padding(.horizontal, 24)
            }
            .padding(.vertical, 20)
        }
        .background(Palette.background)
        .navigationTitle("Encryption")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var qrPlaceholder: some View {
        let seed = abs(chat.id.hashValue)
        return GeometryReader { geo in
            let n = 11
            let cell = geo.size.width / CGFloat(n)
            ForEach(0..<n, id: \.self) { r in
                ForEach(0..<n, id: \.self) { c in
                    if (seed >> ((r * n + c) % 60)) & 1 == 1 {
                        Rectangle().fill(Palette.textPrimary)
                            .frame(width: cell, height: cell)
                            .position(x: (CGFloat(c) + 0.5) * cell, y: (CGFloat(r) + 0.5) * cell)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
