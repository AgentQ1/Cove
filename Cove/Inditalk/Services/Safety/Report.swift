//
//  Report.swift
//  Inditalk
//
//  The user-generated-content (UGC) report model. Submitting a report used to be a
//  toast-only no-op; this is the real value type that a report becomes. It is persisted
//  to a local outbox (ReportStore) and, when Firebase is configured, delivered to the
//  `reports` collection for moderation (ReportService).
//

import Foundation

/// Why a user is being reported. Kept deliberately small and App-Review-legible.
enum ReportReason: String, Codable, CaseIterable, Identifiable {
    case spam
    case harassment
    case inappropriateContent
    case impersonation
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spam:                 return "Spam or scam"
        case .harassment:           return "Harassment or bullying"
        case .inappropriateContent: return "Inappropriate content"
        case .impersonation:        return "Impersonation"
        case .other:                return "Something else"
        }
    }
}

/// A single abuse report. `reportedUserID`/`chatID` are the app's local domain ids;
/// the backend maps them to server ids when the report is delivered.
struct Report: Codable, Identifiable, Equatable {
    let id: UUID
    let reporterID: UUID
    let reportedUserID: UUID
    let chatID: UUID?
    let reason: ReportReason
    let note: String
    let createdAt: Date
    /// True once the report has been accepted by the backend (Firestore). Local-only
    /// reports (no backend configured) stay `false` and remain queued in the outbox.
    var submitted: Bool

    init(id: UUID = UUID(), reporterID: UUID, reportedUserID: UUID, chatID: UUID?,
         reason: ReportReason, note: String = "", createdAt: Date = Date(),
         submitted: Bool = false) {
        self.id = id
        self.reporterID = reporterID
        self.reportedUserID = reportedUserID
        self.chatID = chatID
        self.reason = reason
        self.note = note
        self.createdAt = createdAt
        self.submitted = submitted
    }
}
