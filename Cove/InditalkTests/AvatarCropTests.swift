//
//  AvatarCropTests.swift
//  InditalkTests
//
//  The move-and-scale crop maths. A wrong mapping from the on-screen transform back to
//  source pixels fails silently — you just get someone's forehead — so the geometry is
//  pinned here.
//

import XCTest
import UIKit
@testable import Inditalk

@MainActor
final class AvatarCropTests: XCTestCase {

    /// A landscape photo with a red left half and a blue right half, so the crop's
    /// position can be checked by colour.
    private func splitImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
    }

    private func colour(at point: CGPoint, in image: UIImage) -> (r: Int, g: Int, b: Int)? {
        guard let cg = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cg, in: CGRect(x: -point.x, y: -point.y,
                                    width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    func testCropIsSquare() {
        let source = splitImage(width: 1000, height: 500)
        guard let cropped = AvatarCropView.crop(source, diameter: 300, scale: 1,
                                                offset: .zero, maxSide: 1024) else {
            return XCTFail("crop returned nil")
        }
        XCTAssertEqual(cropped.size.width, cropped.size.height, accuracy: 1,
                       "an avatar crop must be square")
    }

    /// At rest the crop takes the CENTRE of the photo — for a red|blue split that means
    /// the seam, so both colours are present.
    func testUntouchedCropTakesTheCentre() {
        let source = splitImage(width: 1000, height: 500)
        guard let cropped = AvatarCropView.crop(source, diameter: 300, scale: 1,
                                                offset: .zero, maxSide: 512) else {
            return XCTFail("crop returned nil")
        }
        let width = cropped.size.width * cropped.scale
        let height = cropped.size.height * cropped.scale
        let left = colour(at: CGPoint(x: width * 0.1, y: height / 2), in: cropped)
        let right = colour(at: CGPoint(x: width * 0.9, y: height / 2), in: cropped)

        XCTAssertEqual(left?.r ?? 0, 255, accuracy: 12, "left of centre should still be red")
        XCTAssertEqual(right?.b ?? 0, 255, accuracy: 12, "right of centre should be blue")
    }

    /// Panning right moves the crop window LEFT across the photo, so an all-red region
    /// comes into frame. This is the sign convention that gets inverted by accident.
    func testPanningMovesTheCropWindow() {
        let source = splitImage(width: 1000, height: 500)
        // The photo fills a 300pt circle at 300/500 = 0.6x, so 1000pt of source is 600pt
        // on screen: panning 150pt right shifts the window a clear 250 source px left.
        guard let cropped = AvatarCropView.crop(source, diameter: 300, scale: 1,
                                                offset: CGSize(width: 150, height: 0),
                                                maxSide: 512) else {
            return XCTFail("crop returned nil")
        }
        let width = cropped.size.width * cropped.scale
        let height = cropped.size.height * cropped.scale
        let sample = colour(at: CGPoint(x: width * 0.9, y: height / 2), in: cropped)
        XCTAssertEqual(sample?.r ?? 0, 255, accuracy: 12,
                       "panning right must bring the photo's left (red) side into the crop")
    }

    /// Zooming in keeps the crop square and inside the source.
    func testZoomedCropStaysSquareAndInBounds() {
        let source = splitImage(width: 1000, height: 500)
        guard let cropped = AvatarCropView.crop(source, diameter: 300, scale: 3,
                                                offset: .zero, maxSide: 1024) else {
            return XCTFail("crop returned nil")
        }
        XCTAssertEqual(cropped.size.width, cropped.size.height, accuracy: 1)
        XCTAssertLessThanOrEqual(cropped.size.width * cropped.scale, 1024)
    }

    /// Big photos are downscaled so an avatar upload isn't a 12 MP file.
    func testResultIsDownscaledToTheOutputBudget() {
        let source = splitImage(width: 4000, height: 3000)
        guard let cropped = AvatarCropView.crop(source, diameter: 300, scale: 1,
                                                offset: .zero, maxSide: 1024) else {
            return XCTFail("crop returned nil")
        }
        XCTAssertLessThanOrEqual(max(cropped.size.width, cropped.size.height) * cropped.scale, 1024)
    }

    /// An EXIF-rotated photo must be baked flat before cropping, or the cut lands on the
    /// wrong region entirely.
    func testRotatedSourceIsHandled() {
        let upright = splitImage(width: 1000, height: 500)
        guard let cg = upright.cgImage else { return XCTFail("no CGImage") }
        let rotated = UIImage(cgImage: cg, scale: 1, orientation: .right)

        guard let cropped = AvatarCropView.crop(rotated, diameter: 300, scale: 1,
                                                offset: .zero, maxSide: 512) else {
            return XCTFail("crop returned nil")
        }
        XCTAssertEqual(cropped.size.width, cropped.size.height, accuracy: 1)
    }
}
