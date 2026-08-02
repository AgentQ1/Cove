//
//  CallAudioRouter.swift
//  Inditalk
//
//  Where call audio goes: earpiece, loudspeaker, AirPods/Bluetooth headset, or a wired
//  headset. A plain speaker on/off switch can't express "send it to my AirPods", which
//  is what a call actually needs the moment a headset is paired.
//
//  Routing runs through RTCAudioSession's lock, not AVAudioSession directly: WebRTC owns
//  the session for the length of a call and re-applies its own configuration on route
//  changes, so anything written behind its back is reverted.
//
//  REQUIRES the WebRTC SPM package.
//

import Foundation
import AVFoundation
import WebRTC

/// One place call audio can come out of.
struct CallAudioRoute: Identifiable, Equatable {
    enum Kind: Equatable { case earpiece, speaker, bluetooth, wired }

    /// The port UID for a real device; a fixed token for the built-in outputs.
    let id: String
    let name: String
    let kind: Kind

    var symbol: String {
        switch kind {
        case .earpiece:  return "iphone"
        case .speaker:   return "speaker.wave.3.fill"
        case .wired:     return "headphones"
        case .bluetooth: return name.localizedCaseInsensitiveContains("airpod")
                              ? "airpodspro" : "headphones"
        }
    }

    static let speaker = CallAudioRoute(id: "cove.speaker", name: "Speaker", kind: .speaker)
    static let earpiece = CallAudioRoute(id: "cove.earpiece", name: "iPhone", kind: .earpiece)
}

@MainActor
final class CallAudioRouter: ObservableObject {
    static let shared = CallAudioRouter()

    /// Everywhere the audio can currently go, in the order the picker lists them.
    @Published private(set) var routes: [CallAudioRoute] = []
    /// Where it is going right now — reflects the SYSTEM route, so unplugging AirPods
    /// mid-call updates the button instead of leaving it lying.
    @Published private(set) var current: CallAudioRoute = .earpiece

    private var observer: NSObjectProtocol?

    /// True when there is somewhere to go beyond the two built-in outputs, i.e. when a
    /// list is worth showing instead of a speaker toggle.
    var hasExternalRoutes: Bool {
        routes.contains { $0.kind == .bluetooth || $0.kind == .wired }
    }

    /// The category options a call needs. Without the Bluetooth HFP option a paired
    /// headset never even appears in `availableInputs` — which is why AirPods were not
    /// selectable at all.
    static var categoryOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if #available(iOS 26.0, *) {
            options.insert(.allowBluetoothHFP)
        } else {
            // The same bit as `allowBluetoothHFP`: iOS 26 renamed the constant, it did
            // not change it. Spelled by raw value so the rename's deprecation warning
            // doesn't fire on the pre-26 path.
            options.insert(AVAudioSession.CategoryOptions(rawValue: 1 << 2))
        }
        return options
    }

    // MARK: Lifecycle

    /// Begin tracking routes for a call. Idempotent.
    func start() {
        refresh()
        guard observer == nil else { return }
        // Headsets connect and disconnect mid-call; the picker has to follow.
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { _ in
            // Delivered on the main queue, so main-actor isolation genuinely holds.
            MainActor.assumeIsolated { CallAudioRouter.shared.refresh() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        routes = []
        current = .earpiece
    }

    // MARK: Reading the current state

    func refresh() {
        let session = AVAudioSession.sharedInstance()
        var found: [CallAudioRoute] = [.earpiece, .speaker]

        // Inputs are what the system lets you PICK; each external input is paired with
        // its own output (an AirPods mic implies AirPods playback).
        for port in session.availableInputs ?? [] {
            switch port.portType {
            case .bluetoothHFP, .bluetoothLE:
                found.append(CallAudioRoute(id: port.uid, name: port.portName, kind: .bluetooth))
            case .headsetMic, .usbAudio, .carAudio:
                found.append(CallAudioRoute(id: port.uid, name: port.portName, kind: .wired))
            default:
                break   // builtInMic — already covered by iPhone/Speaker
            }
        }
        routes = found
        current = resolveCurrent(in: found, session: session)
    }

    private func resolveCurrent(in routes: [CallAudioRoute],
                                session: AVAudioSession) -> CallAudioRoute {
        guard let output = session.currentRoute.outputs.first else { return .earpiece }
        switch output.portType {
        case .builtInSpeaker:
            return .speaker
        case .builtInReceiver:
            return .earpiece
        default:
            // Match the active output back to a listed route by name — an input port and
            // its output counterpart share a name but not a UID.
            return routes.first { $0.name == output.portName }
                ?? CallAudioRoute(id: output.uid, name: output.portName,
                                  kind: output.portType == .headphones ? .wired : .bluetooth)
        }
    }

    // MARK: Switching

    func select(_ route: CallAudioRoute) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }

        do {
            switch route.kind {
            case .speaker:
                // The speaker override outranks any preferred input, so it is enough.
                try rtc.overrideOutputAudioPort(.speaker)
            case .earpiece:
                try rtc.overrideOutputAudioPort(.none)
                if let mic = builtInMic() { try rtc.setPreferredInput(mic) }
            case .bluetooth, .wired:
                // Clear the override first — it would keep forcing the loudspeaker and
                // the headset would look selected while the room heard the call.
                try rtc.overrideOutputAudioPort(.none)
                if let device = port(withUID: route.id) { try rtc.setPreferredInput(device) }
            }
            print("[Inditalk call] audio route -> \(route.name)")
        } catch {
            print("[Inditalk call] could not route audio to \(route.name): \(error)")
        }
        current = route
        // The system confirms (or corrects) the change through routeChangeNotification.
    }

    private func port(withUID uid: String) -> AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance().availableInputs?.first { $0.uid == uid }
    }

    private func builtInMic() -> AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance().availableInputs?.first { $0.portType == .builtInMic }
    }
}
