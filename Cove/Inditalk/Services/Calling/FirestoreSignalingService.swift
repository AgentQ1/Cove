//
//  FirestoreSignalingService.swift
//  Inditalk
//
//  SignalingChannel over Firestore. SDP offers/answers and ICE candidates are written
//  as documents under calls/{callId}/signals and delivered to the peer via a snapshot
//  listener. This is the low-latency side channel WebRTC needs before media connects.
//
//  Firestore layout:
//    calls/{callId}                 { from, to, media, state, createdAt }
//    calls/{callId}/signals/{id}    CallSignal (offer|answer|candidate|hangup|…)
//
//  REQUIRES the FirebaseFirestore SPM package.
//

import Foundation
import FirebaseFirestore

@MainActor
final class FirestoreSignalingService: SignalingChannel {
    /// Installed by WebRTCMediaSession's init. Anything that arrived before that is
    /// replayed here rather than dropped: whoever attaches the listener and whoever
    /// handles the signals are two different objects, so a signal landing in between
    /// (the caller's offer is usually already waiting in the collection) would otherwise
    /// be lost with no trace — the callee rings, then answers into silence.
    var onSignal: ((CallSignal) -> Void)? {
        didSet {
            guard onSignal != nil, !buffered.isEmpty else { return }
            let queued = buffered
            buffered.removeAll()
            print("[Inditalk call] replaying \(queued.count) signal(s) that arrived before the handler was installed")
            queued.forEach { onSignal?($0) }
        }
    }

    /// Signals received while `onSignal` was still nil (see above).
    private var buffered: [CallSignal] = []

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var callId: String = ""
    private var selfId: String = ""

    func connect(callId: String, selfId: String) {
        self.callId = callId
        self.selfId = selfId
        print("[Inditalk call] signals listener attaching for call \(callId) as \(selfId)")
        // Deliver every signal addressed to me for this call, oldest first.
        listener = db.collection("calls").document(callId).collection("signals")
            .order(by: "createdAt", descending: false)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                // A denied/failed listen here is FATAL to the call (this side never
                // hears the answer or any ICE) and Firestore won't retry it — it must
                // never pass silently. Rules require the parent call doc to exist
                // BEFORE this attaches; see CallCenter.placeCall.
                if let error {
                    print("[Inditalk call] signals listener failed for call \(callId): \(error)")
                }
                snapshot?.documentChanges.forEach { change in
                    guard change.type == .added else { return }
                    let signal: CallSignal
                    do {
                        signal = try change.document.data(as: CallSignal.self)
                    } catch {
                        // Was `try?`. A decode failure here silently swallows the whole
                        // call setup — every offer/answer/candidate — so it is logged
                        // with the raw keys that failed to map.
                        print("[Inditalk call] signal \(change.document.documentID) failed to decode "
                              + "for call \(callId): \(error) — keys \(change.document.data().keys.sorted())")
                        return
                    }
                    print("[Inditalk call] signal in: kind=\(signal.kind.rawValue) "
                          + "from=\(signal.from) to=\(signal.to) call=\(signal.callId)"
                          + (signal.sdp.map { " sdp=\($0.count)B" } ?? "")
                          + (signal.candidate != nil ? " candidate" : ""))
                    guard signal.to == self.selfId else { return }   // the peer's own copy
                    if self.onSignal != nil {
                        self.onSignal?(signal)
                    } else {
                        self.buffered.append(signal)
                        print("[Inditalk call] buffering \(signal.kind.rawValue) — no handler installed yet")
                    }
                }
            }
    }

    func send(_ signal: CallSignal) async throws {
        var payload = signal
        payload.createdAt = nil   // let the server stamp it
        var data = try Firestore.Encoder().encode(payload)
        data["createdAt"] = FieldValue.serverTimestamp()
        do {
            try await db.collection("calls").document(signal.callId)
                .collection("signals").document(signal.id).setData(data)
            print("[Inditalk call] signal out: kind=\(signal.kind.rawValue) "
                  + "from=\(signal.from) to=\(signal.to) call=\(signal.callId)")
        } catch {
            // Several callers use `try?`; without this line a rules denial on the signals
            // subcollection looks exactly like a call that simply never connects.
            print("[Inditalk call] signal out FAILED: kind=\(signal.kind.rawValue) "
                  + "call=\(signal.callId): \(error)")
            throw error
        }
    }

    func disconnect() {
        listener?.remove()
        listener = nil
        buffered.removeAll()
    }

    /// Create/refresh the parent call doc (used to alert the callee + drive presence).
    func upsertCallDoc(callId: String, from: String, to: String, media: String, state: String) async throws {
        try await db.collection("calls").document(callId).setData([
            "from": from, "to": to, "media": media, "state": state,
            "createdAt": FieldValue.serverTimestamp(),
        ], merge: true)
    }

    /// Mark the call doc's lifecycle state (e.g. "ended"). Without this, a finished
    /// call stays "ringing" forever and re-rings the callee on every app launch.
    func updateCallState(callId: String, state: String) async throws {
        try await db.collection("calls").document(callId).setData(["state": state], merge: true)
    }

    /// Listen for incoming calls addressed to me (foreground fallback to VoIP push).
    /// Passes the doc's createdAt so the receiver can ignore stale ringing docs.
    static func listenForIncoming(uid: String,
                                  _ handler: @escaping (String, String, String, Date?) -> Void) -> ListenerRegistration {
        Firestore.firestore().collection("calls")
            .whereField("to", isEqualTo: uid)
            .whereField("state", isEqualTo: "ringing")
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[Inditalk call] incoming-call listener failed: \(error)")
                }
                snapshot?.documentChanges.forEach { change in
                    guard change.type == .added else { return }
                    let d = change.document.data()
                    handler(change.document.documentID,
                            d["from"] as? String ?? "",
                            d["media"] as? String ?? "voice",
                            (d["createdAt"] as? Timestamp)?.dateValue())
                }
            }
    }
}
