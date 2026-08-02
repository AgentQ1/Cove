//
//  CallViewModel.swift
//  Inditalk
//
//  Drives the in-call UI state machine and elapsed-time counter for the local call
//  screens. It performs the real just-in-time work a call needs: requests microphone
//  (and camera, for video) permission before connecting, activates the AVAudioSession,
//  and routes the speaker. It also owns the mid-call feature state: media mode (a voice
//  call can upgrade to video), the DTMF digit string, and simulated extra participants.
//  The simulated ring → connecting → active lifecycle stands in for remote signaling
//  until the WebRTC path (CallCenter) is the presenter — see docs/PHASE4_CALLING.md.
//

import Foundation
import Combine
import AudioToolbox

@MainActor
final class CallViewModel: ObservableObject {
    @Published var state: CallState = .dialing
    @Published var elapsed: Int = 0
    @Published var isMuted = false
    @Published var isSpeaker = false
    @Published var isCameraOn = true
    @Published var isFrontCamera = true
    /// Set when the user declined mic/camera access, so the screen can explain why.
    @Published var permissionDenied = false
    /// Which permission the user declined (so the failure copy names the right toggle).
    @Published private(set) var deniedPermission: DeniedPermission?
    enum DeniedPermission { case microphone, camera }
    /// Current media mode; starts as requested and can upgrade voice → video mid-call.
    @Published private(set) var media: CallMedia = .voice
    /// Digits typed on the in-call DTMF pad (visible string in the overlay).
    @Published private(set) var dtmfDigits = ""

    /// Wall-clock start, used to stamp the call-history entry.
    let startedAt = Date()
    /// True once the call reached `.active` (drives connected-vs-missed history).
    private(set) var didConnect = false
    private var timerTask: Task<Void, Never>?

    /// Request permissions, activate audio, then run the connect sequence.
    func start(media: CallMedia, incoming: Bool = false) async {
        self.media = media

        let micGranted = await PermissionsManager.shared.requestMicrophone()
        let camGranted = media == .video ? await PermissionsManager.shared.requestCamera() : true
        guard micGranted && camGranted else {
            permissionDenied = true
            deniedPermission = micGranted ? .camera : .microphone
            state = .failed
            return
        }

        CallAudioSession.activate(video: media == .video)
        isSpeaker = media == .video

        state = incoming ? .ringing : .dialing
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        guard state == .dialing || state == .ringing else { return }
        state = .connecting
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard state == .connecting else { return }
        state = .active
        didConnect = true
        startTimer()
    }

    /// Upgrade an in-progress voice call to video. Requests camera permission first;
    /// returns false (staying on voice) when the user declines.
    @discardableResult
    func switchToVideo() async -> Bool {
        guard media == .voice else { return true }
        guard await PermissionsManager.shared.requestCamera() else { return false }
        media = .video
        isCameraOn = true
        CallAudioSession.activate(video: true)   // re-route: video defaults to speaker
        isSpeaker = true
        return true
    }

    func toggleMute() { isMuted.toggle() }

    func toggleSpeaker() {
        isSpeaker.toggle()
        CallAudioSession.setSpeaker(isSpeaker)
    }

    func toggleHold() {
        // Hold only applies to a connected call; ignoring it during dial/connect keeps
        // the connect sequence from aborting into a never-connected state.
        switch state {
        case .active: state = .held
        case .held:   state = .active; startTimer()   // resume the frozen timer
        default:      break
        }
    }

    // MARK: DTMF

    /// Append a key to the visible DTMF string and play the matching touch-tone.
    func pressDTMF(_ key: String) {
        dtmfDigits.append(key)
        Self.playTone(for: key)
    }

    func clearDTMF() { dtmfDigits = "" }

    /// System touch-tone sound IDs: 1200…1209 = digits, 1210 = #, 1211 = *.
    private static func playTone(for key: String) {
        let soundID: SystemSoundID?
        switch key {
        case "0"..."9": soundID = SystemSoundID(1200 + (key.unicodeScalars.first!.value - 48))
        case "#":       soundID = 1210
        case "*":       soundID = 1211
        default:        soundID = nil
        }
        if let soundID { AudioServicesPlaySystemSound(soundID) }
    }

    // MARK: Lifecycle

    func end() {
        state = .ended
        timerTask?.cancel()
        timerTask = nil
        CallAudioSession.deactivate()
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.state == .active else { break }
                self.elapsed += 1
            }
        }
    }

    var statusText: String {
        switch state {
        case .dialing:    return "Calling…"
        case .ringing:    return "Incoming call"
        case .connecting: return "Connecting…"
        case .active:     return RelativeDate.duration(elapsed)
        case .held:       return "On hold"
        case .ended:      return "Call ended"
        case .failed:
            switch deniedPermission {
            case .camera:     return "Camera access needed"
            case .microphone: return "Microphone access needed"
            case nil:         return "Call failed"
            }
        case .idle:       return ""
        }
    }
}
