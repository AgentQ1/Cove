//
//  LiveCallView.swift
//  Inditalk
//
//  The REAL call screen: observes CallCenter (state + live WebRTC tracks) and drives
//  mute/camera/end through it. Handles both voice (avatar + status) and video (remote
//  feed + self-view PiP). Presented by CallCenter for a live call.
//
//  The simulation screens (VoiceCallView / VideoCallView) remain for local/demo mode
//  and previews without the SDK; this one is used when Firebase + WebRTC are active.
//
//  ⚠️ REQUIRES the WebRTC SPM package (via VideoRendererView + CallCenter).
//

import SwiftUI

struct LiveCallView: View {
    @ObservedObject var call = CallCenter.shared
    @ObservedObject private var router = CallAudioRouter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selfOffset = CGSize.zero
    @State private var showRoutePicker = false

    var body: some View {
        ZStack {
            if call.isVideoCall {
                videoLayer
            } else {
                voiceLayer
            }
            controls
        }
        .onChange(of: call.state) { _, s in
            // RootView's cover binding drops on .idle (CallCenter's post-call reset);
            // the explicit dismiss also covers any other presentation context.
            if s == .idle { dismiss() }
        }
        .statusBarHidden(call.isVideoCall)
        .confirmationDialog("Audio output", isPresented: $showRoutePicker, titleVisibility: .visible) {
            ForEach(router.routes) { route in
                Button {
                    call.selectAudioRoute(route)
                    Haptics.selection()
                } label: {
                    // The active one is marked, the way the system picker does it.
                    Text(route == router.current ? "\(route.name) ✓" : route.name)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Video

    private var videoLayer: some View {
        ZStack(alignment: .topTrailing) {
            // Remote feed (falls back to a gradient until the track arrives).
            Group {
                if call.remoteVideoTrack != nil {
                    VideoRendererView(track: call.remoteVideoTrack).ignoresSafeArea()
                } else {
                    LinearGradient(colors: [Color(hex: 0x2C3A57), Color(hex: 0x1C2740)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .ignoresSafeArea()
                        .overlay(ProgressView().tint(.white))
                }
            }

            // Self-view PiP (mirrored), draggable. It starts BELOW the header strip so
            // it never covers the peer name or the encryption badge, and the drag is
            // clamped to the safe area so it can't be flung off-screen or under the
            // Dynamic Island / control row.
            GeometryReader { proxy in
                let size = CGSize(width: 110, height: 150)
                VideoRendererView(track: call.localVideoTrack, mirror: true)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .offset(x: proxy.size.width - size.width - Self.pipInset,
                            y: Self.headerClearance)
                    .offset(selfOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                selfOffset = Self.clampedOffset(value.translation,
                                                                in: proxy.size,
                                                                pip: size)
                            }
                    )
            }
        }
    }

    /// Space reserved at the top for the name/status/lock strip.
    private static let headerClearance: CGFloat = 84
    private static let pipInset: CGFloat = 16
    /// Room kept clear at the bottom for the call controls.
    private static let controlsClearance: CGFloat = 150

    /// Keep the dragged self-view fully on screen and clear of the header and controls.
    private static func clampedOffset(_ translation: CGSize,
                                      in container: CGSize,
                                      pip: CGSize) -> CGSize {
        // Resting position is top-trailing, so travel is negative left / positive down.
        let minX = -(container.width - pip.width - pipInset * 2)
        let maxY = container.height - pip.height - headerClearance - controlsClearance
        return CGSize(width: min(0, max(minX, translation.width)),
                      height: min(max(0, maxY), max(0, translation.height)))
    }

    // MARK: Voice

    private var voiceLayer: some View {
        ZStack {
            LinearGradient(colors: [Palette.ink, Palette.ink.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                AvatarView(name: call.activePeerName ?? "Call", size: Metrics.avatarLarge + 40)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2))
                Text(call.activePeerName ?? "Call")
                    .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                statusLine(size: 16)
                Spacer()
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            if call.isVideoCall {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.activePeerName ?? "Call")
                            .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                            .lineLimit(1)
                        statusLine(size: 14)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityLabel("End-to-end encrypted")
                }
                // Leave room on the trailing edge for the self-view PiP so the lock
                // badge and the peer name are never covered by it.
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.trailing, Self.pipInset + 110)
                .background(LinearGradient(colors: [.black.opacity(0.45), .clear],
                                           startPoint: .top, endPoint: .bottom))
            }

            Spacer(minLength: 0)

            // A ringing call reaches this screen only where CallKit can't present its own
            // incoming UI (iOS app on macOS), so answer/decline live here too.
            if call.state == .ringing {
                incomingRow
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
            } else {
                // Wrap on narrow devices instead of letting fixed-width controls collide.
                ViewThatFits(in: .horizontal) {
                    controlRow(spacing: 22)
                    controlRow(spacing: 12)
                    controlRow(spacing: 8)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
    }

    /// Audio output control. With nothing but the built-in outputs it behaves as the
    /// plain speaker toggle; as soon as a headset is around it becomes a picker, because
    /// "speaker on/off" cannot express "send this to my AirPods".
    @ViewBuilder private var audioControl: some View {
        if router.hasExternalRoutes {
            CallControl(symbol: router.current.symbol,
                        label: routeLabel,
                        on: router.current.kind != .earpiece) {
                showRoutePicker = true
            }
        } else {
            CallControl(symbol: call.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                        label: "Speaker", on: call.isSpeakerOn) { call.toggleSpeaker() }
        }
    }

    /// The device name, shortened — "AirPods Pro" fits under a control, "Vincent's
    /// AirPods Pro (2nd generation)" does not.
    private var routeLabel: String {
        switch router.current.kind {
        case .speaker:   return "Speaker"
        case .earpiece:  return "iPhone"
        case .wired:     return "Headset"
        case .bluetooth: return router.current.name.localizedCaseInsensitiveContains("airpod")
                              ? "AirPods" : "Headset"
        }
    }

    private var incomingRow: some View {
        HStack(spacing: 60) {
            Button { call.decline() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 24)).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(Palette.danger, in: Circle())
            }
            .accessibilityLabel("Decline call")

            Button { call.answer() } label: {
                Image(systemName: call.isVideoCall ? "video.fill" : "phone.fill")
                    .font(.system(size: 24)).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(Color.green, in: Circle())
            }
            .accessibilityLabel("Answer call")
        }
    }

    private func controlRow(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            CallControl(symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                        label: "Mute", on: call.isMuted) { call.toggleMute() }
            audioControl
            if call.isVideoCall {
                CallControl(symbol: call.isCameraOn ? "video.fill" : "video.slash.fill",
                            label: "Camera", on: !call.isCameraOn) { call.toggleCamera() }
            }
            Button { call.hangUp() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 24)).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(Palette.danger, in: Circle())
            }
            .accessibilityLabel("End call")
        }
    }

    /// Status line: a live counting timer once connected, otherwise the state label.
    @ViewBuilder private func statusLine(size: CGFloat) -> some View {
        Group {
            if call.state == .active, let since = call.connectedSince {
                Text(since, style: .timer).monospacedDigit()
            } else {
                Text(statusText)
            }
        }
        .font(.system(size: size))
        .foregroundStyle(.white.opacity(0.8))
        .lineLimit(1)
    }

    private var statusText: String {
        switch call.state {
        case .dialing:    return call.peerRinging ? "Ringing…" : "Calling…"
        case .ringing:    return "Incoming call"
        case .connecting: return "Connecting…"
        case .active:     return "Connected"
        case .held:       return "On hold"
        case .ended:      return "Call ended"
        case .failed:     return "Call failed"
        case .idle:       return ""
        }
    }
}
