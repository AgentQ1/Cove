//
//  RelativeDate.swift
//  Inditalk
//
//  Formatting helpers for chat-list timestamps, call rows, "last seen", and
//  message time stamps. Matches the reference's mixed style: time for today,
//  "Yesterday", weekday name within a week, then M/D/YY.
//

import Foundation

enum RelativeDate {

    /// Chat-list / call-list style: "9:22 PM", "Yesterday", "Saturday", "7/11/26".
    static func listStamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return timeOnly.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day,
           days < 7 {
            return weekday.string(from: date)
        }
        return shortDate.string(from: date)
    }

    /// Message bubble time: "8:43 PM".
    static func messageTime(_ date: Date) -> String { timeOnly.string(from: date) }

    /// Date separator inside a chat: "Thu, Apr 2".
    static func daySeparator(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return separator.string(from: date)
    }

    /// Presence line: "online" / "last seen today at 9:22 PM".
    static func presenceLine(_ presence: Presence, calendar: Calendar = .current) -> String? {
        switch presence {
        case .online:
            return "online"
        case .hidden:
            return nil
        case .lastSeen(let date):
            let day: String
            if calendar.isDateInToday(date) { day = "today" }
            else if calendar.isDateInYesterday(date) { day = "yesterday" }
            else { day = weekday.string(from: date) }
            return "last seen \(day) at \(timeOnly.string(from: date))"
        }
    }

    /// Call duration "4:07" or "1:02:30".
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    // MARK: Formatters (cached)
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()
    private static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M/d/yy"; return f
    }()
    private static let separator: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
}
