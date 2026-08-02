//
//  VideoCallView.swift
//  Inditalk
//
//  Entry point for a simulated video call (mock remote feed, draggable self-view PiP,
//  auto-hiding controls). The full in-call UI lives in SimulatedCallView; this wrapper
//  keeps the historical call-site signature. Real frames arrive via the WebRTC video
//  track when LiveCallView is the presenter (see docs/PHASE4_CALLING.md).
//

import SwiftUI

struct VideoCallView: View {
    let peerName: String
    var avatar: String? = nil
    var chatID: UUID? = nil
    var direction: CallDirection = .outgoing

    var body: some View {
        SimulatedCallView(peerName: peerName, avatar: avatar, chatID: chatID,
                          direction: direction, initialMedia: .video)
    }
}
