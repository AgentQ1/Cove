//
//  AccountSettingsView.swift
//  Inditalk
//
//  The real Settings › Account screen. Shows the signed-in identity and provides the
//  App-Store-required in-app account deletion flow (Guideline 5.1.1(v)): a visible
//  "Delete Account" control, an explicit typed confirmation, honest retention copy, and
//  a real deletion service that removes the account + wipes local state.
//

import SwiftUI

struct AccountSettingsView: View {
    @EnvironmentObject private var store: DataStore
    @EnvironmentObject private var session: AppSession
    @StateObject private var vm = AccountViewModel()

    var body: some View {
        List {
            Section("Signed in as") {
                LabeledContent("Name", value: store.currentUser.displayName)
                if !store.currentUser.phoneNumber.isEmpty {
                    LabeledContent("Phone", value: store.currentUser.phoneNumber)
                }
            }
            .listRowBackground(Palette.surface)

            Section {
                Button(role: .destructive) { session.signOut() } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(Palette.danger)
                }
            } footer: {
                Text("Signing out keeps your account and data. You can sign back in with your phone number.")
            }
            .listRowBackground(Palette.surface)

            Section {
                Button(role: .destructive) { vm.showDeleteConfirm = true } label: {
                    Label("Delete Account", systemImage: "trash")
                        .foregroundStyle(Palette.danger)
                }
                .disabled(vm.isDeleting)
            } header: {
                Text("Danger zone")
            } footer: {
                Text("Permanently deletes your Inditalk account and removes your profile, "
                     + "message history, contacts, and encryption keys from this device. "
                     + "Where a backend is configured, your server-side profile and keys "
                     + "are deleted too and you are removed from your chats. This cannot be undone.")
            }
            .listRowBackground(Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $vm.showDeleteConfirm) {
            DeleteAccountSheet(vm: vm) {
                await vm.deleteAccount(store: store, session: session)
            }
            .presentationDetents([.medium, .large])
        }
        .overlay {
            if vm.isDeleting {
                ProgressView("Deleting your account…")
                    .padding(24)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 20)
            }
        }
        .alert("Couldn't delete account", isPresented: $vm.showError, presenting: vm.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

/// Typed-confirmation sheet — the user must type DELETE, matching how high-risk
/// destructive actions are gated elsewhere in the ecosystem.
private struct DeleteAccountSheet: View {
    @ObservedObject var vm: AccountViewModel
    @Environment(\.dismiss) private var dismiss
    let confirm: () async -> Void

    private let phrase = "DELETE"
    @State private var typed = ""

    private var canDelete: Bool {
        typed.trimmingCharacters(in: .whitespaces).uppercased() == phrase && !vm.isDeleting
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40)).foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity)

                Text("Delete your account?")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.textPrimary)

                Text("This permanently deletes your account and erases your data from this "
                     + "device. If a backend is connected, your server-side data is deleted "
                     + "and you're removed from your chats. Some records may be retained "
                     + "briefly where required by law or to prevent abuse. This can't be undone.")
                    .font(.system(size: 15)).foregroundStyle(Palette.textSecondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Type \(phrase) to confirm")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textSecondary)
                    TextField(phrase, text: $typed)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .padding().frame(maxWidth: .infinity)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                }

                Spacer()

                Button {
                    Task { await confirm() }
                } label: {
                    Text(vm.isDeleting ? "Deleting…" : "Delete Account")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(canDelete ? Palette.danger : Palette.danger.opacity(0.4), in: Capsule())
                }
                .disabled(!canDelete)

                Button("Cancel") { dismiss() }
                    .frame(maxWidth: .infinity).tint(Palette.ink)
                    .disabled(vm.isDeleting)
            }
            .padding(24)
            .background(Palette.background)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

@MainActor
final class AccountViewModel: ObservableObject {
    @Published var showDeleteConfirm = false
    @Published var isDeleting = false
    @Published var showError = false
    @Published var errorMessage: String?

    private let service: AccountDeletionService

    init(service: AccountDeletionService = .shared) { self.service = service }

    func deleteAccount(store: DataStore, session: AppSession) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await service.deleteAccount(store: store)
            showDeleteConfirm = false
            session.signOut()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
