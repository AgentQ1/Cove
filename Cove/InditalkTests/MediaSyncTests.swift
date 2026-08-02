//
//  MediaSyncTests.swift
//  InditalkTests
//
//  Covers the cross-device media + status sync seams added for attachment delivery:
//  the MediaEnvelope wire format (attachment metadata carried inside the E2EE
//  ciphertext), the DataStore ingest merge rules for attachments, the
//  download-completion hooks, and remote status ingestion semantics.
//

import XCTest
@testable import Inditalk

@MainActor
final class MediaSyncTests: XCTestCase {

    // MARK: Helpers

    private func someoneElse(_ store: DataStore) -> InditalkUser {
        store.users.values.first { $0.id != store.currentUser.id }!
    }

    private func fullAttachment() -> Attachment {
        Attachment(assetName: nil, localName: "abc.jpg", durationSeconds: 12.5,
                   waveform: [0.1, 0.9, 0.4], fileName: "Report.pdf", byteSize: 1234,
                   latitude: 51.5, longitude: -0.12,
                   contactName: "Priya", contactPhone: "+14155550177")
    }

    // MARK: MediaEnvelope wire format

    func testEnvelopeRoundTripPreservesCaptionAndMetadata() throws {
        let envelope = MediaEnvelope(caption: "look at this", attachment: fullAttachment(),
                                     mediaPath: "chats/c/u/m.jpg", mediaKey: "a2V5", ext: "jpg")
        let wire = try envelope.encodedString()
        let decoded = try XCTUnwrap(MediaEnvelope.decode(wire))

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.caption, "look at this")
        XCTAssertEqual(decoded.mediaPath, "chats/c/u/m.jpg")
        XCTAssertEqual(decoded.mediaKey, "a2V5")

        // The receiver-side attachment carries every metadata field, with localName
        // supplied only once the media file exists on the receiving device.
        let rebuilt = decoded.attachment(localName: "msg-1.jpg")
        XCTAssertEqual(rebuilt.localName, "msg-1.jpg")
        XCTAssertEqual(rebuilt.durationSeconds, 12.5)
        XCTAssertEqual(rebuilt.waveform, [0.1, 0.9, 0.4])
        XCTAssertEqual(rebuilt.fileName, "Report.pdf")
        XCTAssertEqual(rebuilt.byteSize, 1234)
        XCTAssertEqual(rebuilt.latitude, 51.5)
        XCTAssertEqual(rebuilt.longitude, -0.12)
        XCTAssertEqual(rebuilt.contactName, "Priya")
        XCTAssertEqual(rebuilt.contactPhone, "+14155550177")
    }

    func testDecodeRejectsLegacyPlainCaption() {
        // Older media messages carried only the bare caption string — those must keep
        // rendering as caption text, not fail or turn into JSON soup.
        XCTAssertNil(MediaEnvelope.decode("just a caption"))
        XCTAssertNil(MediaEnvelope.decode(""))
        XCTAssertNil(MediaEnvelope.decode("{not json"))
    }

    func testLocalMediaNameIsDeterministicWithExtensionFallback() {
        XCTAssertEqual(MediaEnvelope.localMediaName(messageId: "M1", ext: "jpg"), "msg-M1.jpg")
        XCTAssertEqual(MediaEnvelope.localMediaName(messageId: "M1", ext: nil), "msg-M1.bin")
        XCTAssertEqual(MediaEnvelope.localMediaName(messageId: "M1", ext: ""), "msg-M1.bin")
    }

    // MARK: Ingest merge rules for attachments

    func testIngestInsertsIncomingMessageWithAttachment() {
        let store = DataStore.inMemory()
        let chatID = store.chats[0].id
        let sender = someoneElse(store)
        let incoming = Message(chatID: chatID, senderID: sender.id, kind: .image,
                               text: "hi", state: .read, isOutgoing: false,
                               attachment: Attachment(fileName: "a.jpg", byteSize: 9))

        store.ingest(remoteMessages: [incoming], in: chatID)

        let stored = store.messages(in: chatID).first { $0.id == incoming.id }
        XCTAssertEqual(stored?.attachment?.fileName, "a.jpg")
        XCTAssertEqual(stored?.kind, .image)
    }

    func testIngestDoesNotClobberSendersLocalAttachment() {
        let store = DataStore.inMemory()
        let chatID = store.chats[0].id
        let sent = store.sendAttachment(kind: .image,
                                        attachment: Attachment(localName: "local-photo.jpg"),
                                        caption: "mine", to: chatID)

        // The server echo of our own message maps WITHOUT an attachment (the local
        // copy is authoritative) — the local file reference must survive.
        var echo = sent
        echo.attachment = nil
        store.ingest(remoteMessages: [echo], in: chatID)

        let stored = store.messages(in: chatID).first { $0.id == sent.id }
        XCTAssertEqual(stored?.attachment?.localName, "local-photo.jpg")
    }

    func testIngestUpgradesMetadataOnlyAttachmentWhenFileArrives() {
        let store = DataStore.inMemory()
        let chatID = store.chats[0].id
        let sender = someoneElse(store)
        var message = Message(chatID: chatID, senderID: sender.id, kind: .image,
                              text: "", state: .read, isOutgoing: false,
                              attachment: Attachment(fileName: "a.jpg"))
        store.ingest(remoteMessages: [message], in: chatID)

        // A later snapshot resolved the media file on disk (localName set).
        message.attachment = Attachment(localName: "msg-x.jpg", fileName: "a.jpg")
        store.ingest(remoteMessages: [message], in: chatID)

        let stored = store.messages(in: chatID).first { $0.id == message.id }
        XCTAssertEqual(stored?.attachment?.localName, "msg-x.jpg")
    }

    func testAttachDownloadedMediaFillsLocalNameOnce() {
        let store = DataStore.inMemory()
        let chatID = store.chats[0].id
        let sender = someoneElse(store)
        let message = Message(chatID: chatID, senderID: sender.id, kind: .video,
                              text: "", state: .read, isOutgoing: false,
                              attachment: Attachment(durationSeconds: 3))
        store.ingest(remoteMessages: [message], in: chatID)

        store.attachDownloadedMedia(messageID: message.id, in: chatID, localName: "msg-v.mov")
        var stored = store.messages(in: chatID).first { $0.id == message.id }
        XCTAssertEqual(stored?.attachment?.localName, "msg-v.mov")
        XCTAssertEqual(stored?.attachment?.durationSeconds, 3)

        // Already-materialized attachments are never re-pointed.
        store.attachDownloadedMedia(messageID: message.id, in: chatID, localName: "other.mov")
        stored = store.messages(in: chatID).first { $0.id == message.id }
        XCTAssertEqual(stored?.attachment?.localName, "msg-v.mov")
    }

    // MARK: Remote status ingestion

    func testIngestRemoteStatusesInsertsForAuthor() {
        let store = DataStore.inMemory()
        let author = someoneElse(store)
        let status = StatusUpdate(userID: author.id, kind: .text, text: "hello", paletteIndex: 2)

        store.ingest(remoteStatuses: [status], from: author.id)

        let stored = store.statuses.filter { $0.userID == author.id }
        XCTAssertTrue(stored.contains { $0.id == status.id && $0.text == "hello" })
    }

    func testIngestRemoteStatusesPreservesLocalViewedFlag() {
        let store = DataStore.inMemory()
        let author = someoneElse(store)
        let status = StatusUpdate(userID: author.id, kind: .text, text: "hello", paletteIndex: 0)
        store.ingest(remoteStatuses: [status], from: author.id)
        store.markStatusViewed(status.id)

        // Re-delivered snapshot (e.g. caption edit) must not reset "seen".
        var updated = status
        updated.text = "hello again"
        store.ingest(remoteStatuses: [updated], from: author.id)

        let stored = store.statuses.first { $0.id == status.id }
        XCTAssertEqual(stored?.text, "hello again")
        XCTAssertEqual(stored?.isViewed, true)
    }

    func testIngestRemoteStatusesRemovesRowsAbsentFromSnapshot() {
        let store = DataStore.inMemory()
        let author = someoneElse(store)
        let a = StatusUpdate(userID: author.id, kind: .text, text: "a", paletteIndex: 0)
        let b = StatusUpdate(userID: author.id, kind: .text, text: "b", paletteIndex: 1)
        store.ingest(remoteStatuses: [a, b], from: author.id)

        // The author deleted "a" (or it expired server-side): snapshot only has "b".
        store.ingest(remoteStatuses: [b], from: author.id)

        let stored = store.statuses.filter { $0.userID == author.id }
        XCTAssertFalse(stored.contains { $0.id == a.id })
        XCTAssertTrue(stored.contains { $0.id == b.id })
    }

    func testIngestRemoteStatusesIgnoresCurrentUser() {
        let store = DataStore.inMemory()
        let mine = store.myActiveStatuses
        let rogue = StatusUpdate(userID: store.currentUser.id, kind: .text,
                                 text: "spoofed", paletteIndex: 0)

        store.ingest(remoteStatuses: [rogue], from: store.currentUser.id)

        // Our own statuses are authored locally; a "remote" copy must change nothing.
        XCTAssertEqual(store.myActiveStatuses.map(\.id), mine.map(\.id))
    }

    func testAttachDownloadedStatusMediaFillsLocalName() {
        let store = DataStore.inMemory()
        let author = someoneElse(store)
        let status = StatusUpdate(userID: author.id, kind: .photo, text: "", paletteIndex: 0)
        store.ingest(remoteStatuses: [status], from: author.id)

        store.attachDownloadedStatusMedia(statusID: status.id, localName: "status-s.jpg")
        XCTAssertEqual(store.statuses.first { $0.id == status.id }?.localName, "status-s.jpg")
    }

    func testDeleteOwnStatusNotifiesDeleteSink() {
        let store = DataStore.inMemory()
        var deleted: [UUID] = []
        store.statusDeleteSink = { deleted.append($0) }

        let posted = store.postStatus(kind: .text, text: "bye", localName: nil, paletteIndex: 0)
        store.deleteStatus(posted.id)
        XCTAssertEqual(deleted, [posted.id])

        // Deleting someone ELSE's (locally cached) status must not touch the server.
        let author = someoneElse(store)
        let theirs = StatusUpdate(userID: author.id, kind: .text, text: "x", paletteIndex: 0)
        store.ingest(remoteStatuses: [theirs], from: author.id)
        store.deleteStatus(theirs.id)
        XCTAssertEqual(deleted, [posted.id])
    }

    func testPostStatusNotifiesStatusSink() {
        let store = DataStore.inMemory()
        var published: [StatusUpdate] = []
        store.statusSink = { published.append($0) }

        let posted = store.postStatus(kind: .text, text: "hi", localName: nil, paletteIndex: 3)
        XCTAssertEqual(published.map(\.id), [posted.id])
        XCTAssertEqual(published.first?.paletteIndex, 3)
    }
}
