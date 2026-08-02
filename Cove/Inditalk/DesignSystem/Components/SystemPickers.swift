//
//  SystemPickers.swift
//  Inditalk
//
//  Thin SwiftUI wrappers over the UIKit system pickers Inditalk needs: the camera
//  (UIImagePickerController), the share sheet (UIActivityViewController), and the
//  contact picker (CNContactPickerViewController). Photo library and file import
//  are handled by SwiftUI-native `PhotosPicker` / `.fileImporter` at the call sites.
//  Permission prompts are driven by PermissionsManager; the Info.plist usage
//  strings are already present.
//

import SwiftUI
import UIKit
import ContactsUI

/// Camera capture. Presents the system camera and returns the captured image.
/// The camera is unavailable on the Simulator — callers should fall back to the
/// photo library there (see `UIImagePickerController.isSourceTypeAvailable`).
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }

    /// Whether real camera capture is possible on this device.
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
}

/// Identifiable wrapper so a freshly captured `UIImage` can drive `.sheet(item:)`.
struct CapturedPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// System share sheet (used by "Invite a Friend", invite-link copy, etc.).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// System contact picker for sharing a contact card. CNContactPickerViewController
/// runs out-of-process and needs NO contacts permission. Returns the picked
/// contact's display name and phone numbers (may be empty — callers handle that).
struct ContactPickerView: UIViewControllerRepresentable {
    var onPick: (_ name: String, _ phoneNumbers: [String]) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let parent: ContactPickerView
        init(_ parent: ContactPickerView) { self.parent = parent }

        // CNContactPickerDelegate callbacks arrive on the main thread but the
        // protocol requirements are nonisolated — assume main-actor to call back.
        nonisolated func contactPicker(_ picker: CNContactPickerViewController,
                                       didSelect contact: CNContact) {
            let formatted = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            let name = formatted.isEmpty ? contact.organizationName : formatted
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            MainActor.assumeIsolated {
                parent.onPick(name, phones)
            }
        }

        nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            MainActor.assumeIsolated {
                parent.onCancel()
            }
        }
    }
}
