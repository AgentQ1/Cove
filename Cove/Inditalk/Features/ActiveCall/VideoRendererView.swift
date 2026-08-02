//
//  VideoRendererView.swift
//  Inditalk
//
//  SwiftUI bridge that renders a WebRTC video track using RTCMTLVideoView (Metal).
//  Used for both the remote feed and the local self-view in a live video call.
//
//  ⚠️ REQUIRES the WebRTC SPM package. Reference rendering code.
//

import SwiftUI
import WebRTC

struct VideoRendererView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var mirror: Bool = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        // Swap the renderer when the track changes.
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(view)
            track?.add(view)
            context.coordinator.track = track
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var track: RTCVideoTrack?
    }
}
