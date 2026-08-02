//
//  CallAudioSession.swift
//  Inditalk
//
//  Configures AVAudioSession for a call so mute/speaker actually route audio (not just
//  a visual toggle). Used by the local call screens; the WebRTC path configures its own
//  session via RTCAudioSession when the SDK is active.
//

import Foundation
import AVFoundation

@MainActor
enum CallAudioSession {

    /// Activate the play-and-record session used for the duration of a call.
    static func activate(video: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: video ? .videoChat : .voiceChat,
                                    options: [.allowBluetoothA2DP])
            try session.setActive(true)
            // Video calls default to the loudspeaker, voice calls to the earpiece.
            try session.overrideOutputAudioPort(video ? .speaker : .none)
        } catch {
            // Non-fatal: the UI still works; audio routing simply falls back to default.
        }
    }

    /// Route audio to the loudspeaker or back to the earpiece/receiver.
    static func setSpeaker(_ on: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    }

    /// Tear the session down at call end so other audio can resume.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
