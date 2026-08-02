//
//  InditalkQRCodeTests.swift
//  InditalkTests
//
//  Round-trips the contact-QR payload and pins the failure modes, since a QR scan that
//  silently does nothing is the worst outcome for that feature.
//

import XCTest
@testable import Inditalk

final class InditalkQRCodeTests: XCTestCase {

    func testPayloadRoundTripsUID() throws {
        let uid = "aBcD1234efGH5678"
        let decoded = try InditalkQRCode.uid(from: InditalkQRCode.payload(for: uid))
        XCTAssertEqual(decoded, uid)
    }

    func testDecodeIgnoresSurroundingWhitespace() throws {
        let payload = "  \(InditalkQRCode.payload(for: "uid-42"))\n"
        XCTAssertEqual(try InditalkQRCode.uid(from: payload), "uid-42")
    }

    func testNonInditalkCodeIsRejected() {
        for scanned in ["https://example.com/user/abc", "just some text", "wa.me/1555"] {
            XCTAssertThrowsError(try InditalkQRCode.uid(from: scanned)) { error in
                XCTAssertEqual(error as? InditalkQRCode.DecodeError, .notAnInditalkCode,
                               "\(scanned) should be reported as a non-Inditalk code")
            }
        }
    }

    func testInditalkCodeWithoutIdentifierIsRejected() {
        XCTAssertThrowsError(try InditalkQRCode.uid(from: "inditalk://user/")) { error in
            XCTAssertEqual(error as? InditalkQRCode.DecodeError, .emptyIdentifier)
        }
    }

    func testGeneratedImageIsScannableSize() throws {
        let image = try XCTUnwrap(InditalkQRCode.image(for: InditalkQRCode.payload(for: "uid-1"), size: 240))
        // CoreImage emits one pixel per module; the transform must scale it up so the
        // rendered code isn't a blurry 25x25 thumbnail.
        XCTAssertGreaterThanOrEqual(image.size.width, 200)
        XCTAssertEqual(image.size.width, image.size.height, accuracy: 1)
    }
}
