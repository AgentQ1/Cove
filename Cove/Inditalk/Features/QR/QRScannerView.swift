//
//  QRScannerView.swift
//  Inditalk
//
//  Live QR scanner built on AVFoundation. Camera access is requested just-in-time by
//  the presenting view (PermissionsManager); this view reports a clear failure rather
//  than showing a black rectangle if the session can't be built.
//

// AVCaptureSession is not yet Sendable, but it is documented as safe to drive from a
// single serial queue — which is exactly what `sessionQueue` below does. @preconcurrency
// keeps that pattern from producing Sendable diagnostics on every hop onto the queue.
@preconcurrency import AVFoundation
import SwiftUI

struct QRScannerView: UIViewControllerRepresentable {
    /// Called once per distinct code. The presenter is responsible for dismissing.
    var onScan: (String) -> Void
    var onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController {

    var onScan: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    /// Session configuration and start/stop must stay off the main thread — both block.
    private let sessionQueue = DispatchQueue(label: "chat.cove.qr.session")
    /// Guarantees a single delivery per presentation, so a code held in frame doesn't
    /// fire the handler dozens of times a second.
    private var hasDelivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasDelivered = false
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            // Simulator, or a device whose camera is unavailable/in use.
            onFailure?("Inditalk can't reach the camera on this device. QR scanning needs a real device with camera access enabled.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onFailure?("Inditalk couldn't start the QR scanner.")
            return
        }
        session.addOutput(output)
        // Deliver on the main queue so the handler can touch UI state directly.
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Must be set AFTER the output is attached, or the type isn't yet available.
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        // Reduce the non-Sendable AVFoundation objects to a plain String here, so only a
        // Sendable value crosses into the main-actor context below.
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }

        // The delegate queue is .main (set above), so this is already main-thread work.
        MainActor.assumeIsolated {
            guard !hasDelivered else { return }
            hasDelivered = true
            Haptics.notify(.success)
            onScan?(value)
        }
    }
}
