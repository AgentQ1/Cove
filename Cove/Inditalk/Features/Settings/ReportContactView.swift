//
//  ReportContactView.swift
//  Inditalk
//
//  Real "report this contact" flow. Replaces the previous toast-only stub: the user
//  picks a reason and optionally adds detail, and the report is recorded to the local
//  outbox and (when a backend is configured) delivered to the `reports` collection for
//  moderation via ReportService. The confirmation copy tells the user honestly what
//  happened — delivered vs. queued locally.
//

import SwiftUI

struct ReportContactView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss

    let reportedUser: InditalkUser
    let chatID: UUID?
    /// Whether to also block the user after reporting (defaults on — common pattern).
    @State private var alsoBlock = true
    @State private var reason: ReportReason = .spam
    @State private var note = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Tell us what's wrong with your chat with \(reportedUser.displayName). "
                         + "Reports are reviewed by the Inditalk safety team. In an emergency, contact "
                         + "local authorities.")
                        .font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
                }
                .listRowBackground(Palette.background)

                Section("Reason") {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { r in Text(r.label).tag(r) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .listRowBackground(Palette.surface)

                Section("Add detail (optional)") {
                    TextField("What happened?", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .foregroundStyle(Palette.textPrimary)
                }
                .listRowBackground(Palette.surface)

                Section {
                    Toggle("Also block \(reportedUser.displayName)", isOn: $alsoBlock)
                        .tint(Palette.pine)
                } footer: {
                    Text("Blocking stops them from messaging or calling you.")
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.ink).disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { submit() }
                        .tint(Palette.danger).disabled(isSubmitting)
                }
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        let report = Report(reporterID: store.currentUser.id,
                            reportedUserID: reportedUser.id,
                            chatID: chatID, reason: reason,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        if alsoBlock { store.block(reportedUser.id) }
        Task {
            let outcome = await ReportService.shared.submit(report)
            isSubmitting = false
            dismiss()
            switch outcome {
            case .delivered:
                ToastCenter.shared.show("Report sent to the Inditalk safety team", pending: false)
            case .queuedLocally, .queuedNeedsRetry:
                ToastCenter.shared.show("Report saved — it'll be sent when you're online", pending: false)
            }
        }
    }
}
