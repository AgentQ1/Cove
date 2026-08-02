//
//  VoIPPushPayloadTests.swift
//  InditalkTests
//
//  Covers decoding of the APNs VoIP push body sent by the `onCallInvite` Cloud Function
//  (functions/voip.js). A payload that fails to decode means the phone never rings —
//  a failure nobody sees until someone complains they can't reach you — so the shape
//  contract between the function and the app is pinned here.
//

import XCTest
@testable import Inditalk

final class VoIPPushPayloadTests: XCTestCase {

    /// Exactly what functions/voip.js sends.
    private func serverPayload(video: Bool = false) -> [AnyHashable: Any] {
        [
            "callId": "6C7B4F94-1E0E-4C4E-9A4B-6D4C1F2A3B4C",
            "from": "firebase-uid-123",
            "caller": "Priya",
            "video": video,
        ]
    }

    func testDecodesTheCloudFunctionPayload() throws {
        let call = try XCTUnwrap(VoIPCallPayload(serverPayload(video: true)))

        XCTAssertEqual(call.callId, "6C7B4F94-1E0E-4C4E-9A4B-6D4C1F2A3B4C")
        XCTAssertEqual(call.callUUID, UUID(uuidString: "6C7B4F94-1E0E-4C4E-9A4B-6D4C1F2A3B4C"))
        XCTAssertEqual(call.fromUID, "firebase-uid-123")
        XCTAssertEqual(call.callerName, "Priya")
        XCTAssertTrue(call.isVideo)
        XCTAssertEqual(call.media, "video")
    }

    func testVoiceCallsAreTheDefault() throws {
        let call = try XCTUnwrap(VoIPCallPayload(serverPayload(video: false)))
        XCTAssertFalse(call.isVideo)
        XCTAssertEqual(call.media, "voice")

        // A payload with no `video` key at all is a voice call, not a decode failure.
        var withoutVideo = serverPayload()
        withoutVideo.removeValue(forKey: "video")
        XCTAssertEqual(VoIPCallPayload(withoutVideo)?.isVideo, false)
    }

    func testBridgedNSNumberBooleansAreUnderstood() throws {
        // APNs JSON arrives through NSJSONSerialization, so `true` is an NSNumber by
        // the time it reaches us — not a Swift Bool.
        var payload = serverPayload()
        payload["video"] = NSNumber(value: true)
        XCTAssertEqual(VoIPCallPayload(payload)?.isVideo, true)
    }

    func testCallerNameIsOptionalSoTheClientCanUseItsOwn() throws {
        var payload = serverPayload()
        payload.removeValue(forKey: "caller")
        XCTAssertNil(try XCTUnwrap(VoIPCallPayload(payload)).callerName)

        // An empty name is the same as none — CallCenter must fall back rather than
        // showing a blank caller on the lock screen.
        payload["caller"] = ""
        XCTAssertNil(try XCTUnwrap(VoIPCallPayload(payload)).callerName)
    }

    func testRejectsPayloadsCallKitCouldNotBeAddressedWith() {
        // Inditalk deliberately uses ONE id for the signaling document and the CallKit call,
        // so a callId that isn't a UUID cannot be answered, ended, or matched to the
        // Firestore call — reject it rather than ring a call nothing can control.
        var badID = serverPayload()
        badID["callId"] = "not-a-uuid"
        XCTAssertNil(VoIPCallPayload(badID))

        var missingID = serverPayload()
        missingID.removeValue(forKey: "callId")
        XCTAssertNil(VoIPCallPayload(missingID))

        var emptyID = serverPayload()
        emptyID["callId"] = ""
        XCTAssertNil(VoIPCallPayload(emptyID))
    }

    func testRejectsPayloadsWithNoCaller() {
        // Without the caller's uid there is nobody to signal back to: no ringing frame,
        // no answer, no hangup.
        var missingFrom = serverPayload()
        missingFrom.removeValue(forKey: "from")
        XCTAssertNil(VoIPCallPayload(missingFrom))

        var emptyFrom = serverPayload()
        emptyFrom["from"] = ""
        XCTAssertNil(VoIPCallPayload(emptyFrom))
    }

    func testRejectsAnEmptyPayload() {
        XCTAssertNil(VoIPCallPayload([:]))
    }
}
