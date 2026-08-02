//
//  KeypadView.swift
//  Inditalk
//
//  The Calls tab dial pad: type a number, see it formatted large, and place a
//  simulated call. Known numbers resolve to the matching contact (name/avatar/chat);
//  unknown numbers call as-dialed and offer "Add to contacts". Also defines
//  DialPadGrid, the telephone key grid reused by the in-call DTMF overlay.
//

import SwiftUI

struct KeypadView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""            // raw keys typed: digits, +, *, #

    private var matchedUser: InditalkUser? { store.user(withPhone: number) }
    private var display: String { Self.format(number) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 8)
            numberDisplay
            matchRow
            Spacer(minLength: 16)
            DialPadGrid(zeroPlusOnHold: true) { key in
                number.append(key)
                Haptics.selection()
            }
            Spacer(minLength: 16)
            actionRow
                .padding(.bottom, 24)
        }
        .padding(.horizontal, Metrics.screenPadding)
        .background(Palette.background)
    }

    private var header: some View {
        HStack {
            Text("Keypad").font(.inditalkSectionTitle()).foregroundStyle(Palette.textPrimary)
            Spacer()
            CircleButton(symbol: "xmark", tint: Palette.pine) { dismiss() }
                .accessibilityLabel("Close keypad")
        }
        .padding(.top, 18)
    }

    private var numberDisplay: some View {
        Text(number.isEmpty ? "Enter number" : display)
            .font(number.isEmpty ? .system(size: 22, weight: .regular)
                                 : .system(size: 36, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(number.isEmpty ? Palette.textSecondary : Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .contentTransition(.numericText())
            .animation(.snappy, value: number)
            .accessibilityLabel(number.isEmpty ? "No number entered" : "Number \(display)")
    }

    /// Under the number: the matched contact, or an "Add to contacts" affordance.
    @ViewBuilder
    private var matchRow: some View {
        if let user = matchedUser {
            HStack(spacing: 8) {
                AvatarView(name: user.displayName, imageName: user.avatarAsset,
                           localName: user.avatarLocalName, size: 26)
                Text(user.displayName)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.pine)
            }
            .frame(height: 34)
            .accessibilityLabel("Matches contact \(user.displayName)")
        } else if number.filter(\.isNumber).count >= 3 {
            Button { addToContacts() } label: {
                Label("Add to contacts", systemImage: "person.badge.plus")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.pine)
            }
            .frame(height: 34)
        } else {
            Color.clear.frame(height: 34)
        }
    }

    private var actionRow: some View {
        HStack {
            // Invisible twin of the backspace button keeps the call button centered.
            backspaceButton.hidden()
            Spacer()
            Button { startCall() } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 26)).foregroundStyle(Palette.textOnAccent)
                    .frame(width: 72, height: 72)
                    .background(Palette.pine, in: Circle())
            }
            .disabled(number.isEmpty)
            .opacity(number.isEmpty ? 0.5 : 1)
            .accessibilityLabel("Call")
            Spacer()
            backspaceButton
                .opacity(number.isEmpty ? 0 : 1)
                .disabled(number.isEmpty)
        }
    }

    private var backspaceButton: some View {
        Button {
            guard !number.isEmpty else { return }
            number.removeLast()
            Haptics.selection()
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 22)).foregroundStyle(Palette.textSecondary)
                .frame(width: 52, height: 52)
        }
        .accessibilityLabel("Delete digit")
    }

    // MARK: Actions

    private func startCall() {
        guard !number.isEmpty else { return }
        // Only a number that maps to an Inditalk contact can be called for real — there is
        // no PSTN leg, so an unmatched number gets an honest explanation, never a
        // simulated call screen the other side can't hear.
        if let user = matchedUser {
            CallLauncher.call(user: user, video: false, store: store)
        } else {
            ToastCenter.shared.show("\(display) isn't on Inditalk — Inditalk can only call Inditalk contacts.",
                                    pending: false)
        }
    }

    private func addToContacts() {
        store.addContact(name: display, phone: number)
        Haptics.impact(.light)
        ToastCenter.shared.show("Saved \(display) to contacts", pending: false)
    }

    /// Light US-style grouping for plain digit strings; anything with +, * or #
    /// is shown as typed.
    static func format(_ raw: String) -> String {
        guard !raw.isEmpty, raw.allSatisfy(\.isNumber) else { return raw }
        let digits = Array(raw)
        switch digits.count {
        case 0...3:
            return raw
        case 4...7:
            return "\(String(digits[0..<3]))-\(String(digits[3...]))"
        case 8...10:
            return "(\(String(digits[0..<3]))) \(String(digits[3..<6]))-\(String(digits[6...]))"
        default:
            return raw
        }
    }
}

// MARK: - Dial pad grid

/// 3×4 telephone key grid (1–9, *, 0/+, #) shared by the Keypad sheet and the
/// in-call DTMF overlay. Long-pressing 0 yields "+" when `zeroPlusOnHold` is on.
struct DialPadGrid: View {
    enum Style { case sheet, inCall }

    var style: Style = .sheet
    var zeroPlusOnHold = false
    var keySize: CGFloat = 72
    let onKey: (String) -> Void

    private static let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"],
                                           ["7", "8", "9"], ["*", "0", "#"]]
    private static let subLabels: [String: String] = [
        "2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO",
        "7": "PQRS", "8": "TUV", "9": "WXYZ", "0": "+"
    ]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { key in keyView(key) }
                }
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: String) -> some View {
        let base = VStack(spacing: 1) {
            Text(key)
                .font(.system(size: key == "*" ? 34 : 28, weight: .medium))
                .foregroundStyle(primaryColor)
            if let sub = Self.subLabels[key] {
                Text(sub)
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(secondaryColor)
            }
        }
        .frame(width: keySize, height: keySize)
        .background(fillColor, in: Circle())
        .overlay(Circle().strokeBorder(strokeColor, lineWidth: style == .sheet ? 1 : 0))
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName(for: key))
        .accessibilityAddTraits(.isButton)

        if key == "0" && zeroPlusOnHold {
            base
                .onTapGesture { onKey("0") }
                .onLongPressGesture(minimumDuration: 0.35) { onKey("+") }
        } else {
            base.onTapGesture { onKey(key) }
        }
    }

    private func accessibilityName(for key: String) -> String {
        switch key {
        case "*": return "Star"
        case "#": return "Pound"
        case "0": return zeroPlusOnHold ? "Zero. Hold for plus" : "Zero"
        default:  return key
        }
    }

    private var primaryColor: Color { style == .sheet ? Palette.textPrimary : .white }
    private var secondaryColor: Color { style == .sheet ? Palette.textSecondary : .white.opacity(0.7) }
    private var fillColor: Color { style == .sheet ? Palette.surface : .white.opacity(0.16) }
    private var strokeColor: Color { style == .sheet ? Palette.separator : .clear }
}

#Preview {
    KeypadView().environmentObject(DataStore.inMemory())
}
