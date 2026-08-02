//
//  InditalkCameraView.swift
//  Inditalk
//
//  Inditalk's own camera, replacing the system `UIImagePickerController` chrome for the
//  in-app capture buttons. A messenger's camera is part of the app: tap to shoot, HOLD
//  to record, flip, flash, pinch to zoom, and a shortcut into the library — none of
//  which the system picker offers.
//
//  The result is an `AttachmentDraft.Content`, so a capture flows into exactly the same
//  preview/caption/send path as a picked photo or an imported movie.
//

import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

// MARK: - Camera view

struct InditalkCameraView: View {
    enum Capture {
        case photo(UIImage)
        case video(URL)

        /// A capture is just an attachment draft — it goes through the same
        /// preview/caption/send path as anything picked from the library.
        var draftContent: AttachmentDraft.Content {
            switch self {
            case .photo(let image): return .image(image)
            case .video(let url):   return .video(url)
            }
        }
    }

    /// Profile photos want a still only; chat capture allows both.
    var allowsVideo: Bool = true
    let onCapture: (Capture) -> Void

    /// Whether this device can actually capture (false on the Simulator).
    static var isAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()
    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var libraryItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .gesture(
                    MagnifyGesture()
                        .onChanged { camera.setZoom(zoomAtGestureStart * $0.magnification) }
                        .onEnded { _ in zoomAtGestureStart = camera.zoom }
                )
                .onAppear { zoomAtGestureStart = camera.zoom }

            if camera.isRecording { recordingBorder }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .statusBarHidden()
        .task {
            // Hand results straight back rather than observing a published value —
            // `Capture` carries a UIImage/URL and has no business being Equatable.
            camera.onCapture = { capture in
                onCapture(capture)
                dismiss()
            }
            // Ask for the mic BEFORE the session is configured: an audio input added
            // without permission records a silent video, which looks like a bug and is
            // only discovered after the moment has passed.
            let micGranted = allowsVideo ? await PermissionsManager.shared.requestMicrophone() : false
            await camera.start(withAudio: micGranted)
        }
        .onDisappear { camera.stop() }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task { await loadFromLibrary(item) }
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            circleButton("xmark") { dismiss() }
            Spacer()
            if camera.isRecording {
                Text(camera.recordingLabel)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Palette.danger, in: Capsule())
            }
            Spacer()
            circleButton(camera.flashSymbol) { camera.cycleFlash() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            Text(allowsVideo
                 ? (camera.isRecording ? "Release to send" : "Tap for photo, hold for video")
                 : "Tap to take a photo")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))

            HStack {
                Spacer()
                shutter
                Spacer()
            }
            .overlay(alignment: .leading) {
                // Straight into the library without backing out of the camera first.
                PhotosPicker(selection: $libraryItem,
                             matching: allowsVideo ? .any(of: [.images, .videos]) : .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .padding(.leading, 32)
                .disabled(camera.isRecording)
                .opacity(camera.isRecording ? 0.4 : 1)
                .accessibilityLabel("Choose from library")
            }
            .overlay(alignment: .trailing) {
                circleButton("arrow.triangle.2.circlepath") { camera.flip() }
                    .padding(.trailing, 32)
                    .disabled(camera.isRecording)
                    .opacity(camera.isRecording ? 0.4 : 1)
            }
        }
        .padding(.bottom, 36)
    }

    private var shutter: some View {
        ZStack {
            Circle()
                .strokeBorder(.white, lineWidth: 4)
                .frame(width: 78, height: 78)
            Circle()
                .fill(camera.isRecording ? Palette.danger : .white)
                .frame(width: camera.isRecording ? 36 : 64,
                       height: camera.isRecording ? 36 : 64)
                .animation(.snappy(duration: 0.2), value: camera.isRecording)
        }
        .contentShape(Circle())
        // Tap shoots a still; press-and-hold records for as long as it's held — the
        // gesture every messenger camera uses.
        .onTapGesture {
            guard !camera.isRecording else { return }
            Haptics.impact(.light)
            camera.capturePhoto()
        }
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 60) {
            // Fires once the press is recognised; recording stops on release below.
        } onPressingChanged: { isPressing in
            guard allowsVideo else { return }
            if isPressing {
                Haptics.impact(.medium)
                camera.startRecordingAfterHold()
            } else {
                camera.stopRecording()
            }
        }
        .accessibilityLabel(camera.isRecording ? "Stop recording" : "Take photo")
    }

    /// Unmistakable "you are recording" frame.
    private var recordingBorder: some View {
        Rectangle()
            .strokeBorder(Palette.danger, lineWidth: 4)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// Library pick, handed back exactly like a capture. Video is tried first: a movie
    /// also loads as `Data`, so checking images first would send a video as a still.
    private func loadFromLibrary(_ item: PhotosPickerItem) async {
        defer { libraryItem = nil }
        if allowsVideo, let movie = try? await item.loadTransferable(type: PickedVideoFile.self) {
            onCapture(.video(movie.url))
            dismiss()
            return
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            ToastCenter.shared.show("Couldn't load that item")
            return
        }
        onCapture(.photo(image))
        dismiss()
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview layer

/// Hosts the live `AVCaptureVideoPreviewLayer`. A plain UIView whose backing layer IS
/// the preview layer, so it resizes with the view instead of needing manual frame work.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Capture session

@MainActor
final class CameraController: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var flashMode: AVCaptureDevice.FlashMode = .auto
    @Published private(set) var recordingSeconds = 0
    /// Called once a photo or movie is ready; the view hands it up and dismisses.
    var onCapture: ((InditalkCameraView.Capture) -> Void)?

    let session = AVCaptureSession()
    /// AVCaptureSession isn't Sendable, but the class is documented as safe to use from
    /// one serial queue — which is exactly how `sessionQueue` uses it.
    private var sessionBox: UncheckedSendableBox<AVCaptureSession> { UncheckedSendableBox(session) }

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    /// Session configuration and start/stop MUST stay off the main thread —
    /// `startRunning()` blocks for a noticeable beat and would stutter the presentation.
    private let sessionQueue = DispatchQueue(label: "chat.cove.camera.session")
    private var videoInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var configured = false
    private var recordingTimer: Task<Void, Never>?
    /// A hold that hasn't passed the long-press threshold yet must not start a recording.
    private var holdRecognised = false

    var flashSymbol: String {
        switch flashMode {
        case .auto: return "bolt.badge.a.fill"
        case .on:   return "bolt.fill"
        default:    return "bolt.slash.fill"
        }
    }

    var recordingLabel: String {
        String(format: "%d:%02d", recordingSeconds / 60, recordingSeconds % 60)
    }

    // MARK: Lifecycle

    func start(withAudio: Bool) async {
        if !configured {
            configured = true
            await configure(withAudio: withAudio)
        }
        let boxed = sessionBox
        sessionQueue.async {
            let session = boxed.value
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        recordingTimer?.cancel()
        let boxed = sessionBox
        sessionQueue.async {
            let session = boxed.value
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    private func configure(withAudio: Bool) async {
        let boxed = sessionBox
        let outputs = UncheckedSendableBox((photoOutput, movieOutput))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                let session = boxed.value
                let (photoOutput, movieOutput) = outputs.value
                session.beginConfiguration()
                session.sessionPreset = .high

                if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: camera),
                   session.canAddInput(input) {
                    session.addInput(input)
                    // The input is only ever touched on the main actor after this hop
                    // (zoom reads its device), so boxing it across is sound.
                    let boxedInput = UncheckedSendableBox(input)
                    Task { @MainActor [weak self] in self?.videoInput = boxedInput.value }
                }
                // Only for video capture: adding a mic input lights the orange recording
                // indicator, so a stills-only camera must not ask for one.
                if withAudio,
                   let mic = AVCaptureDevice.default(for: .audio),
                   let micInput = try? AVCaptureDeviceInput(device: mic),
                   session.canAddInput(micInput) {
                    session.addInput(micInput)
                }
                if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
                if withAudio, session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

                session.commitConfiguration()
                continuation.resume()
            }
        }
    }

    // MARK: Controls

    func cycleFlash() {
        flashMode = switch flashMode {
        case .auto: .on
        case .on:   .off
        default:    .auto
        }
    }

    func flip() {
        position = position == .back ? .front : .back
        let target = position
        let boxed = sessionBox
        sessionQueue.async { [weak self] in
            let session = boxed.value
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
            where input.device.hasMediaType(.video) {
                session.removeInput(input)
            }
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let boxedInput = UncheckedSendableBox(input)
            Task { @MainActor in self?.videoInput = boxedInput.value }
        }
    }

    func setZoom(_ factor: CGFloat) {
        guard let device = videoInput?.device else { return }
        let clamped = min(max(factor, 1), min(device.activeFormat.videoMaxZoomFactor, 8))
        zoom = clamped
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            print("[Inditalk camera] zoom failed: \(error)")
        }
    }

    // MARK: Capture

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(flashMode) { settings.flashMode = flashMode }
        let mirrored = position == .front
        photoOutput.capturePhoto(with: settings, delegate: PhotoCaptureDelegate(mirrored: mirrored) { [weak self] image in
            guard let image else { return }
            self?.onCapture?(.photo(image))
        })
    }

    /// Called on press-down; the actual recording only begins once the hold has been
    /// held long enough to be a hold rather than a tap.
    func startRecordingAfterHold() {
        holdRecognised = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.holdRecognised, !self.isRecording else { return }
            self.beginRecording()
        }
    }

    private func beginRecording() {
        // No video connection means the movie output was never added (stills-only mode).
        guard movieOutput.connection(with: .video) != nil else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        if let connection = movieOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        recordingSeconds = 0
        recordingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRecording else { return }
                self.recordingSeconds += 1
            }
        }
    }

    func stopRecording() {
        holdRecognised = false
        guard isRecording else { return }
        movieOutput.stopRecording()
        recordingTimer?.cancel()
    }
}

// MARK: - Output delegates

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        let boxed = UncheckedSendableBox(outputFileURL)
        let failed = error != nil
        Task { @MainActor [weak self] in
            self?.isRecording = false
            guard !failed else {
                print("[Inditalk camera] recording failed")
                return
            }
            // A stray sub-second clip is a mis-recognised tap, not a video.
            // `AVAsset.duration` is deprecated since iOS 16 in favour of async loading.
            let asset = AVURLAsset(url: boxed.value)
            let duration = await (try? asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            guard duration >= 0.6 else {
                try? FileManager.default.removeItem(at: boxed.value)
                return
            }
            self?.onCapture?(.video(boxed.value))
        }
    }
}

/// Kept as its own object because `AVCapturePhotoOutput` holds its delegate WEAKLY —
/// a delegate that only lives for the duration of the call is deallocated before the
/// photo arrives, and the capture silently produces nothing.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let mirrored: Bool
    private let completion: @MainActor (UIImage?) -> Void
    /// Self-reference dropped once the photo is delivered.
    private var retain: PhotoCaptureDelegate?

    init(mirrored: Bool, completion: @escaping @MainActor (UIImage?) -> Void) {
        self.mirrored = mirrored
        self.completion = completion
        super.init()
        retain = self
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        let boxed = UncheckedSendableBox(image)
        let mirrored = mirrored
        Task { @MainActor [completion] in
            var result = boxed.value
            // Selfies are expected to look like the preview did.
            if mirrored, let cg = result?.cgImage, let source = result {
                result = UIImage(cgImage: cg, scale: source.scale, orientation: .leftMirrored)
            }
            completion(result)
        }
        retain = nil
    }
}
