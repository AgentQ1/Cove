//
//  AddContactView.swift
//  Inditalk
//
//  Save a new contact (name + phone) into the store, then jump straight into a
//  1:1 chat with them. DataStore.addContact dedupes by normalized phone, so saving
//  a number that already belongs to a user simply opens the existing chat.
//

import SwiftUI

struct AddContactView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    /// Called with the (existing or newly created) 1:1 chat for the saved contact.
    let onSelect: (Chat) -> Void

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var countryCode = "+1"
    @State private var phone = ""

    private var phoneDigits: String { ContactsService.normalized(phone: phone) }
    private var phoneValid: Bool { (7...15).contains(phoneDigits.count) }

    private var canSave: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty && phoneValid
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Name") {
                    TextField("First name", text: $firstName)
                        .textContentType(.givenName)
                        .foregroundStyle(Palette.textPrimary)
                    TextField("Last name (optional)", text: $lastName)
                        .textContentType(.familyName)
                        .foregroundStyle(Palette.textPrimary)
                }
                .listRowBackground(Palette.surface)

                Section {
                    HStack(spacing: 10) {
                        TextField("+1", text: $countryCode)
                            .keyboardType(.phonePad)
                            .multilineTextAlignment(.center)
                            .frame(width: 64)
                            .padding(.vertical, 6)
                            .background(Palette.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .foregroundStyle(Palette.textPrimary)
                        TextField("Phone number", text: $phone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .foregroundStyle(Palette.textPrimary)
                    }
                } header: {
                    Text("Phone")
                } footer: {
                    if !phone.isEmpty && !phoneValid {
                        Text("Enter 7–15 digits.")
                            .foregroundStyle(Palette.danger)
                    }
                }
                .listRowBackground(Palette.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("New contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.ink)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.tint(Palette.ink).disabled(!canSave)
                }
            }
        }
        .tint(Palette.ink)
    }

    private func save() {
        let name = [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let codeDigits = ContactsService.normalized(phone: countryCode)
        let fullPhone = codeDigits.isEmpty ? phone : "+\(codeDigits) \(phone)"

        let existing = store.user(withPhone: fullPhone)
        // Dedupes by normalized phone — returns the existing user if the number is known.
        let user = store.addContact(name: name, phone: fullPhone)
        if let existing {
            ToastCenter.shared.show("\(existing.displayName) is already in your contacts")
        }
        Haptics.impact(.light)
        onSelect(store.startDirectChat(with: user))
    }
}

#Preview {
    AddContactView { _ in }
        .environmentObject(DataStore.inMemory())
}
