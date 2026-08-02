//
//  VoiceCallView.swift
//  Inditalk
//
//  Entry point for a simulated voice call. The full in-call UI (including the
//  mid-call switch to video, DTMF pad, and add-person flow) lives in
//  SimulatedCallView; this wrapper keeps the historical call-site signature.
//

import SwiftUI

struct VoiceCallView: View {
    let peerName: String
    var avatar: String? = nil
    var chatID: UUID? = nil
    var direction: CallDirection = .outgoing

    var body: some View {
        SimulatedCallView(peerName: peerName, avatar: avatar, chatID: chatID,
                          direction: direction, initialMedia: .voice)
    }
}
