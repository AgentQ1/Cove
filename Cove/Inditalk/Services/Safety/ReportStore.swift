//
//  ReportStore.swift
//  Inditalk
//
//  Durable local outbox for abuse reports. A report is recorded here first (so it
//  survives relaunch and is never silently lost), then ReportService attempts backend
//  delivery. Backend-free and fully unit-testable: inject a UserDefaults suite so tests
//  don't touch the standard domain.
//

import Foundation

@MainActor
final class ReportStore {
    static let shared = ReportStore()

    private let defaults: UserDefaults
    private let key = "cove.reports.outbox.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// All reports ever recorded on this device, newest first.
    func all() -> [Report] {
        guard let data = defaults.data(forKey: key),
              let reports = try? JSONDecoder().decode([Report].self, from: data) else { return [] }
        return reports.sorted { $0.createdAt > $1.createdAt }
    }

    /// Reports not yet accepted by the backend.
    func pending() -> [Report] { all().filter { !$0.submitted } }

    /// Append a new report to the outbox.
    func record(_ report: Report) {
        var reports = all()
        reports.append(report)
        persist(reports)
    }

    /// Mark a recorded report as delivered to the backend.
    func markSubmitted(_ id: UUID) {
        var reports = all()
        guard let idx = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[idx].submitted = true
        persist(reports)
    }

    /// Remove all recorded reports (used by account deletion / local wipe).
    func clear() { defaults.removeObject(forKey: key) }

    private func persist(_ reports: [Report]) {
        if let data = try? JSONEncoder().encode(reports) { defaults.set(data, forKey: key) }
    }
}
