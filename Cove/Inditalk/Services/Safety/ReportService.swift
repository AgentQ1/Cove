//
//  ReportService.swift
//  Inditalk
//
//  Delivers abuse reports. Every report is first written to the local outbox
//  (ReportStore) so nothing is lost, then — when Firebase is configured — pushed to the
//  Firestore `reports` collection for server-side moderation and marked submitted.
//
//  Firestore layout:
//    reports/{reportId}   { reporterUid, reportedLocalId, chatLocalId?, reason, note,
//                           createdAt }
//  Rules (firestore.rules) allow create only when reporterUid == auth.uid, and deny
//  client reads — reports are moderator/Cloud-Function readable only.
//
//  REQUIRES the FirebaseFirestore + FirebaseAuth SPM packages (only exercised when
//  AppConfig.usesFirebase is true; otherwise this stays a local-outbox operation).
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class ReportService {
    static let shared = ReportService()

    private let store: ReportStore
    init(store: ReportStore = .shared) { self.store = store }

    /// Result of a submission so the UI can message the user honestly.
    enum Outcome {
        case delivered          // recorded locally AND accepted by the backend
        case queuedLocally      // recorded locally; no backend configured yet
        case queuedNeedsRetry   // recorded locally; backend push failed, will retry
    }

    /// Record + attempt delivery of a report. Never throws — a report is always at
    /// least persisted locally.
    @discardableResult
    func submit(_ report: Report) async -> Outcome {
        store.record(report)

        guard AppConfig.usesFirebase, let reporterUid = Auth.auth().currentUser?.uid else {
            return .queuedLocally
        }

        do {
            var data: [String: Any] = [
                "reporterUid": reporterUid,
                "reportedLocalId": report.reportedUserID.uuidString,
                "reason": report.reason.rawValue,
                "note": report.note,
                "createdAt": FieldValue.serverTimestamp(),
            ]
            if let chatID = report.chatID { data["chatLocalId"] = chatID.uuidString }
            try await Firestore.firestore().collection("reports")
                .document(report.id.uuidString).setData(data)
            store.markSubmitted(report.id)
            return .delivered
        } catch {
            return .queuedNeedsRetry
        }
    }
}
