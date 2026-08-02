//
//  CallsViewModel.swift
//  Inditalk
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class CallsViewModel: ObservableObject {
    @Published var searchText: String = ""

    struct Row: Identifiable {
        let record: CallRecord
        let stamp: String
        var id: UUID { record.id }
        var titleColor: Bool { record.direction == .missed }   // missed rows use danger color
    }

    func rows(_ calls: [CallRecord], now: Date = Date()) -> [Row] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? calls : calls.filter { $0.displayName.lowercased().contains(q) }
        return filtered
            .sorted { $0.date > $1.date }
            .map { Row(record: $0, stamp: RelativeDate.listStamp($0.date, now: now)) }
    }

    /// Directional glyph + tint for a call record.
    static func directionGlyph(_ r: CallRecord) -> (symbol: String, tint: Color) {
        switch r.direction {
        case .outgoing: return ("arrow.up.right", Palette.pine)
        case .incoming: return ("arrow.down.left", Palette.pine)
        case .missed:   return (r.media == .video ? "video.slash.fill" : "arrow.down.left", Palette.danger)
        }
    }

    /// Future-facing stamp for scheduled calls: "Today at 3:00 PM", "Tomorrow at…",
    /// then "Wed, Jul 29 at 3:00 PM".
    static func upcomingStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let time = upcomingTime.string(from: date)
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow at \(time)" }
        return "\(upcomingDay.string(from: date)) at \(time)"
    }

    private static let upcomingTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let upcomingDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
}
