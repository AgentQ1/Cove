//
//  AudioPlayerService.swift
//  Inditalk
//
//  Playback for voice-note bubbles. A single shared player so only one voice note
//  plays at a time; bubbles key off `playingID` + `progress`. Progress is driven by
//  a main-actor Task loop; the AVAudioPlayerDelegate finish callback (off-main)
//  hops back to the main actor.
//

import Foundation
import AVFoundation

@MainActor
final class AudioPlayerService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerService()

    @Published private(set) var playingID: UUID?
    @Published private(set) var progress: Double = 0   // 0…1
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    /// Play/pause the voice note identified by `id` (a message ID). Starting a
    /// different note stops the current one.
    func togglePlay(id: UUID, url: URL) {
        // Never grab the audio session while a recording is in progress.
        guard !AudioRecorderService.isCapturing else { return }
        if playingID == id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                progressTask?.cancel()
            } else {
                activateSession()
                isPlaying = player.play()
                startProgressLoop()
            }
            return
        }

        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        activateSession()
        self.player = player
        playingID = id
        progress = 0
        isPlaying = player.play()
        startProgressLoop()
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        playingID = nil
        progress = 0
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func startProgressLoop() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let player = self.player else { return }
                guard player.duration > 0 else { continue }
                self.progress = min(1, player.currentTime / player.duration)
            }
        }
    }

    // MARK: AVAudioPlayerDelegate (arrives off-main — hop to MainActor)

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
