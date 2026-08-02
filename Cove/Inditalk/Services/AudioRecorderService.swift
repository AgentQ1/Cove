//
//  AudioRecorderService.swift
//  Inditalk
//
//  Voice-note capture for the composer. Records AAC (.m4a, 44.1kHz mono) straight
//  into MediaStore's directory and publishes a rolling, normalized level meter for
//  the recording UI. Metering is driven by a main-actor Task loop (not a delegate
//  callback) to stay Swift 6 strict-concurrency clean.
//

import Foundation
import AVFoundation

@MainActor
final class AudioRecorderService: NSObject, ObservableObject {

    /// The finished capture: `localName` is the MediaStore file for
    /// `Attachment.localName`; `waveform` is ~40 normalized 0…1 samples.
    struct Recording {
        let localName: String
        let duration: TimeInterval
        let waveform: [Float]
    }

    /// True while ANY recorder instance is capturing — the shared audio player checks
    /// this so a voice-bubble tap can't hijack the session mid-record (both are
    /// @MainActor, so this cross-type read is concurrency-safe).
    static private(set) var isCapturing = false

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels: [Float] = []   // rolling meter, newest last

    private var recorder: AVAudioRecorder?
    private var localName: String?
    private var meterTask: Task<Void, Never>?
    private var allSamples: [Float] = []               // full-session samples for the waveform

    private static let meterWindow = 60                // rolling samples kept for the UI
    private static let waveformSamples = 40

    /// Ask for mic permission, configure the audio session, and start recording.
    /// Returns false (without state changes) when permission is denied or setup fails.
    func start() async -> Bool {
        guard !isRecording else { return false }
        guard await PermissionsManager.shared.requestMicrophone() else { return false }
        // Stop any voice-note playback first: recording and playback share the audio
        // session, and letting a playing bubble deactivate it mid-record would corrupt
        // the take (AVAudioSessionErrorCodeIsBusy, silently swallowed by try?).
        AudioPlayerService.shared.stop()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch { return false }

        let file = MediaStore.newAudioFile()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: file.url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                Self.deactivateSession()
                return false
            }
            self.recorder = recorder
            self.localName = file.name
            self.allSamples = []
            self.levels = []
            self.elapsed = 0
            self.isRecording = true
            Self.isCapturing = true
            startMetering()
            return true
        } catch {
            Self.deactivateSession()
            return false
        }
    }

    /// Finish and return the capture (nil if nothing meaningful was recorded).
    func stop() -> Recording? {
        guard let recorder, let localName else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        finishSession()
        guard duration > 0.3 else {           // accidental tap — discard
            MediaStore.delete(localName)
            return nil
        }
        return Recording(localName: localName,
                         duration: duration,
                         waveform: Self.downsample(allSamplesSnapshot(), to: Self.waveformSamples))
    }

    /// Abort and delete the partial file.
    func cancel() {
        recorder?.stop()
        if let localName { MediaStore.delete(localName) }
        finishSession()
    }

    // MARK: Metering

    /// ~10 samples/sec while recording; each sample feeds both the rolling UI meter
    /// and the full-session buffer used for the final waveform.
    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let recorder = self.recorder, self.isRecording else { return }
                recorder.updateMeters()
                let level = Self.normalizedLevel(recorder.averagePower(forChannel: 0))
                self.allSamples.append(level)
                self.levels.append(level)
                if self.levels.count > Self.meterWindow {
                    self.levels.removeFirst(self.levels.count - Self.meterWindow)
                }
                self.elapsed = recorder.currentTime
            }
        }
    }

    /// Map average power (≈ -50…0 dB useful range) to 0…1.
    private static func normalizedLevel(_ power: Float) -> Float {
        min(1, max(0, (power + 50) / 50))
    }

    private func allSamplesSnapshot() -> [Float] { allSamples }

    /// Average-bucket downsample to `count` values (pads quiet defaults when the
    /// capture was shorter than the target resolution).
    private static func downsample(_ samples: [Float], to count: Int) -> [Float] {
        guard !samples.isEmpty else { return Array(repeating: 0.3, count: count) }
        guard samples.count > count else { return samples }
        let bucket = Double(samples.count) / Double(count)
        return (0..<count).map { i in
            let start = Int(Double(i) * bucket)
            let end = max(start + 1, min(samples.count, Int(Double(i + 1) * bucket)))
            let slice = samples[start..<end]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }

    // MARK: Session teardown

    private func finishSession() {
        meterTask?.cancel()
        meterTask = nil
        recorder = nil
        localName = nil
        allSamples = []
        isRecording = false
        Self.isCapturing = false
        elapsed = 0
        levels = []
        Self.deactivateSession()
    }

    private static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
