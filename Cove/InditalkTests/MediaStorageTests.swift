//
//  MediaStorageTests.swift
//  InditalkTests
//
//  The Storage screen's promises, as tests: identical media is stored once (so the
//  totals don't double-count), the browser can enumerate what is actually on disk, and
//  deleting files frees the space immediately.
//

import XCTest
import UIKit
@testable import Inditalk

@MainActor
final class MediaStorageTests: XCTestCase {

    private var written: [String] = []

    override func tearDown() async throws {
        MediaStore.delete(written)
        written = []
        try await super.tearDown()
    }

    private func image(_ color: UIColor, side: CGFloat = 220) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func store(_ image: UIImage) -> (name: String, bytes: Int) {
        let saved = MediaStore.saveImage(image)
        XCTAssertNotNil(saved)
        written.append(saved!.name)
        return saved!
    }

    /// The same picture sent twice (or forwarded to several chats) must occupy ONE file.
    func testIdenticalMediaIsStoredOnce() {
        let picture = image(.systemIndigo)
        let first = store(picture)
        let countAfterFirst = MediaStore.items().count

        let second = store(picture)

        XCTAssertEqual(first.name, second.name, "identical bytes must map to the same file")
        XCTAssertEqual(MediaStore.items().count, countAfterFirst,
                       "storing the same media twice must not add a second file")
    }

    /// Different media still gets its own file — de-duplication must not collapse
    /// unrelated pictures into one.
    func testDifferentMediaIsStoredSeparately() {
        let a = store(image(.systemTeal))
        let b = store(image(.systemOrange))
        XCTAssertNotEqual(a.name, b.name)
    }

    /// Opting out is what keeps avatars/statuses safe to delete: they own their copy.
    func testDedupeCanBeOptedOutOfForFilesThatOwnTheirCopy() {
        let picture = image(.systemPink)
        let shared = store(picture)
        guard let owned = MediaStore.saveImage(picture, dedupe: false) else {
            return XCTFail("expected the un-deduped save to succeed")
        }
        written.append(owned.name)
        XCTAssertNotEqual(shared.name, owned.name)
    }

    /// The browser lists real files, with the size and category it will show.
    func testItemsReportSizeAndCategory() {
        let saved = store(image(.systemGreen))
        guard let item = MediaStore.items(in: .photos).first(where: { $0.localName == saved.name }) else {
            return XCTFail("stored photo missing from the photos listing")
        }
        XCTAssertEqual(item.bytes, saved.bytes)
        XCTAssertEqual(item.category, .photos)
        XCTAssertFalse(item.sizeLabel.isEmpty)
    }

    /// Deleting the picked files frees the bytes right away — the totals the Storage
    /// screen shows are recomputed from the same listing.
    func testDeletingSelectedFilesFreesSpaceImmediately() {
        let keep = store(image(.systemBlue, side: 200))
        let remove = store(image(.systemRed, side: 300))
        let before = MediaStore.totalBytes()

        let deleted = MediaStore.delete([remove.name])

        XCTAssertEqual(deleted, [remove.name])
        XCTAssertFalse(MediaStore.exists(remove.name))
        XCTAssertTrue(MediaStore.exists(keep.name), "only the selected file may be removed")
        XCTAssertEqual(MediaStore.totalBytes(), before - remove.bytes)
    }

    /// Grid tiles decode a downsampled thumbnail rather than the full-resolution photo.
    func testThumbnailsDecode() async {
        let saved = store(image(.systemYellow, side: 900))
        let thumbnail = await MediaStore.downsampledImage(named: saved.name, maxPixels: 320)
        guard let thumbnail else { return XCTFail("thumbnail failed to decode") }
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 320)
    }
}
