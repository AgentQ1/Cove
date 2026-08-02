//
//  WebRTCMediaSession.swift
//  Inditalk
//
//  WebRTC implementation of the `CallMediaSession` hook declared in CallManager. It
//  owns the RTCPeerConnection, negotiates SDP + trickles ICE over the injected
//  SignalingChannel (Firestore), and manages audio/video tracks.
//
//  Media transport decision (see docs/PHASE4_CALLING.md): WebRTC (BSD-3, permissive)
//  via the `stasel/WebRTC` SPM binary. WebRTC mandates DTLS-SRTP, so the call's
//  audio/video is encrypted peer-to-peer; signaling metadata still transits Firestore.
//
//  ⚠️ REQUIRES the WebRTC SPM package. This file cannot compile without it and is a
//  REFERENCE implementation — not audited, not production-hardened (no bandwidth
//  adaptation, reconnection, or SFU for large group calls yet).
//

import Foundation
import AVFoundation
import WebRTC

/// Bridges a thread-safe but non-Sendable WebRTC object (e.g. RTCVideoTrack) across an
/// actor boundary. Safe here because WebRTC's media objects are usable cross-thread.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Lifecycle facts the media layer reports upward so CallCenter can drive the call
/// state machine (and the UI) off what is actually happening on the wire.
enum CallMediaEvent {
    case ringingAtPeer     // callee's device confirmed it is ringing (caller side)
    case accepted          // local user answered (callee)
    case answerReceived    // peer answered our offer (caller)
    case connected         // ICE reached connected/completed — media is flowing
    case endedByPeer       // peer sent hangup/decline/busy
    case failed            // ICE failed — the call cannot continue
}

@MainActor
final class WebRTCMediaSession: NSObject, CallMediaSession {

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let signaling: SignalingChannel
    private let callId: String
    private let selfId: String
    private let peerId: String
    private let isVideo: Bool
    private let isCaller: Bool

    private var pc: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?

    /// Offer buffered until the user actually answers — answering the SDP on arrival
    /// would start streaming the callee's microphone before they accepted the call.
    private var pendingOffer: CallSignal?
    /// Whether the local user has accepted (callee side).
    private var accepted = false
    /// Remote ICE candidates that arrived before the remote description was set —
    /// adding them early is an error and silently costs connectivity.
    private var pendingCandidates: [IceCandidate] = []
    /// Emit `.connected` only once per call.
    private var reportedConnected = false
    /// The local side already ended (suppresses a duplicate hangup signal).
    private var endedLocally = false

    /// Emits the remote video track once it arrives (for the video call view).
    var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?
    /// Emits the local camera track once capture starts (for the self-view PiP).
    var onLocalVideoTrack: ((RTCVideoTrack) -> Void)?
    /// Reports call lifecycle facts upward (see CallMediaEvent).
    var onEvent: ((CallMediaEvent) -> Void)?

    init(signaling: SignalingChannel, callId: String, selfId: String, peerId: String,
         isVideo: Bool, isCaller: Bool) {
        self.signaling = signaling
        self.callId = callId
        self.selfId = selfId
        self.peerId = peerId
        self.isVideo = isVideo
        self.isCaller = isCaller
        super.init()
        self.signaling.onSignal = { [weak self] signal in
            Task { @MainActor in self?.handle(signal) }
        }
    }

    // MARK: CallMediaSession

    func configureAudioSession() {
        // CallKit owns AVAudioSession activation. Manual-audio mode makes WebRTC wait
        // for audioSessionDidActivate (CXProvider didActivate) before starting its
        // audio unit — without this the unit races CallKit and calls connect silent.
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
        session.lockForConfiguration()
        try? session.setCategory(.playAndRecord, mode: isVideo ? .videoChat : .voiceChat,
                                 options: CallAudioRouter.categoryOptions)
        session.unlockForConfiguration()
        applyCallCategoryToWebRTCDefaults()
    }

    /// WebRTC re-applies its OWN stored configuration whenever the route changes, so the
    /// Bluetooth options have to live there too — otherwise a headset selected mid-call
    /// is dropped again the moment libwebrtc reconfigures the session.
    private func applyCallCategoryToWebRTCDefaults() {
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.mode = (isVideo ? AVAudioSession.Mode.videoChat : .voiceChat).rawValue
        config.categoryOptions = CallAudioRouter.categoryOptions
    }

    /// Audio path for platforms with no CallKit (iOS app on macOS — see
    /// CallCenter.usesCallKit). `configureAudioSession` hands the session to CallKit and
    /// waits for `audioSessionDidActivate`, which never comes there: the call would
    /// connect with WebRTC's audio unit switched off — no mic, no speaker. So take the
    /// session ourselves instead.
    func activateAudioWithoutCallKit() {
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = false
        session.lockForConfiguration()
        try? session.setCategory(.playAndRecord, mode: isVideo ? .videoChat : .voiceChat,
                                 options: CallAudioRouter.categoryOptions)
        try? session.setActive(true)
        session.unlockForConfiguration()
        session.isAudioEnabled = true
        applyCallCategoryToWebRTCDefaults()
        print("[Inditalk call] WebRTC audio started without CallKit")
    }

    func audioSessionDidActivate(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(session)
        rtc.isAudioEnabled = true
        print("[Inditalk call] WebRTC audio unit started")
    }

    func audioSessionDidDeactivate(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidDeactivate(session)
        rtc.isAudioEnabled = false
    }

    func startOutgoing(handle: String) async throws {
        await buildPeerConnectionIfNeeded()
        // Caller creates and sends the SDP offer.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await pc!.offer(for: constraints)
        try await pc!.setLocalDescription(offer)
        do {
            try await signaling.send(CallSignal(callId: callId, from: selfId, to: peerId,
                                                kind: .offer, media: media, sdp: offer.sdp))
            print("[Inditalk call] offer sent for call \(callId)")
        } catch {
            print("[Inditalk call] sending offer failed for call \(callId): \(error)")
            onEvent?(.failed)
            throw error
        }
    }

    func accept(callID: UUID) async throws {
        // Answer the buffered offer NOW — not when it arrived — so no media (mic!)
        // starts flowing before the user actually accepted the call.
        accepted = true
        print("[Inditalk call] local accept for call \(callId) (offer buffered: \(pendingOffer != nil))")
        onEvent?(.accepted)
        if let offer = pendingOffer {
            pendingOffer = nil
            await processOffer(offer)
        }
    }

    func end(callID: UUID) { end(callID: callID, kind: .hangup) }

    /// Same teardown, but says WHY it ended. A ring the user rejected from the CallKit
    /// UI is a `.decline`, not a `.hangup`: the caller's side treats both as "the peer
    /// ended it", but the distinction is the only record of what actually happened, and
    /// it is what a future "Declined" call-history row would be built on.
    func end(callID: UUID, kind: CallSignalKind) {
        // Both the in-app hang-up and the CallKit end action route here; send the
        // hangup/decline signal only once.
        guard !endedLocally else { return }
        endedLocally = true
        Task { try? await signaling.send(CallSignal(callId: callId, from: selfId, to: peerId, kind: kind)) }
        teardown()
    }

    func setMuted(_ muted: Bool, callID: UUID) {
        localAudioTrack?.isEnabled = !muted
    }

    /// Route call audio to the loudspeaker, or back to the earpiece/receiver. Anything
    /// richer (AirPods, a wired headset) goes through CallAudioRouter, which owns the
    /// full picker; this stays for the plain two-way toggle.
    func setSpeaker(_ on: Bool) {
        CallAudioRouter.shared.select(on ? .speaker : .earpiece)
    }

    func setCameraEnabled(_ on: Bool) { localVideoTrack?.isEnabled = on }

    // MARK: Signaling in

    private func handle(_ signal: CallSignal) {
        switch signal.kind {
        case .offer:
            // Buffer until the user answers via CallKit; if they already answered
            // (accept raced ahead of the offer's arrival), process immediately.
            if accepted {
                print("[Inditalk call] offer arrived after accept for call \(callId) — answering now")
                Task { await processOffer(signal) }
            } else {
                print("[Inditalk call] offer buffered for call \(callId) (\(signal.sdp?.count ?? 0)B)")
                pendingOffer = signal
            }
        case .answer:
            Task {
                guard let pc else {
                    // The answer cannot be applied without the offering peer connection,
                    // and nothing retries — so this must not be a silent `return`.
                    print("[Inditalk call] answer for call \(callId) DROPPED — no peer connection")
                    return
                }
                guard let sdp = signal.sdp else {
                    print("[Inditalk call] answer for call \(callId) DROPPED — no sdp")
                    return
                }
                do {
                    try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                    drainPendingCandidates()
                    print("[Inditalk call] answer applied for call \(callId)")
                    onEvent?(.answerReceived)
                } catch {
                    print("[Inditalk call] setRemoteDescription(answer) failed: \(error)")
                    onEvent?(.failed)
                }
            }
        case .candidate:
            if let c = signal.candidate {
                // Candidates must not be added before the remote description exists.
                if let pc, pc.remoteDescription != nil {
                    pc.add(RTCIceCandidate(sdp: c.sdp, sdpMLineIndex: c.sdpMLineIndex, sdpMid: c.sdpMid),
                           completionHandler: { _ in })
                } else {
                    pendingCandidates.append(c)
                }
            }
        case .hangup, .decline, .busy:
            // The peer already ended; there is nobody left to signal, so mark the call
            // locally ended too — CallCenter's teardown path calls end(callID:), and
            // without this it would echo a pointless hangup back.
            print("[Inditalk call] received \(signal.kind.rawValue) signal for call \(callId)")
            endedLocally = true
            teardown()
            onEvent?(.endedByPeer)
        case .ringing:
            onEvent?(.ringingAtPeer)
        }
    }

    /// Callee path: build the connection, apply the (answered) offer, reply.
    private func processOffer(_ signal: CallSignal) async {
        await buildPeerConnectionIfNeeded()
        guard let pc, let sdp = signal.sdp else { return }
        do {
            try await pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp))
            drainPendingCandidates()
            let answer = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await pc.setLocalDescription(answer)
            try await signaling.send(CallSignal(callId: callId, from: selfId, to: peerId,
                                                kind: .answer, media: media, sdp: answer.sdp))
            print("[Inditalk call] answer sent for call \(callId)")
        } catch {
            print("[Inditalk call] answering offer failed: \(error)")
            onEvent?(.failed)
        }
    }

    private func drainPendingCandidates() {
        guard let pc, pc.remoteDescription != nil else { return }
        for c in pendingCandidates {
            pc.add(RTCIceCandidate(sdp: c.sdp, sdpMLineIndex: c.sdpMLineIndex, sdpMid: c.sdpMid),
                   completionHandler: { _ in })
        }
        pendingCandidates.removeAll()
    }

    // MARK: Peer connection

    private var media: String { isVideo ? "video" : "voice" }

    /// Create this call's peer connection, once.
    ///
    /// Fetching TURN suspends, so the "do we already have one?" check is repeated after
    /// the await: a second offer arriving mid-fetch (a redelivered snapshot, or accept
    /// racing the offer) must not build a SECOND RTCPeerConnection for the same call —
    /// the first would keep its ICE agent running with nothing reading its candidates.
    private func buildPeerConnectionIfNeeded() async {
        guard pc == nil else { return }
        // Fetch TURN BEFORE constructing the connection: WebRTC snapshots `iceServers`
        // here, so a relay installed even a moment later is never used by this call.
        // Cheap in the common case (credentials cached and still valid) and bounded by
        // the callable's own timeout; if it fails we build with STUN only, which still
        // connects on most home/office networks.
        await ICEServerConfig.shared.refreshIfNeeded()
        guard pc == nil else { return }
        buildPeerConnection()
    }

    private func buildPeerConnection() {
        let config = RTCConfiguration()
        // STUN always; TURN when configured from backend-minted ephemeral credentials
        // (see ICEServerConfig — credentials are never hardcoded in the app).
        config.iceServers = ICEServerConfig.shared.iceServers()
        print("[Inditalk call] building peer connection with "
              + "\(ICEServerConfig.shared.hasTURN ? "STUN + TURN" : "STUN only") for call \(callId)")
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        addLocalMedia()
    }

    private func addLocalMedia() {
        guard let pc else { return }
        let audio = Self.factory.audioTrack(with: Self.factory.audioSource(with: nil), trackId: "audio0")
        pc.add(audio, streamIds: ["stream0"])
        localAudioTrack = audio

        if isVideo {
            let source = Self.factory.videoSource()
            let capturer = RTCCameraVideoCapturer(delegate: source)
            self.capturer = capturer
            let video = Self.factory.videoTrack(with: source, trackId: "video0")
            pc.add(video, streamIds: ["stream0"])
            localVideoTrack = video
            onLocalVideoTrack?(video)
            startCameraCapture(capturer)
        }
    }

    private func startCameraCapture(_ capturer: RTCCameraVideoCapturer) {
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front }),
              let format = RTCCameraVideoCapturer.supportedFormats(for: device).last else { return }
        let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(fps))
    }

    private func teardown() {
        capturer?.stopCapture()
        pc?.close()
        pc = nil
        // CallKit deactivates the AVAudioSession itself after the end action; just
        // stop WebRTC's audio unit (deactivating here would fight CallKit).
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCMediaSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let payload = IceCandidate(sdp: candidate.sdp, sdpMid: candidate.sdpMid,
                                   sdpMLineIndex: candidate.sdpMLineIndex)
        Task { @MainActor in
            try? await self.signaling.send(CallSignal(callId: self.callId, from: self.selfId,
                                                      to: self.peerId, kind: .candidate, candidate: payload))
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                                    streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        // WebRTC tracks are thread-safe but not Sendable; box to hand to the main actor.
        let boxed = UncheckedSendableBox(track)
        Task { @MainActor in self.onRemoteVideoTrack?(boxed.value) }
    }

    /// ICE connectivity is the ground truth for "the call is up" / "the call is lost" —
    /// report it so CallCenter can move to .active (or .failed) accordingly.
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            // Every transition, not just the two that change call state: "checking" then
            // nothing means candidates never paired (TURN/NAT), while never reaching
            // "checking" at all means the SDP exchange itself never completed.
            print("[Inditalk call] ICE state: \(Self.describe(newState)) for call \(self.callId)")
            switch newState {
            case .connected, .completed:
                if !self.reportedConnected {
                    self.reportedConnected = true
                    self.onEvent?(.connected)
                }
            case .failed:
                self.onEvent?(.failed)
            default:
                break
            }
        }
    }

    /// Readable ICE states — the raw enum logs as an integer.
    private static func describe(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    // Unused delegate callbacks (required by protocol).
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
