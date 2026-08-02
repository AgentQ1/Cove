//
//  PermissionsManager.swift
//  Inditalk
//
//  Just-in-time permission requests for camera, microphone, photo library, and
//  contacts, using only Apple frameworks. The corresponding usage-description
//  strings live in Info.plist.
//

import Foundation
import AVFoundation
import Photos
import Contacts

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published var camera: AVAuthorizationStatus = .notDetermined
    @Published var microphone: AVAuthorizationStatus = .notDetermined
    @Published var photos: PHAuthorizationStatus = .notDetermined
    @Published var contacts: CNAuthorizationStatus = .notDetermined

    init() { refresh() }

    func refresh() {
        camera = AVCaptureDevice.authorizationStatus(for: .video)
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        contacts = CNContactStore.authorizationStatus(for: .contacts)
    }

    @discardableResult
    func requestCamera() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        camera = AVCaptureDevice.authorizationStatus(for: .video)
        return granted
    }

    @discardableResult
    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        return granted
    }

    @discardableResult
    func requestPhotos() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photos = status
        return status == .authorized || status == .limited
    }

    @discardableResult
    func requestContacts() async -> Bool {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        contacts = CNContactStore.authorizationStatus(for: .contacts)
        return granted
    }
}
