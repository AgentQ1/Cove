//
//  ChatDetailViewModel.swift
//  Inditalk
//
//  Composer + interaction state for a single chat. Message data itself is read
//  from the store (the reactive source of truth); this holds draft/reply/edit
//  state, the voice-message capture state machine, and the pure day-grouping
//  logic used to render date separators.
//

import Foundation
import Combine

@MainActor
final class ChatDetailViewModel: ObservableObject {
    @Published var draft: String = ""
    @Published var replyingTo: Message?
    @Published var editing: Message?
    @Published var showAttachments = false

    // MARK: Voice messages

    /// idle -> recording (bar replaces composer) -> preview (play/trash/send) -> idle.
    enum VoiceCaptureState: Equatable {
        case idle
        case starting          // permission/session setup in flight — blocks a second tap
        case recording
        case preview(AudioRecorderService.Recording)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.starting, .starting), (.recording, .recording): return true
            case let (.preview(a), .preview(b)): return a.localName == b.localName
            default: return false
            }
        }
    }

    @Published var voiceState: VoiceCaptureState = .idle
    let recorder = AudioRecorderService()
    /// Stable playback key for the pre-send preview (not yet a message ID).
    let voicePreviewID = UUID()

    /// Start capturing (mic permission is checked by the caller so denial can show
    /// an Open Settings alert). Returns false when the recorder failed to start.
    func beginVoiceRecording() async -> Bool {
        guard case .idle = voiceState else { return false }
        // Flip to .starting synchronously (before the first await) so a rapid second
        // mic tap can't spawn a parallel recorder and orphan a file.
        voiceState = .starting
        let started = await recorder.start()
        voiceState = started ? .recording : .idle
        return started
    }

    /// Stop capturing and move to the preview bar (too-short takes are discarded).
    func finishVoiceRecording() {
        guard case .recording = voiceState else { return }
        if let recording = recorder.stop() {
            voiceState = .preview(recording)
        } else {
            voiceState = .idle
            ToastCenter.shared.show("Recording was too short", symbol: "mic.slash", pending: false)
        }
    }

    /// Abort at any stage: cancels an active take or deletes the previewed one.
    func cancelVoiceRecording() {
        switch voiceState {
        case .recording:
            recorder.cancel()
        case .preview(let recording):
            if AudioPlayerService.shared.playingID == voicePreviewID {
                AudioPlayerService.shared.stop()
            }
            MediaStore.delete(recording.localName)
        case .starting:
            recorder.cancel()   // setup in flight — tear down whatever started
        case .idle:
            break
        }
        voiceState = .idle
    }

    /// Send the previewed voice note into the chat.
    func sendVoiceNote(to chatID: UUID, store: DataStore) {
        guard case .preview(let recording) = voiceState else { return }
        guard !store.isBlockedChat(chatID) else { return }
        if AudioPlayerService.shared.playingID == voicePreviewID {
            AudioPlayerService.shared.stop()
        }
        let bytes = (try? MediaStore.url(for: recording.localName)
            .resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        store.sendAttachment(
            kind: .voiceNote,
            attachment: Attachment(localName: recording.localName,
                                   durationSeconds: recording.duration,
                                   waveform: recording.waveform,
                                   byteSize: bytes),
            to: chatID,
            replyingTo: replyingTo?.id)
        replyingTo = nil
        voiceState = .idle
        Haptics.impact(.light)
    }

    // MARK: Day sections

    /// A day-bucketed section of messages for rendering "Thu, Apr 2" separators.
    struct DaySection: Identifiable {
        let id: String
        let title: String
        let messages: [Message]
    }

    func sections(_ messages: [Message], calendar: Calendar = .current) -> [DaySection] {
        let groups = Dictionary(grouping: messages) { calendar.startOfDay(for: $0.sentAt) }
        return groups.keys.sorted().map { day in
            DaySection(
                id: ISO8601DateFormatter().string(from: day),
                title: RelativeDate.daySeparator(day, calendar: calendar),
                messages: (groups[day] ?? []).sorted { $0.sentAt < $1.sentAt }
            )
        }
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(into chatID: UUID, store: DataStore) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Enforcement backstop: never send to a blocked contact even if a stale UI path
        // reaches here (the composer is normally replaced by the "unblock" bar).
        guard !store.isBlockedChat(chatID) else { return }
        if let editing {
            store.editMessage(editing.id, newText: text, in: chatID)
            self.editing = nil
        } else {
            store.send(text: text, to: chatID, replyingTo: replyingTo?.id)
        }
        draft = ""
        replyingTo = nil
        Haptics.impact(.light)
    }

    /// Load an outgoing message into the composer for editing.
    func beginEdit(_ message: Message) {
        replyingTo = nil
        editing = message
        draft = message.text
    }

    func cancelEdit() {
        editing = nil
        draft = ""
    }
}
