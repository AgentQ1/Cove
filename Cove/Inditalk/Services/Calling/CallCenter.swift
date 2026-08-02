//
//  CallCenter.swift
//  Inditalk
//
//  Orchestrates a call end-to-end: CallKit (native UI) + Firestore signaling + the
//  WebRTC media session. This is the glue that connects the three verified/reference
//  pieces; the *decision* logic (legal transitions) lives in CallSessionMachine.
//
//  Outgoing:  placeCall → CallKit start → offer over signaling → answer → media
//  Incoming:  VoIP push / Firestore listener → CallKit reportIncoming → answer → media
//
//  ⚠️ REQUIRES the Firebase + WebRTC SPM packages. Reference orchestration — the call
//  stack is not production-secure until independently audited (docs/PHASE4_CALLING.md).
//

import Foundation
import CallKit
import FirebaseAuth
import FirebaseFirestore
import WebRTC

@MainActor
final class CallCenter: ObservableObject {
    static let shared = CallCenter()

    @Published private(set) var state: CallState = .idle
    @Published private(set) var activePeerName: String?
    @Published private(set) var isVideoCall = false
    @Published private(set) var isMuted = false
    @Published private(set) var isCameraOn = true
    /// Loudspeaker vs earpiece. Video calls start on the speaker (you're not holding the
    /// phone to your ear); voice calls start on the receiver, like the system dialer.
    @Published private(set) var isSpeakerOn = false
    /// The callee's device confirmed it is ringing ("Ringing…" instead of "Calling…").
    @Published private(set) var peerRinging = false
    /// When media connected (drives the in-call duration timer; nil = not connected).
    @Published private(set) var connectedSince: Date?

    /// Live media tracks for the call UI to render (nil until they arrive).
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var localVideoTrack: RTCVideoTrack?

    private let callKit = CallManager.shared
    /// Tracks and switches the audio output device for the duration of a call.
    let audioRouter = CallAudioRouter.shared
    private var signaling: FirestoreSignalingService?
    private var media: WebRTCMediaSession?
    private var incomingListener: ListenerRegistration?
    private var currentCallId: String?
    /// Ends a call nobody answers (cancelled on connect/teardown).
    private var ringTimeoutTask: Task<Void, Never>?
    /// Delayed post-"Call ended" cleanup. MUST be tracked so a new call can cancel it —
    /// an orphaned one fired mid-call and silently destroyed the next call's session.
    private var cleanupTask: Task<Void, Never>?
    /// Teardown has begun for the current call. Guards finishCall against re-entry:
    /// our own programmatic CXEndCallAction echoes back through onSystemEnd, and
    /// without this the echo cut the "Call ended" display to a single frame.
    private var finishing = false

    // Facts for the history record written at teardown.
    private var callStartedAt: Date?
    private var callWasOutgoing = false
    private var callPeerUID: String?

    private init() {
        // Hang-ups from the native CallKit UI must also close the in-app call state.
        callKit.onSystemEnd = { [weak self] in self?.systemEnded() }
    }

    /// Resolves whether an incoming caller's Firebase uid is blocked by the local user.
    /// Injected by the app (FirebaseSyncCoordinator) so this call layer can consult the
    /// local block list without importing the data store. Blocked callers never ring.
    var isPeerBlocked: ((String) -> Bool)?

    /// Resolves an incoming caller's Firebase uid to their display name (injected the
    /// same way) — without it, the native call UI shows the raw uid string.
    var resolvePeerName: ((String) -> String?)?

    /// Receives the finished call's history record plus the peer's Firebase uid so the
    /// app layer can resolve the chat and persist it (Calls tab "Recent"). Injected by
    /// FirebaseSyncCoordinator; without it real calls never appear in call history.
    var onCallEnded: ((CallRecord, String?) -> Void)?

    /// Ringing call docs older than this are leftovers of past calls, not live rings.
    private static let staleRingSeconds: TimeInterval = 60

    /// Whether CallKit can carry this call.
    ///
    /// On iPhone/iPad CallKit owns the ring UI AND drives the media — `startOutgoing` /
    /// `accept` run inside CXStartCallAction / CXAnswerCallAction. Running as an iOS app
    /// on macOS there is no telephony stack behind CallKit: the system performs the start
    /// action, then ends the call a second or two later, taking the media with it (the
    /// call dies in `dialing`, before the callee can answer). Native Mac calling apps
    /// don't use CallKit at all — they present their own call window — so on that
    /// platform Inditalk drives the media itself and uses the in-app call screen.
    static let usesCallKit = !ProcessInfo.processInfo.isiOSAppOnMac

    private var uid: String? { Auth.auth().currentUser?.uid }

    // MARK: Incoming registration

    /// Begin listening for incoming calls (foreground path; VoIP push covers background).
    func startListening() {
        guard AppConfig.usesFirebase, let uid else { return }
        incomingListener = FirestoreSignalingService.listenForIncoming(uid: uid) { [weak self] callId, fromUID, media, createdAt in
            self?.receiveIncoming(callId: callId, fromUID: fromUID, media: media, createdAt: createdAt)
        }
    }

    func stopListening() { incomingListener?.remove(); incomingListener = nil }

    // MARK: Outgoing

    func placeCall(to peerUID: String, peerName: String, video: Bool) {
        guard let uid else { return }
        // A finished call must never block or bleed into a new one.
        if CallSessionMachine.isTerminal(state) || (state != .idle && currentCallId == nil) {
            cleanup()
        }
        guard currentCallId == nil else {
            print("[Inditalk call] placeCall ignored — already in call \(currentCallId ?? "?")")
            return
        }

        // ONE id for the whole call: the Firestore signaling doc AND the CallKit call.
        // (Mismatched ids made CXEndCallAction fail, leaving the system UI un-endable.)
        let callUUID = UUID()
        let callId = callUUID.uuidString
        currentCallId = callId
        activePeerName = peerName
        isVideoCall = video
        isSpeakerOn = video
        callWasOutgoing = true
        callPeerUID = peerUID
        callStartedAt = Date()
        print("[Inditalk call] placing \(video ? "video" : "voice") call \(callId) to \(peerUID)")
        transition(.dialing)

        let signaling = FirestoreSignalingService()
        self.signaling = signaling

        let media = WebRTCMediaSession(signaling: signaling, callId: callId, selfId: uid,
                                       peerId: peerUID, isVideo: video, isCaller: true)
        wireTracks(media)
        self.media = media
        callKit.mediaSession = media

        Task {
            // The call DOCUMENT must exist before the signals listener attaches: the
            // signals read rule get()s calls/{callId}, and a listener denied against a
            // missing parent doc is dead for good (Firestore never retries a denied
            // listen). Connecting first left the caller deaf to the callee's answer —
            // the call rang, then died when the callee's ICE went unanswered.
            do {
                try await signaling.upsertCallDoc(callId: callId, from: uid, to: peerUID,
                                                  media: video ? "video" : "voice", state: "ringing")
            } catch {
                print("[Inditalk call] could not create call doc \(callId): \(error)")
                ToastCenter.shared.show("Couldn't start the call — check your connection.", pending: false)
                transition(.failed)
                finishCall(after: 1.0)
                return
            }
            signaling.connect(callId: callId, selfId: uid)
            if Self.usesCallKit {
                // CallKit fires CXStartCallAction → CallManager calls media.startOutgoing()
                // which creates + sends the SDP offer over signaling.
                callKit.startCall(callID: callUUID, to: peerName, video: video)
            } else {
                // No CallKit here (see `usesCallKit`) — nothing would ever call
                // startOutgoing, so drive the offer ourselves.
                print("[Inditalk call] CallKit unavailable on this platform — driving media directly")
                media.activateAudioWithoutCallKit()
                do {
                    try await media.startOutgoing(handle: peerName)
                } catch {
                    print("[Inditalk call] startOutgoing failed for call \(callId): \(error)")
                    transition(.failed)
                    finishCall(after: 1.2)
                    return
                }
            }
            startUnansweredTimeout(for: callId)
        }
    }

    /// End a call nobody answers instead of ringing forever: after the same interval
    /// that makes a call doc stale (60s) with still no media connection, tear down —
    /// which also signals the peer and marks the doc ended. On the callee this covers
    /// a caller that vanished (killed app) without sending a hangup.
    private func startUnansweredTimeout(for callId: String) {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.staleRingSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.currentCallId == callId else { return }
            guard self.state == .dialing || self.state == .connecting || self.state == .ringing else { return }
            print("[Inditalk call] call \(callId) unanswered after \(Int(Self.staleRingSeconds))s — ending (state \(self.state.rawValue))")
            if self.state == .ringing {
                finishCall()                     // just stop the native ring; no in-app screen
            } else {
                transition(.ended)
                finishCall(after: 0.9)           // brief "Call ended" on the caller side
            }
        }
    }

    // MARK: Incoming

    /// Foreground path: the Firestore incoming-call listener saw a new ringing document.
    private func receiveIncoming(callId: String, fromUID: String, media mediaKind: String, createdAt: Date?) {
        // Old "ringing" docs (a crash, a missed cleanup) must not re-ring on launch.
        // Only this path needs the check — a VoIP push is live by construction.
        if let createdAt, Date().timeIntervalSince(createdAt) > Self.staleRingSeconds {
            print("[Inditalk call] ignoring stale ringing call \(callId) from \(createdAt)")
            return
        }
        presentIncoming(callId: callId, fromUID: fromUID, media: mediaKind, callerName: nil)
    }

    /// Background / locked / cold-launch path: an APNs VoIP push woke the app.
    ///
    /// `completion` MUST run once CallKit has been told about the call — PushKit keeps
    /// the process alive until then, and iOS treats "never completed" the same as
    /// "never reported": app terminated, and eventually no more VoIP pushes at all.
    func receiveIncomingFromPush(_ push: VoIPCallPayload, completion: @escaping (Bool) -> Void) {
        print("[Inditalk call] VoIP push for \(push.media) call \(push.callId) from \(push.fromUID)")
        // Foregrounded, the Firestore listener may have reported this very call already.
        // Re-report the SAME id rather than treating it as a second call: CallKit
        // rejects the duplicate harmlessly and PushKit's report contract is satisfied.
        if currentCallId == push.callId {
            print("[Inditalk call] call \(push.callId) is already ringing — push is a duplicate")
            callKit.reportIncoming(callID: push.callUUID,
                                   from: activePeerName ?? push.callerName ?? "Inditalk user",
                                   video: push.isVideo) { _ in completion(true) }
            return
        }
        presentIncoming(callId: push.callId, fromUID: push.fromUID, media: push.media,
                        callerName: push.callerName, fromPush: true, completion: completion)
    }

    /// Shared incoming setup for both paths: attach signaling, build the media session,
    /// tell the caller we're ringing, and hand the call to CallKit.
    private func presentIncoming(callId: String, fromUID: String, media mediaKind: String,
                                 callerName: String?, fromPush: Bool = false,
                                 completion: @escaping (Bool) -> Void = { _ in }) {
        let video = mediaKind == "video"
        let callUUID = UUID(uuidString: callId) ?? UUID()

        /// Decline to ring. The foreground path can just walk away; a VoIP push still
        /// owes CallKit a report, so it reports and immediately retires the call.
        func refuse(_ why: String, reason: CXCallEndedReason) {
            print("[Inditalk call] not ringing for \(callId): \(why)")
            guard fromPush else { completion(false); return }
            callKit.reportIncomingThenEnd(callID: callUUID, from: callerName ?? "Inditalk user",
                                          video: video, reason: reason) { _ in completion(false) }
        }

        guard let uid else { return refuse("no signed-in user", reason: .failed) }
        // A finished call lingering through its "Call ended" display must not swallow
        // a fresh incoming ring — clear it and take the new call.
        if CallSessionMachine.isTerminal(state) || (state != .idle && currentCallId == nil) {
            cleanup()
        }
        guard currentCallId == nil else {
            return refuse("busy in call \(currentCallId ?? "?")", reason: .unanswered)
        }
        // Blocked callers must not ring the user (UGC block enforcement). The
        // `onCallInvite` function performs the same check before sending a VoIP push —
        // it has to, because this hook is unset until the sync coordinator starts, which
        // a push-launched app may not have done yet.
        if isPeerBlocked?(fromUID) == true {
            return refuse("caller \(fromUID) is blocked", reason: .declinedElsewhere)
        }
        currentCallId = callId
        isVideoCall = video
        isSpeakerOn = video
        // Prefer the locally resolved contact name; the push's copy is the cold-launch
        // fallback for when the store hasn't been loaded yet.
        let peerName = resolvePeerName?(fromUID) ?? callerName ?? "Inditalk user"
        activePeerName = peerName
        callWasOutgoing = false
        callPeerUID = fromUID
        callStartedAt = Date()
        print("[Inditalk call] incoming \(mediaKind) call \(callId) from \(fromUID)")
        transition(.ringing)

        let signaling = FirestoreSignalingService()
        self.signaling = signaling

        // The media session MUST exist before the listener attaches: its init is what
        // installs `signaling.onSignal`, and the caller's offer is usually already
        // sitting in the collection, so it arrives in the listener's very first
        // snapshot. Connecting first left a window in which that offer had nowhere to
        // go — the callee rang, then answered with `offer buffered: false`. (The
        // service also buffers signals that predate the handler; this ordering means it
        // never has to.)
        let media = WebRTCMediaSession(signaling: signaling, callId: callId, selfId: uid,
                                       peerId: fromUID, isVideo: video, isCaller: false)
        wireTracks(media)
        self.media = media
        callKit.mediaSession = media

        signaling.connect(callId: callId, selfId: uid)

        // Tell the caller this device is ringing, so their screen can say "Ringing…".
        Task {
            do {
                try await signaling.send(CallSignal(callId: callId, from: uid, to: fromUID,
                                                    kind: .ringing, media: mediaKind))
            } catch {
                // Was `try?`. This is the FIRST write this device makes to the signals
                // subcollection, so it is also the first thing a rules problem breaks —
                // worth a line rather than a silent shrug.
                print("[Inditalk call] sending ringing for call \(callId) failed: \(error)")
            }
        }
        // Ask for mic (and camera) WHILE the incoming UI shows — the accept path never
        // prompts, so a first-ever call answered without this ran with a dead mic.
        Task {
            _ = await PermissionsManager.shared.requestMicrophone()
            if video { _ = await PermissionsManager.shared.requestCamera() }
        }
        // A caller that vanished without a hangup must not ring this device forever.
        startUnansweredTimeout(for: callId)

        // Without CallKit (see `usesCallKit`) there is no native incoming UI to report to
        // and no CXAnswerCallAction to drive `accept` — the in-app call screen shows the
        // ring instead and calls `answer()` / `decline()` below. Foreground only, which is
        // all the platform supports anyway: VoIP pushes don't reach it.
        guard Self.usesCallKit else {
            print("[Inditalk call] CallKit unavailable on this platform — ringing in-app")
            completion(true)
            return
        }

        // Report to CallKit → native incoming UI, on the lock screen too when a VoIP
        // push got us here. Answering runs CallManager's CXAnswerCallAction, which calls
        // media.accept() → the buffered offer is answered and the WebRTC/Firestore flow
        // continues exactly as in the foreground case. Declining runs CXEndCallAction →
        // media.end(kind: .decline) + the call doc marked "ended" (see systemEnded).
        callKit.reportIncoming(callID: callUUID, from: peerName, video: video) { [weak self] reported in
            // If CallKit refused the call, the app must not stay "busy" forever.
            if !reported { self?.cleanup() }
            completion(reported)
        }
    }

    // MARK: In-app answer / decline (no-CallKit platforms)

    /// Accept a ringing call from Inditalk's own incoming screen. On iOS this path is unused —
    /// CallKit's answer action drives `accept` instead.
    func answer() {
        guard state == .ringing, let media else { return }
        print("[Inditalk call] in-app answer for call \(currentCallId ?? "?")")
        media.activateAudioWithoutCallKit()
        Task {
            do {
                try await media.accept(callID: UUID())
            } catch {
                print("[Inditalk call] accept failed for call \(currentCallId ?? "?"): \(error)")
                transition(.failed)
                finishCall(after: 1.2)
            }
        }
    }

    /// Reject a ringing call from Inditalk's own incoming screen (CallKit's decline equivalent).
    func decline() {
        guard state == .ringing else { return }
        print("[Inditalk call] in-app decline for call \(currentCallId ?? "?")")
        transition(.ended)
        finishCall(after: 0.3, declined: true)
    }

    // MARK: Controls

    func toggleMute() {
        isMuted.toggle()
        media?.setMuted(isMuted, callID: UUID())
    }

    func toggleCamera() {
        isCameraOn.toggle()
        media?.setCameraEnabled(isCameraOn)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        media?.setSpeaker(isSpeakerOn)
    }

    /// Send call audio to a specific device (AirPods, a wired headset, the loudspeaker,
    /// the earpiece). The route list itself lives on CallAudioRouter, which the call
    /// screen observes so it follows headsets connecting mid-call.
    func selectAudioRoute(_ route: CallAudioRoute) {
        audioRouter.select(route)
        isSpeakerOn = route.kind == .speaker
    }

    /// Called by the media/signaling layer once the peer connection is up.
    func markConnected() { transition(.active) }

    private func wireTracks(_ media: WebRTCMediaSession) {
        media.onRemoteVideoTrack = { [weak self] track in self?.remoteVideoTrack = track }
        media.onLocalVideoTrack = { [weak self] track in self?.localVideoTrack = track }
        media.onEvent = { [weak self] event in self?.handleMediaEvent(event) }
    }

    /// Drive the call state machine from what the media/signaling layer reports —
    /// without this the UI is frozen in "Calling…" no matter what happens on the wire.
    private func handleMediaEvent(_ event: CallMediaEvent) {
        switch event {
        case .ringingAtPeer:
            print("[Inditalk call] peer device is ringing (call \(currentCallId ?? "?"))")
            peerRinging = true
        case .accepted, .answerReceived:
            peerRinging = false
            transition(.connecting)
        case .connected:
            ringTimeoutTask?.cancel(); ringTimeoutTask = nil
            peerRinging = false
            connectedSince = Date()
            // Start tracking outputs now: before the audio session is live there is no
            // route to read, and an override has nothing to act on. A headset already
            // connected keeps the audio — only fall back to the default when there is
            // nothing better than the built-in outputs.
            audioRouter.start()
            if audioRouter.hasExternalRoutes {
                isSpeakerOn = audioRouter.current.kind == .speaker
            } else {
                media?.setSpeaker(isSpeakerOn)
            }
            // CallKit's outgoing leg was reported "started connecting" at dial time;
            // report connected now so the system call timer matches reality.
            if callWasOutgoing, let id = currentCallId, let cid = UUID(uuidString: id) {
                callKit.reportConnected(cid)
            }
            transition(.active)
        case .endedByPeer:
            print("[Inditalk call] peer ended call \(currentCallId ?? "?") in state \(state.rawValue)")
            if state == .ringing {
                // Caller cancelled before we answered: a missed call, not an ended one.
                // Stop the native ring without ever presenting the in-app call screen.
                finishCall()
            } else {
                transition(.ended)
                finishCall(after: 1.0)      // let "Call ended" read before dismissing
            }
        case .failed:
            print("[Inditalk call] media failed for call \(currentCallId ?? "?")")
            transition(.failed)
            finishCall(after: 1.2)
        }
    }

    // MARK: Teardown

    /// The user hung up from the in-app call screen.
    func hangUp() {
        print("[Inditalk call] local hangup for call \(currentCallId ?? "?") in state \(state.rawValue)")
        transition(.ended)
        finishCall(after: 0.6)              // brief "Call ended" beat, like the peer sees
    }

    /// The user ended/declined from the NATIVE CallKit UI — CallKit already performed
    /// the end action and media.end was called; only the in-app state remains to close.
    /// Also re-entered by our OWN programmatic CXEndCallAction (finishCall → endCall →
    /// this delegate); `finishing` makes that echo a no-op instead of letting it cut
    /// the "Call ended" display to a single frame.
    private func systemEnded() {
        guard currentCallId != nil, !finishing else { return }
        print("[Inditalk call] system UI ended call \(currentCallId ?? "?") in state \(state.rawValue)")
        let neverAccepted = state == .ringing
        transition(.ended)
        // Declining a ring must not flash the in-app call screen at all — cleanup runs
        // synchronously, so SwiftUI never sees the intermediate .ended state.
        finishCall(after: neverAccepted ? 0 : 0.6, endCallKit: false, declined: neverAccepted)
    }

    /// Common end-of-call path: release the CallKit call, mark the call doc ended so
    /// it can never re-ring, log history, then reset so the NEXT call starts from idle.
    /// Idempotent per call via `finishing`.
    private func finishCall(after delay: TimeInterval = 0, endCallKit: Bool = true,
                            declined: Bool = false) {
        guard !finishing else { return }
        finishing = true
        ringTimeoutTask?.cancel(); ringTimeoutTask = nil
        // Every termination path (including ICE failure) must tell the peer, or their
        // side rings/hangs forever. WebRTCMediaSession sends the hangup at most once,
        // and skips it entirely when the PEER ended (no echo). A ring rejected from the
        // CallKit UI is signaled as a decline rather than a hangup.
        media?.end(callID: UUID(), kind: declined ? .decline : .hangup)
        if endCallKit, Self.usesCallKit, let id = currentCallId,
           let cid = UUID(uuidString: id) { callKit.endCall(cid) }
        if let id = currentCallId, let signaling {
            Task { try? await signaling.updateCallState(callId: id, state: "ended") }
        }
        logHistory()
        if delay > 0 {
            let id = currentCallId
            cleanupTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, self.currentCallId == id else { return }
                self.cleanup()
            }
        } else {
            cleanup()
        }
    }

    /// One history row per call, written at teardown on both ends. Direction mirrors
    /// the product reference: outgoing logs outgoing (answered or not); incoming logs
    /// missed unless it actually connected.
    private func logHistory() {
        guard currentCallId != nil, let onCallEnded else { return }
        let duration = connectedSince.map { Int(Date().timeIntervalSince($0)) }
        let direction: CallDirection = callWasOutgoing ? .outgoing
                                     : (duration != nil ? .incoming : .missed)
        let record = CallRecord(displayName: activePeerName ?? "Inditalk user",
                                direction: direction,
                                media: isVideoCall ? .video : .voice,
                                date: callStartedAt ?? Date(),
                                durationSeconds: duration)
        print("[Inditalk call] history: \(direction.rawValue) \(record.media.rawValue) "
              + "call, duration \(duration.map(String.init) ?? "—")s")
        onCallEnded(record, callPeerUID)
    }

    private func cleanup() {
        audioRouter.stop()
        ringTimeoutTask?.cancel(); ringTimeoutTask = nil
        cleanupTask?.cancel(); cleanupTask = nil
        signaling?.disconnect()
        signaling = nil; media = nil; currentCallId = nil; activePeerName = nil
        remoteVideoTrack = nil; localVideoTrack = nil
        isMuted = false; isCameraOn = true; isVideoCall = false; isSpeakerOn = false
        peerRinging = false; connectedSince = nil; finishing = false
        callStartedAt = nil; callWasOutgoing = false; callPeerUID = nil
        // The machine treats ended/failed as final for a CALL; the CENTER must return
        // to idle between calls or every later call is born dead showing "Call ended".
        state = .idle
    }

    private func transition(_ event: CallState) {
        let previous = state
        state = CallSessionMachine.apply(event, to: state)
        if previous != state {
            print("[Inditalk call] state \(previous.rawValue) -> \(state.rawValue) "
                  + "(call \(currentCallId ?? "none"))")
        }
        // activePeerName survives into ended/failed so the "Call ended" screen still
        // shows who the call was with; cleanup clears it.
    }
}

// MARK: - CallLauncher

/// Shared entry point for placing a REAL call from anywhere in the app (chat header,
/// Calls tab, favorites, keypad, call-back). Resolves the peer's Firebase uid, takes
/// the permissions iOS requires, then hands off to CallCenter — the screens must never
/// fall back to a screen that only LOOKS like a call while the peer hears nothing.
@MainActor
enum CallLauncher {

    /// Call the other participant of a direct chat.
    static func call(chatID: UUID?, video: Bool, store: DataStore) {
        guard let chatID, let chat = store.chat(chatID) else {
            ToastCenter.shared.show("Couldn't find who to call", pending: false)
            return
        }
        // Calls are 1:1 only, and nothing in the UI offers a group as a call target, so a
        // non-direct chat has no single peer to dial — the same failure as an unresolvable one.
        guard chat.kind == .direct,
              let peer = chat.participantIDs.first(where: { $0 != store.currentUser.id })
                .flatMap({ store.users[$0] }) else {
            ToastCenter.shared.show("Couldn't find who to call", pending: false)
            return
        }
        call(user: peer, video: video, store: store)
    }

    /// Call a specific contact.
    static func call(user: InditalkUser, video: Bool, store: DataStore) {
        guard !store.isBlocked(user.id) else {
            ToastCenter.shared.show("You blocked this contact. Unblock to call.", pending: false)
            return
        }
        guard let uid = user.remoteUID, !uid.isEmpty else {
            ToastCenter.shared.show("\(user.displayName) isn't on Inditalk yet", pending: false)
            return
        }
        Task {
            guard await PermissionsManager.shared.requestMicrophone() else {
                ToastCenter.shared.show("Microphone access is off — enable it in Settings", pending: false)
                return
            }
            if video, await PermissionsManager.shared.requestCamera() == false {
                ToastCenter.shared.show("Camera access is off — enable it in Settings", pending: false)
                return
            }
            Haptics.impact(.light)
            CallCenter.shared.placeCall(to: uid, peerName: user.displayName, video: video)
        }
    }
}
