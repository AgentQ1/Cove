//
//  StatusRing.swift
//  Inditalk
//
//  Shared visuals for the Updates tab: the segmented ring drawn around avatars
//  (one arc per active status, viewed arcs dimmed), the curated background palette
//  for text status cards, and the compact "26m ago" status timestamp.
//

import SwiftUI

/// Segmented status ring: one arc per status update, 4pt gaps between arcs.
/// `segments[i] == true` means that update has been viewed (dimmed arc).
struct StatusRing: View {
    let segments: [Bool]
    var size: CGFloat = Metrics.avatar + 10
    var lineWidth: CGFloat = 2.5
    var gapLength: CGFloat = 4                       // arc length between segments, in points
    var unviewedColor: Color = Palette.pine
    var viewedColor: Color = Palette.separator

    var body: some View {
        ZStack {
            ForEach(segments.indices, id: \.self) { i in
                Circle()
                    .trim(from: fraction(of: i) + gapFraction / 2,
                          to: fraction(of: i + 1) - gapFraction / 2)
                    .stroke(segments[i] ? viewedColor : unviewedColor,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))   // start segments at 12 o'clock
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func fraction(of index: Int) -> CGFloat {
        CGFloat(index) / CGFloat(max(segments.count, 1))
    }

    /// The 4pt gap expressed as a fraction of the ring's circumference.
    /// A single-status ring draws as one unbroken circle.
    private var gapFraction: CGFloat {
        guard segments.count > 1 else { return 0 }
        return gapLength / (.pi * (size - lineWidth))
    }
}

/// Curated card backgrounds for text statuses, indexed by `StatusUpdate.paletteIndex`.
/// Fixed (non-adaptive) colors — white type sits on them in both appearances.
enum StatusPalette {
    static let colors: [Color] = [
        Color(hex: 0x26324F),   // ink slate
        Color(hex: 0x2F5D50),   // deep pine
        Color(hex: 0xB0842F),   // ochre
        Color(hex: 0x8A5A3B),   // warm sienna
        Color(hex: 0x5B4A78),   // dusk violet
        Color(hex: 0x3E6B7A)    // sea slate
    ]

    static func color(at index: Int) -> Color {
        colors[abs(index) % colors.count]
    }
}

/// Compact status-row timestamps. Statuses expire after 24h, so anything older
/// than a day only appears transiently before the projection filters it out.
enum StatusTime {
    static func label(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "Yesterday"
    }
}
