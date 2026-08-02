//
//  CallManager.swift
//  Inditalk
//
//  CallKit + PushKit integration for native incoming-call UI and VoIP signaling.
//  This is real, compiling CallKit wiring; the media path (WebRTC peer connection)
//  is described in docs/PHASE4_CALLING.md and injected via the `mediaSession` hook.
//
//  ⚠️ Requires the "Voice over IP" background mode + a VoIP push certificate to run
//  end-to-end on device. Not production-secure until the media/signaling stack is
//  audited.
//

import Foundation
import CallKit
import PushKit
import AVFoundation
import Combine

/// Abstraction over the media/signaling backend so CallKit code is testable without
/// a live WebRTC stack. Phase 4 provides a WebRTC-backed implementation. `@MainActor`
/// so the main-actor WebRTCMediaSession satisfies it under Swift 6 strict concurrency.
@MainActor
protocol CallMediaSession: AnyObject {
    func configureAudioSession()
    func startOutgoing(handle: String) async throws
    func accept(callID: UUID) async throws
    func end(callID: UUID)
    func setMuted(_ muted: Bool, callID: UUID)
    /// CallKit activated/deactivated the AVAudioSession. WebRTC must start/stop its
    /// audio unit on exactly these — starting earlier races CallKit's activation and
    /// is the classic "call connects but nobody hears anything" failure.
    func audioSessionDidActivate(_ session: AVAudioSession)
    func audioSessionDidDeactivate(_ session: AVAudioSession)
}

extension CallMediaSession {
    func audioSessionDidActivate(_ session: AVAudioSession) {}
    func audioSessionDidDeactivate(_ session: AVAudioSession) {}
}

@MainActor
final class CallManager: NSObject, ObservableObject {

    static let shared = CallManager()

    @Published private(set) var activeCallID: UUID?

    private let provider: CXProvider
    private let callController = CXCallController()
    weak var mediaSession: CallMediaSession?

    /// Fired when CallKit performs an end action (user hung up / declined from the
    /// NATIVE UI — lock screen, banner) so the in-app call state can end + dismiss too.
    var onSystemEnd: (() -> Void)?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        // config.iconTemplateImageData = ...  // Inditalk's own monochrome glyph
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: Outgoing

    /// `callID` MUST be the signaling call id (CallCenter mints one UUID for both), so
    /// ending the call later addresses the same CallKit call — a mismatched id makes
    /// CXEndCallAction fail and leaves the system call UI alive with no way to cut it.
    func startCall(callID: UUID, to handle: String, video: Bool) {
        activeCallID = callID
        let cxHandle = CXHandle(type: .generic, value: handle)
        let action = CXStartCallAction(call: callID, handle: cxHandle)
        action.isVideo = video
        callController.request(CXTransaction(action: action)) { error in
            if let error { print("[Inditalk call] startCall error: \(error)") }
        }
    }

    // MARK: Incoming (called from PushKit VoIP push)

    /// iOS requires reporting an incoming call to CallKit *immediately* on receiving a
    /// VoIP push, or the app is terminated. Signaling details are decrypted here.
    /// `completion` receives whether CallKit accepted the report, so the caller can
    /// clean up call state when it didn't (otherwise the app stays "busy" forever).
    func reportIncoming(callID: UUID, from displayName: String, video: Bool,
                        completion: @escaping (Bool) -> Void = { _ in }) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: displayName)
        update.hasVideo = video
        update.localizedCallerName = displayName
        let box = UncheckedSendableBox(completion)
        provider.reportNewIncomingCall(with: callID, update: update) { [weak self] error in
            Task { @MainActor in
                if let error { print("[Inditalk call] reportIncoming failed: \(error)") }
                if error == nil { self?.activeCallID = callID }
                box.value(error == nil)
            }
        }
    }

    /// Report an incoming call and immediately retire it.
    ///
    /// PushKit's contract is absolute: EVERY VoIP push must produce a
    /// `reportNewIncomingCall` before the delegate returns, or iOS terminates the app —
    /// and repeat offenders stop receiving VoIP pushes at all. So when Inditalk decides not
    /// to ring (already in a call, blocked caller, signed out, malformed payload) it
    /// still has to report, then end the call itself. `reason` decides how the system
    /// logs it (missed vs. declined).
    func reportIncomingThenEnd(callID: UUID, from displayName: String, video: Bool,
                               reason: CXCallEndedReason,
                               completion: @escaping (Bool) -> Void = { _ in }) {
        reportIncoming(callID: callID, from: displayName, video: video) { [weak self] reported in
            if reported { self?.provider.reportCall(with: callID, endedAt: nil, reason: reason) }
            completion(false)
        }
    }

    func endCall(_ callID: UUID) {
        let action = CXEndCallAction(call: callID)
        callController.request(CXTransaction(action: action)) { _ in }
    }

    /// Media connected — flip the system call UI/timer from "connecting" to live.
    func reportConnected(_ callID: UUID) {
        provider.reportOutgoingCall(with: callID, connectedAt: nil)
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            // The system dropped every call this provider owns. Seeing this seconds into
            // a call means CallKit itself is unavailable/unhappy — not the media stack.
            print("[Inditalk call] CallKit provider RESET — all calls torn down by the system")
            self.activeCallID = nil
        }
    }

    /// A CallKit action must be fulfilled PROMPTLY. The system gives each transaction a
    /// few seconds and then, if it hasn't been fulfilled, times it out and tears the call
    /// down — which arrives here as an end action while the call is still "dialing".
    /// SDP negotiation is far too slow to sit inside an action: it awaits a TURN fetch
    /// (up to 8s) and a Firestore round trip for the offer/answer. So both handlers below
    /// configure audio, fulfill, and only THEN negotiate.
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let box = UncheckedSendableBox((provider, action))
        Task { @MainActor in
            let (provider, action) = box.value
            self.mediaSession?.configureAudioSession()
            // Only "started connecting" here — connectedAt is reported when ICE is
            // actually up (CallCenter → reportConnected), so the system timer is honest.
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            action.fulfill()
            let started = Date()
            do {
                try await self.mediaSession?.startOutgoing(handle: action.handle.value)
            } catch {
                print("[Inditalk call] startOutgoing failed: \(error)")
            }
            print(String(format: "[Inditalk call] offer negotiation took %.2fs "
                         + "(would have held the CallKit start action open that long)",
                         Date().timeIntervalSince(started)))
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let box = UncheckedSendableBox(action)
        Task { @MainActor in
            let action = box.value
            self.mediaSession?.configureAudioSession()
            action.fulfill()
            let started = Date()
            do {
                try await self.mediaSession?.accept(callID: action.callUUID)
            } catch {
                print("[Inditalk call] accept failed: \(error)")
            }
            print(String(format: "[Inditalk call] answer negotiation took %.2fs "
                         + "(would have held the CallKit answer action open that long)",
                         Date().timeIntervalSince(started)))
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let box = UncheckedSendableBox(action)
        Task { @MainActor in
            let action = box.value
            // Logged because CallKit performs this action itself when a transaction times
            // out — an "end" nobody in the app asked for.
            print("[Inditalk call] CallKit end action for \(action.callUUID)")
            self.mediaSession?.end(callID: action.callUUID)
            self.activeCallID = nil
            action.fulfill()
            self.onSystemEnd?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let box = UncheckedSendableBox(action)
        Task { @MainActor in
            let action = box.value
            self.mediaSession?.setMuted(action.isMuted, callID: action.callUUID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let box = UncheckedSendableBox(audioSession)
        Task { @MainActor in
            print("[Inditalk call] CallKit activated the audio session")
            self.mediaSession?.audioSessionDidActivate(box.value)
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let box = UncheckedSendableBox(audioSession)
        Task { @MainActor in
            print("[Inditalk call] CallKit deactivated the audio session")
            self.mediaSession?.audioSessionDidDeactivate(box.value)
        }
    }
}

// MARK: - PushKit VoIP push registration

/// Receives APNs VoIP pushes and turns them into ringing calls.
///
/// This is what makes Inditalk ring when it is BACKGROUNDED, locked, or not running at all:
/// the Firestore incoming-call listener (CallCenter.startListening) only survives while
/// the app is in the foreground, so on its own a callee never hears a locked phone ring.
/// A VoIP push wakes — or launches — the process, and the handler reports the call to
/// CallKit, which is what actually rings the device.
///
/// A singleton because PKPushRegistry only retains its delegate weakly: a handler
/// created and dropped at launch stops receiving pushes with no error anywhere.
@MainActor
final class VoIPPushHandler: NSObject, PKPushRegistryDelegate {
    static let shared = VoIPPushHandler()

    /// `queue: nil` == the main queue. That matters: `didReceiveIncomingPush` must
    /// report to CallKit synchronously (see below), which is only safe to do from the
    /// main actor without an intervening hop.
    private let registry = PKPushRegistry(queue: nil)

    func register() {
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    /// Send this token to Inditalk's backend so it can address VoIP pushes. PushKit issues
    /// it once per process — typically BEFORE sign-in — so PushService caches it and
    /// publishes (or re-publishes) it as soon as there is a signed-in user to store it
    /// against.
    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            print("[Inditalk call] VoIP push token registered (\(token.count / 2) bytes)")
            PushService.shared.setVoIPToken(token)
        }
    }

    /// The token was revoked (app reinstalled, restored to a new device). Drop the
    /// server's copy so the backend stops pushing into the void.
    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        MainActor.assumeIsolated {
            print("[Inditalk call] VoIP push token invalidated")
            PushService.shared.setVoIPToken(nil)
        }
    }

    /// A VoIP push arrived — we MUST report an incoming call to CallKit before this
    /// method returns, or iOS terminates the app (and eventually stops delivering VoIP
    /// pushes to it entirely). PushKit delivers on the main queue here, so assume the
    /// isolation and report inline: hopping through `Task { @MainActor in … }` would
    /// return from this method *first* and run the report a turn later, which is
    /// precisely the violation iOS punishes.
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType, completion: @escaping () -> Void) {
        // Decode before the isolation hop: PKPushPayload isn't Sendable, VoIPCallPayload
        // is. `completion` is boxed for the same reason (the same pattern the CallKit
        // delegate callbacks above use).
        let call = VoIPCallPayload(payload.dictionaryPayload)
        let raw = String(describing: payload.dictionaryPayload)
        let done = UncheckedSendableBox(completion)
        MainActor.assumeIsolated {
            guard let call else {
                // An unparseable payload still owes CallKit a report. Ring nothing, but
                // report-and-retire so the process survives to receive the next push.
                print("[Inditalk call] malformed VoIP payload: \(raw)")
                CallManager.shared.reportIncomingThenEnd(
                    callID: UUID(), from: "Inditalk user", video: false, reason: .failed
                ) { _ in done.value() }
                return
            }
            CallCenter.shared.receiveIncomingFromPush(call) { _ in done.value() }
        }
    }
}
