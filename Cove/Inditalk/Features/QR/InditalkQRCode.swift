//
//  InditalkQRCode.swift
//  Inditalk
//
//  Inditalk's contact QR payload. A code encodes the scanned person's REAL Firebase Auth
//  uid, which is what makes a scan actionable: the uid is looked up in Firestore to
//  resolve a genuine account, and is the same identifier used to place calls.
//
//  Format:  inditalk://user/<firebase-uid>
//
//  A custom scheme (rather than a bare uid) means a scan can be told apart from any
//  other QR code in the wild, so "this isn't an Inditalk code" is a distinguishable error.
//

import CoreImage.CIFilterBuiltins
import UIKit

enum InditalkQRCode {

    static let scheme = "inditalk"
    private static let userHost = "user"

    // MARK: Encoding

    /// The payload string to render for `uid`.
    static func payload(for uid: String) -> String {
        "\(scheme)://\(userHost)/\(uid)"
    }

    /// Render `payload` as a crisp QR image at roughly `size` points.
    ///
    /// CoreImage emits a tiny bitmap (one pixel per module), so it is scaled up with a
    /// nearest-neighbour transform BEFORE rasterizing — scaling the UIImage afterwards
    /// would interpolate and blur the modules, which scanners handle poorly.
    static func image(for payload: String, size: CGFloat = 240) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        // "M" corrects ~15% of the symbol, enough to stay readable on a screen without
        // inflating module count the way "H" would.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scale = max(1, size / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: Decoding

    enum DecodeError: LocalizedError, Equatable {
        case notAnInditalkCode
        case emptyIdentifier

        var errorDescription: String? {
            switch self {
            case .notAnInditalkCode:
                return "That isn't an Inditalk QR code. Ask them to open Inditalk → Settings → their profile code."
            case .emptyIdentifier:
                return "That Inditalk code is damaged and doesn't identify an account."
            }
        }
    }

    /// Extract the Firebase uid from a scanned string.
    static func uid(from scanned: String) throws -> String {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == userHost else {
            throw DecodeError.notAnInditalkCode
        }
        // URL(string: "inditalk://user/abc").path == "/abc"
        let uid = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !uid.isEmpty else { throw DecodeError.emptyIdentifier }
        return uid
    }
}
