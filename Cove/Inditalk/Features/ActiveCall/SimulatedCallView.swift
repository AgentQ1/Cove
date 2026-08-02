//
//  SimulatedCallView.swift
//  Inditalk
//
//  The unified simulated call screen: renders the voice layout or the video layout
//  from a single media-mode state, so "Switch to video" transitions the in-progress
//  call in place. Also hosts the in-call DTMF pad overlay and the simulated
//  "add person" flow (participant chips). VoiceCallView / VideoCallView are thin
//  entry points over this view; the real WebRTC path presents LiveCallView instead.
//

import SwiftUI

/// Everything needed to launch the simulated call screen from anywhere in the app.
struct SimulatedCallRequest: Identifiable {
    let id = UUID()
    var name: String
    var avatar: String? = nil
    var chatID: UUID? = nil
    var media: CallMedia = .voice
    var direction: CallDirection = .outgoing
}

struct SimulatedCallView: View {
    let peerName: String
    var avatar: String? = nil
    var chatID: UUID? = nil
    var direction: CallDirection = .outgoing
    var initialMedia: CallMedia = .voice

    @EnvironmentObject private var store: DataStore
    @StateObject private var vm = CallViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var showDialPad = false
    @State private var inlineNote: String?
    @State private var selfOffset = CGSize.zero

    init(request: SimulatedCallRequest) {
        self.init(peerName: request.name, avatar: request.avatar, chatID: request.chatID,
                  direction: request.direction, initialMedia: request.media)
    }

    init(peerName: String, avatar: String? = nil, chatID: UUID? = nil,
         direction: CallDirection = .outgoing, initialMedia: CallMedia = .voice) {
        self.peerName = peerName
        self.avatar = avatar
        self.chatID = chatID
        self.direction = direction
        self.initialMedia = initialMedia
    }

    var body: some View {
        ZStack {
            if vm.media == .video {
                videoLayer
            } else {
                voiceLayer
            }

            if let inlineNote {
                Text(inlineNote)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: vm.media)
        .task { await vm.start(media: initialMedia) }
        .onChange(of: vm.state) { _, s in if s == .ended { logAndDismiss() } }
        .statusBarHidden(vm.media == .video)
    }

    private func logAndDismiss() {
        // An outgoing call the user cancels before it connects stays "outgoing" (not
        // connected) — .missed is reserved for calls the user actually missed (incoming).
        let loggedDirection: CallDirection = vm.didConnect
            ? direction
            : (direction == .incoming ? .missed : .outgoing)
        store.logCall(CallRecord(
            chatID: chatID, displayName: peerName, avatarAsset: avatar,
            direction: loggedDirection, media: vm.media,
            date: vm.startedAt, durationSeconds: vm.didConnect ? vm.elapsed : nil,
            participantsSummary: nil))
        dismiss()
    }

    private func note(_ text: String) {
        withAnimation(.snappy) { inlineNote = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(.snappy) { inlineNote = nil }
        }
    }

    // MARK: Voice layout

    private var voiceLayer: some View {
        ZStack {
            LinearGradient(colors: [Palette.ink, Palette.ink.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer().frame(height: 40)

                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 12))
                    Text("End-to-end encrypted").font(.system(size: 13))
                }
                .foregroundStyle(.white.opacity(0.7))

                AvatarView(name: peerName, imageName: avatar, size: Metrics.avatarLarge + 40)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2))

                VStack(spacing: 6) {
                    Text(peerName).font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                    Text(vm.statusText).font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }


                Spacer()

                if showDialPad {
                    dtmfPanel.padding(.bottom, 40)
                } else {
                    voiceControls.padding(.bottom, 40)
                }
            }
            .padding(.horizontal, 28)
        }
    }

    private var voiceControls: some View {
        VStack(spacing: 26) {
            HStack(spacing: 26) {
                CallControl(symbol: vm.isMuted ? "mic.slash.fill" : "mic.fill",
                            label: "Mute", on: vm.isMuted) { vm.toggleMute() }
                CallControl(symbol: "video.fill", label: "Video", on: false) { switchToVideo() }
                CallControl(symbol: vm.isSpeaker ? "speaker.wave.3.fill" : "speaker.fill",
                            label: "Speaker", on: vm.isSpeaker) { vm.toggleSpeaker() }
            }
            HStack(spacing: 26) {
                CallControl(symbol: "circle.grid.3x3.fill", label: "Keypad", on: false) {
                    withAnimation(.snappy) { showDialPad = true }
                }
                CallControl(symbol: "pause.fill", label: "Hold", on: vm.state == .held) {
                    vm.toggleHold()
                }
            }
            endButton
        }
    }

    private func switchToVideo() {
        Task {
            if await vm.switchToVideo() == false {
                note("Camera access is off — enable it in Settings")
            }
        }
    }

    // MARK: DTMF overlay

    private var dtmfPanel: some View {
        VStack(spacing: 16) {
            Text(vm.dtmfDigits.isEmpty ? "Enter numbers" : vm.dtmfDigits)
                .font(.system(size: 26, weight: .medium, design: .monospaced))
                .foregroundStyle(vm.dtmfDigits.isEmpty ? Color.white.opacity(0.5) : Color.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(height: 34)
                .accessibilityLabel(vm.dtmfDigits.isEmpty ? "No numbers entered"
                                                          : "Entered \(vm.dtmfDigits)")

            DialPadGrid(style: .inCall, keySize: 62) { key in vm.pressDTMF(key) }

            HStack(spacing: 26) {
                Button {
                    withAnimation(.snappy) { showDialPad = false }
                } label: {
                    Text("Hide")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 70, height: 70)
                        .background(Color.white.opacity(0.16), in: Circle())
                }
                .accessibilityLabel("Hide keypad")
                endButton
            }
        }
    }

    // MARK: Video layout

    private var videoLayer: some View {
        ZStack {
            // Remote feed placeholder (a warm gradient stands in for video frames).
            LinearGradient(colors: [Color(hex: 0x2C3A57), Color(hex: 0x1C2740)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
                .overlay(
                    VStack(spacing: 14) {
                        AvatarView(name: peerName, imageName: avatar, size: 120)
                        if vm.state != .active {
                            Text(vm.statusText).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .opacity(vm.state == .active ? 0.25 : 1)
                )

            // Self-view PiP.
            selfView
                .frame(width: 110, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .offset(x: selfOffset.width, y: selfOffset.height)
                .gesture(DragGesture().onChanged { selfOffset = $0.translation })
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            if showControls { videoOverlay }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { showControls.toggle() } }
    }

    private var selfView: some View {
        LinearGradient(colors: [Palette.pine, Palette.ink], startPoint: .top, endPoint: .bottom)
            .overlay(Image(systemName: vm.isCameraOn ? "person.fill" : "video.slash.fill")
                .font(.system(size: 30)).foregroundStyle(.white.opacity(0.7)))
    }

    private var videoOverlay: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(peerName).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    Text(vm.statusText).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: "lock.fill").foregroundStyle(.white.opacity(0.7))
            }
            .padding()
            .background(LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))


            Spacer()

            HStack(spacing: 22) {
                CallControl(symbol: vm.isCameraOn ? "video.fill" : "video.slash.fill",
                            label: "Camera", on: !vm.isCameraOn) { vm.isCameraOn.toggle() }
                CallControl(symbol: "arrow.triangle.2.circlepath.camera.fill",
                            label: "Flip", on: false) { vm.isFrontCamera.toggle() }
                CallControl(symbol: vm.isMuted ? "mic.slash.fill" : "mic.fill",
                            label: "Mute", on: vm.isMuted) { vm.toggleMute() }
                Button { vm.end() } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 24)).foregroundStyle(.white)
                        .frame(width: 64, height: 64).background(Palette.danger, in: Circle())
                }
                .accessibilityLabel("End call")
            }
            .padding(.bottom, 40)
        }
        .transition(.opacity)
    }

    // MARK: Shared pieces

    private var endButton: some View {
        Button { vm.end() } label: {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 26)).foregroundStyle(.white)
                .frame(width: 70, height: 70)
                .background(Palette.danger, in: Circle())
        }
        .accessibilityLabel("End call")
    }
}

/// Round translucent in-call control button (shared with LiveCallView).
struct CallControl: View {
    let symbol: String
    let label: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(on ? Palette.ink : .white)
                    .frame(width: 62, height: 62)
                    .background(on ? Color.white : Color.white.opacity(0.16), in: Circle())
                Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

