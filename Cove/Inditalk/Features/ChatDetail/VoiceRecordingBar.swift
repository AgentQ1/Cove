//
//  VoiceRecordingBar.swift
//  Inditalk
//
//  Voice-message capture UI. `VoiceRecordingBar` replaces the composer while
//  recording (pulsing dot, elapsed time, live level meter, cancel/stop);
//  `VoicePreviewBar` follows a stop (play back, waveform, trash, send).
//  `AudioRecorderSheet` is the standalone recorder used by the attachment
//  picker's Audio tile. `VoiceWaveformBars` is shared with the message bubbles
//  and the attachment preview.
//

import SwiftUI
import UIKit

// MARK: - Recording bar (replaces the composer while capturing)

struct VoiceRecordingBar: View {
    @ObservedObject var recorder: AudioRecorderService
    let onCancel: () -> Void
    let onStop: () -> Void

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.danger)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Cancel recording")

            Circle()
                .fill(Palette.danger)
                .frame(width: 10, height: 10)
                .opacity(pulsing ? 0.2 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                }
                .accessibilityHidden(true)

            Text(mmss(recorder.elapsed))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.textPrimary)

            VoiceLevelMeter(levels: recorder.levels)
                .frame(maxWidth: .infinity)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Palette.danger, in: Circle())
            }
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Palette.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording voice message, \(mmss(recorder.elapsed))")
    }
}

// MARK: - Preview bar (after stop, before send)

struct VoicePreviewBar: View {
    let recording: AudioRecorderService.Recording
    let playbackID: UUID
    let onDelete: () -> Void
    let onSend: () -> Void

    @ObservedObject private var player = AudioPlayerService.shared

    private var isCurrent: Bool { player.playingID == playbackID }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.danger)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Delete voice message")

            Button {
                player.togglePlay(id: playbackID, url: MediaStore.url(for: recording.localName))
            } label: {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 36, height: 36)
                    .background(Palette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.separator, lineWidth: 1))
            }
            .accessibilityLabel(isCurrent && player.isPlaying ? "Pause preview" : "Play preview")

            VoiceWaveformBars(samples: recording.waveform,
                              progress: isCurrent ? player.progress : 0)
                .frame(maxWidth: .infinity)

            Text(mmss(recording.duration))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.textSecondary)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Palette.ink, in: Circle())
            }
            .accessibilityLabel("Send voice message")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Palette.background)
    }
}

// MARK: - Standalone recorder sheet (attachment picker "Audio" tile)

struct AudioRecorderSheet: View {
    let onUse: (AudioRecorderService.Recording) -> Void

    @StateObject private var recorder = AudioRecorderService()
    @ObservedObject private var player = AudioPlayerService.shared
    @State private var recording: AudioRecorderService.Recording?
    @State private var previewID = UUID()
    @State private var handedOff = false
    @State private var showMicSettingsAlert = false

    var body: some View {
        VStack(spacing: 22) {
            Capsule().fill(Palette.separator).frame(width: 40, height: 4)
                .padding(.top, 8)

            Text("Record audio")
                .font(.inditalkSectionTitle())
                .foregroundStyle(Palette.textPrimary)

            if let recording {
                previewRow(recording)
                HStack(spacing: 12) {
                    Button(role: .destructive) { discard() } label: {
                        Text("Discard")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.danger)

                    Button { use(recording) } label: {
                        Text("Use recording")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.ink)
                }
                .padding(.horizontal, 24)
            } else if recorder.isRecording {
                VoiceLevelMeter(levels: recorder.levels, barCount: 34, maxHeight: 40)
                Text(mmss(recorder.elapsed))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.textPrimary)
                Button {
                    if let captured = recorder.stop() {
                        recording = captured
                    } else {
                        ToastCenter.shared.show("Recording was too short", symbol: "mic.slash",
                                                pending: false)
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Palette.textOnAccent)
                        .frame(width: 68, height: 68)
                        .background(Palette.danger, in: Circle())
                }
                .accessibilityLabel("Stop recording")
            } else {
                Button { startRecording() } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Palette.textOnAccent)
                        .frame(width: 68, height: 68)
                        .background(Palette.danger, in: Circle())
                }
                .accessibilityLabel("Start recording")
                Text("Tap to start recording")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Palette.background)
        .alert("Microphone access is off", isPresented: $showMicSettingsAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Inditalk needs the microphone to record audio. Allow access in Settings.")
        }
        .onDisappear {
            if recorder.isRecording { recorder.cancel() }
            if let recording, !handedOff {
                if player.playingID == previewID { player.stop() }
                MediaStore.delete(recording.localName)
            }
        }
    }

    private func previewRow(_ recording: AudioRecorderService.Recording) -> some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlay(id: previewID, url: MediaStore.url(for: recording.localName))
            } label: {
                Image(systemName: player.playingID == previewID && player.isPlaying
                      ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(width: 42, height: 42)
                    .background(Palette.ink, in: Circle())
            }
            .accessibilityLabel("Play recording")

            VoiceWaveformBars(samples: recording.waveform,
                              progress: player.playingID == previewID ? player.progress : 0,
                              maxHeight: 30)

            Text(mmss(recording.duration))
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func startRecording() {
        Task {
            if await PermissionsManager.shared.requestMicrophone() {
                if !(await recorder.start()) {
                    ToastCenter.shared.show("Couldn't start recording", pending: false)
                }
            } else {
                showMicSettingsAlert = true
            }
        }
    }

    private func discard() {
        guard let recording else { return }
        if player.playingID == previewID { player.stop() }
        MediaStore.delete(recording.localName)
        self.recording = nil
        previewID = UUID()
    }

    private func use(_ recording: AudioRecorderService.Recording) {
        if player.playingID == previewID { player.stop() }
        handedOff = true
        onUse(recording)
    }
}

// MARK: - Shared waveform / meter views

/// Static waveform with a played-progress fill. Falls back to flat bars when a
/// message has no captured waveform (e.g. imported audio files).
struct VoiceWaveformBars: View {
    let samples: [Float]
    var progress: Double = 0
    var playedTint: Color = Palette.ink
    var restTint: Color = Palette.ink.opacity(0.3)
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 24
    var maxBars: Int = 30

    private var display: [Float] {
        let source = samples.isEmpty ? Array(repeating: 0.35, count: 24) : samples
        guard source.count > maxBars else { return source }
        let step = Double(source.count) / Double(maxBars)
        return (0..<maxBars).map { source[min(source.count - 1, Int(Double($0) * step))] }
    }

    var body: some View {
        let bars = display
        HStack(spacing: spacing) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                Capsule()
                    .fill(Double(index) < progress * Double(bars.count) ? playedTint : restTint)
                    .frame(width: barWidth, height: max(3, CGFloat(value) * maxHeight))
            }
        }
        .frame(height: maxHeight)
        .accessibilityHidden(true)
    }
}

/// Rolling live level meter fed by `AudioRecorderService.levels` (newest last).
struct VoiceLevelMeter: View {
    let levels: [Float]
    var barCount: Int = 26
    var tint: Color = Palette.danger
    var maxHeight: CGFloat = 26

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                let sampleIndex = levels.count - barCount + index
                let value: Float = (sampleIndex >= 0 && sampleIndex < levels.count)
                    ? levels[sampleIndex] : 0.05
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: 3, height: max(3, CGFloat(value) * maxHeight))
            }
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}

fileprivate func mmss(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}
