//
//  MediaPickerView.swift
//  Inditalk
//
//  The attachment sheet shown from the composer "+". A grid of media sources —
//  Photos (multi image/video), Camera, Document, Location, Contact, and Audio
//  (record or import). Every source produces `AttachmentDraft`s that route through
//  the full-screen `AttachmentPreviewSheet` (caption + confirm) before anything
//  is actually sent via `AttachmentSender`.
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct MediaPickerView: View {
    let chatID: UUID
    let onClose: () -> Void

    @EnvironmentObject private var store: DataStore
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isLoadingPicks = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var importerTypes: [UTType] = [.item]
    @State private var showAudioOptions = false
    @State private var showAudioRecorder = false
    @State private var showLocationPicker = false
    @State private var showContactPicker = false
    @State private var showNoPhoneAlert = false
    @State private var showCameraSettingsAlert = false
    @State private var previewBatch: DraftBatch?

    /// Wraps drafts so `.fullScreenCover(item:)` drives the preview screen.
    private struct DraftBatch: Identifiable {
        let id = UUID()
        let drafts: [AttachmentDraft]
    }

    private let sources: [(String, Color, String)] = [
        ("photo.on.rectangle", Palette.ink, "Photos"),
        ("camera.fill", Palette.pine, "Camera"),
        ("doc.fill", Palette.ochre, "Document"),
        ("location.fill", Palette.danger, "Location"),
        ("person.crop.circle.fill", Palette.ink, "Contact"),
        ("waveform", Palette.pine, "Audio"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule().fill(Palette.separator).frame(width: 40, height: 4)
                .frame(maxWidth: .infinity).padding(.top, 8)

            Text("Share").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.textPrimary).padding(.horizontal, 20)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 18) {
                ForEach(sources, id: \.2) { item in
                    if item.2 == "Photos" {
                        PhotosPicker(selection: $pickerItems, maxSelectionCount: 10,
                                     matching: .any(of: [.images, .videos])) {
                            SourceTile(symbol: item.0, tint: item.1, label: item.2)
                        }
                    } else {
                        Button { handleTap(item.2) } label: {
                            SourceTile(symbol: item.0, tint: item.1, label: item.2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .background(Palette.background)
        .presentationDragIndicator(.hidden)
        .overlay {
            if isLoadingPicks {
                ZStack {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView().controlSize(.large).tint(Palette.ink)
                }
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPicked(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                queueDrafts([AttachmentDraft(content: .image(image))])
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $previewBatch) { batch in
            AttachmentPreviewSheet(
                drafts: batch.drafts,
                destinationTitle: store.chat(chatID)?.title ?? "Chat",
                onSend: { drafts, caption in
                    AttachmentSender.send(drafts, caption: caption, to: chatID, store: store)
                    previewBatch = nil
                    onClose()
                },
                onCancel: {
                    discardResources(of: batch.drafts)
                    previewBatch = nil
                }
            )
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: importerTypes, allowsMultipleSelection: false) { result in
            handleImportedFile(result)
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet { recording in
                showAudioRecorder = false
                queueDrafts([AttachmentDraft(content: .audioRecording(
                    localName: recording.localName,
                    duration: recording.duration,
                    waveform: recording.waveform))])
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheet { latitude, longitude in
                showLocationPicker = false
                queueDrafts([AttachmentDraft(content: .location(latitude: latitude,
                                                                longitude: longitude))])
            }
        }
        .sheet(isPresented: $showContactPicker) {
            ContactPickerView(
                onPick: { name, phones in
                    showContactPicker = false
                    handlePickedContact(name: name, phones: phones)
                },
                onCancel: { showContactPicker = false }
            )
            .ignoresSafeArea()
        }
        .confirmationDialog("Share audio", isPresented: $showAudioOptions, titleVisibility: .visible) {
            Button("Record audio") { showAudioRecorder = true }
            Button("Choose audio file") {
                importerTypes = [.audio]
                showFileImporter = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("No phone number", isPresented: $showNoPhoneAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That contact doesn't have a phone number, so it can't be shared.")
        }
        .alert("Camera access is off", isPresented: $showCameraSettingsAlert) {
            Button("Open Settings") { openAppSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow camera access in Settings to take photos in Inditalk.")
        }
    }

    // MARK: Source actions

    private func handleTap(_ label: String) {
        switch label {
        case "Camera":
            guard CameraPicker.isAvailable else {
                ToastCenter.shared.show("Camera isn't available on the Simulator", pending: false)
                return
            }
            Task {
                if await PermissionsManager.shared.requestCamera() {
                    showCamera = true
                } else {
                    showCameraSettingsAlert = true
                }
            }
        case "Document":
            importerTypes = [.item]
            showFileImporter = true
        case "Location":
            showLocationPicker = true
        case "Contact":
            showContactPicker = true
        case "Audio":
            showAudioOptions = true
        default:
            break
        }
    }

    // MARK: Draft building

    /// Present the preview screen for freshly built drafts. The short delay lets
    /// whatever system picker produced them finish its dismiss animation first.
    private func queueDrafts(_ drafts: [AttachmentDraft]) {
        guard !drafts.isEmpty else { return }
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            previewBatch = DraftBatch(drafts: drafts)
        }
    }

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        isLoadingPicks = true
        defer { isLoadingPicks = false }

        var drafts: [AttachmentDraft] = []
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if isVideo {
                if let picked = try? await item.loadTransferable(type: PickedVideoFile.self) {
                    drafts.append(AttachmentDraft(content: .video(picked.url)))
                }
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) {
                drafts.append(AttachmentDraft(content: .image(image)))
            }
        }
        pickerItems = []

        if drafts.isEmpty {
            ToastCenter.shared.show("Couldn't load that selection", pending: false)
        } else {
            queueDrafts(drafts)
        }
    }

    private func handleImportedFile(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        guard let temp = copyToTemp(url) else {
            ToastCenter.shared.show("Couldn't read that file", pending: false)
            return
        }
        queueDrafts([AttachmentDraft(content: .file(temp, displayName: url.lastPathComponent))])
    }

    private func handlePickedContact(name: String, phones: [String]) {
        guard let phone = phones.first(where: { !$0.isEmpty }) else {
            showNoPhoneAlert = true
            return
        }
        let displayName = name.isEmpty ? phone : name
        queueDrafts([AttachmentDraft(content: .contact(name: displayName, phone: phone))])
    }

    /// Copy a security-scoped picked file somewhere we can read after the picker
    /// releases its scope; the real MediaStore import happens on send.
    private func copyToTemp(_ url: URL) -> URL? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch { return nil }
    }

    /// A cancelled preview releases whatever the drafts staged on disk.
    private func discardResources(of drafts: [AttachmentDraft]) {
        for draft in drafts {
            switch draft.content {
            case .video(let url), .file(let url, _):
                try? FileManager.default.removeItem(at: url)
            case .audioRecording(let localName, _, _):
                MediaStore.delete(localName)
            case .image, .location, .contact:
                break
            }
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Movie picked from the photo library, copied out of the transfer sandbox into
/// a temp file that survives until the preview/send flow finishes with it.
/// Shared with the in-app camera's library shortcut (InditalkCameraView), which needs the
/// same "copy the picked movie somewhere readable" behaviour.
struct PickedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideoFile(url: dest)
        }
    }
}

/// Extracted as a View (not a main-actor method returning `some View`) so it composes
/// inside SwiftUI's builder closures without a Swift 6 isolation-crossing error.
private struct SourceTile: View {
    let symbol: String
    let tint: Color
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.white)
                .frame(width: 62, height: 62).background(tint, in: Circle())
            Text(label).font(.system(size: 13)).foregroundStyle(Palette.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
