//
//  ContactsService.swift
//  Inditalk
//
//  Reads the device address book (with permission via PermissionsManager) so the
//  New Chat screen can show real contacts and match them against known Inditalk users
//  by phone number. Enumeration runs off the main actor; results publish on main.
//

import Foundation
import Contacts

@MainActor
final class ContactsService: ObservableObject {
    static let shared = ContactsService()

    enum LoadState: Equatable {
        case idle, loading, denied, restricted, loaded
        case failed(String)
    }

    /// A row from the device address book (not necessarily an Inditalk user).
    struct DeviceContact: Identifiable, Hashable, Sendable {
        let id: String              // CNContact.identifier
        let fullName: String
        let phoneNumbers: [String]
        var primaryPhone: String? { phoneNumbers.first }
    }

    @Published var state: LoadState = .idle
    @Published var deviceContacts: [DeviceContact] = []

    /// Request contacts permission and (re)load the address book.
    func requestAndLoad() async {
        state = .loading
        guard await PermissionsManager.shared.requestContacts() else {
            state = PermissionsManager.shared.contacts == .restricted ? .restricted : .denied
            return
        }
        do {
            deviceContacts = try await Self.enumerateDeviceContacts()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The Inditalk user matching a device contact, if any of its numbers line up.
    func matchUser(for contact: DeviceContact, in users: [InditalkUser]) -> InditalkUser? {
        for phone in contact.phoneNumbers {
            let normalized = Self.normalized(phone: phone)
            guard !normalized.isEmpty else { continue }
            if let match = users.first(where: {
                Self.phonesMatch(Self.normalized(phone: $0.phoneNumber), normalized)
            }) { return match }
        }
        return nil
    }

    /// Digits only — the canonical form for phone comparison.
    nonisolated static func normalized(phone: String) -> String {
        phone.filter(\.isNumber)
    }

    /// Two already-normalized numbers refer to the same line when they're equal or
    /// share the last 10 digits (ignores country-code formatting differences).
    nonisolated static func phonesMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard a.count >= 10, b.count >= 10 else { return false }
        return a.suffix(10) == b.suffix(10)
    }

    /// CNContactStore enumeration is blocking, so it runs detached off the main actor.
    private nonisolated static func enumerateDeviceContacts() async throws -> [DeviceContact] {
        try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.sortOrder = .givenName
            var result: [DeviceContact] = []
            try store.enumerateContacts(with: request) { contact, _ in
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                let name = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                let display = name.isEmpty
                    ? (contact.organizationName.isEmpty ? (phones.first ?? "Unknown") : contact.organizationName)
                    : name
                result.append(DeviceContact(id: contact.identifier,
                                            fullName: display, phoneNumbers: phones))
            }
            return result
        }.value
    }
}
