//
//  CallSignaling.swift
//  Inditalk
//
//  Backend-free signaling models + the SignalingChannel abstraction. WebRTC needs a
//  side channel to exchange SDP offers/answers and ICE candidates before media flows;
//  Inditalk carries those over Firestore (see FirestoreSignalingService). Keeping the
//  models and protocol here (no Firebase/WebRTC imports) means the orchestration logic
//  stays testable.
//

import Foundation

/// One signaling frame exchanged between two peers to set up / tear down a call.
enum CallSignalKind: String, Codable {
    case ringing      // callee is being alerted
    case offer        // caller SDP offer
    case answer       // callee SDP answer
    case candidate    // trickle ICE candidate
    case hangup       // either party ends
    case decline      // callee rejects
    case busy         // callee already in a call
}

/// A trickle-ICE candidate (mirrors RTCIceCandidate's transportable fields).
struct IceCandidate: Codable, Equatable {
    var sdp: String
    var sdpMid: String?
    var sdpMLineIndex: Int32
}

/// The transportable signaling envelope. `sdp` is set for offer/answer; `candidate`
/// for ICE. This is metadata (not message content) — it is NOT E2EE, but a call's
/// audio/video is separately encrypted by WebRTC's mandatory DTLS-SRTP.
struct CallSignal: Codable, Identifiable, Equatable {
    var id: String
    var callId: String
    var from: String          // sender uid
    var to: String            // recipient uid
    var kind: CallSignalKind
    var media: String         // "voice" | "video"
    var sdp: String?
    var candidate: IceCandidate?
    var createdAt: Date?

    init(id: String = UUID().uuidString, callId: String, from: String, to: String,
         kind: CallSignalKind, media: String = "voice",
         sdp: String? = nil, candidate: IceCandidate? = nil, createdAt: Date? = nil) {
        self.id = id; self.callId = callId; self.from = from; self.to = to
        self.kind = kind; self.media = media; self.sdp = sdp
        self.candidate = candidate; self.createdAt = createdAt
    }
}

/// The body of the APNs VoIP push sent by the `onCallInvite` Cloud Function
/// (functions/voip.js) when a call invite document is created.
///
/// Parsed here — away from PushKit — so the decoding rules are unit-testable: a
/// mis-parsed push means the phone never rings, which is invisible until someone can't
/// reach you. `callId` must be the signaling document id AND a valid UUID, because
/// CallKit is addressed by UUID and Inditalk deliberately uses one id for both.
struct VoIPCallPayload: Equatable, Sendable {
    var callId: String
    var callUUID: UUID
    var fromUID: String
    /// Caller's display name as the server knows it. The client prefers its own locally
    /// resolved contact name when it has one (this is the fallback for a cold launch).
    var callerName: String?
    var isVideo: Bool

    var media: String { isVideo ? "video" : "voice" }

    init?(_ dictionary: [AnyHashable: Any]) {
        guard let callId = dictionary["callId"] as? String, !callId.isEmpty,
              let callUUID = UUID(uuidString: callId),
              let fromUID = dictionary["from"] as? String, !fromUID.isEmpty else { return nil }
        self.callId = callId
        self.callUUID = callUUID
        self.fromUID = fromUID
        let name = dictionary["caller"] as? String
        self.callerName = (name?.isEmpty == false) ? name : nil
        // APNs JSON booleans arrive bridged as NSNumber; `as? Bool` handles both that
        // and a literal Bool, and anything else means voice.
        self.isVideo = (dictionary["video"] as? Bool) ?? false
    }
}

/// A transport for signaling frames. Firestore provides the concrete implementation;
/// tests provide an in-memory loopback. `@MainActor` so main-actor implementations
/// (FirestoreSignalingService) satisfy it under Swift 6 strict concurrency.
@MainActor
protocol SignalingChannel: AnyObject {
    var onSignal: ((CallSignal) -> Void)? { get set }
    func connect(callId: String, selfId: String)
    func send(_ signal: CallSignal) async throws
    func disconnect()
}
