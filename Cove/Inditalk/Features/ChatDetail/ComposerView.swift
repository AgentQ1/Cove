//
//  ComposerView.swift
//  Inditalk
//
//  Message input bar: attachment (+), growing text field, emoji quick-insert, camera,
//  and a mic button that becomes a send button when there's text. Shows a reply banner
//  when replying and an edit banner when editing an existing message.
//

import SwiftUI

struct ComposerView: View {
    @ObservedObject var vm: ChatDetailViewModel
    let onSend: () -> Void
    let onAttach: () -> Void
    let onVoiceStart: () -> Void
    let onCamera: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if vm.editing != nil {
                editBanner
            } else if let reply = vm.replyingTo {
                replyBanner(reply)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: onAttach) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.ochre)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Add attachment")

                TextField("Message", text: $vm.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .font(.system(size: 16))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.separator.opacity(0.5), lineWidth: 0.5))

                if !vm.canSend {
                    Button(action: onCamera) {
                        Image(systemName: "camera")
                            .font(.system(size: 20))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("Camera")
                }

                sendOrMic
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Palette.background)
    }

    @ViewBuilder private var sendOrMic: some View {
        if vm.canSend {
            Button(action: onSend) {
                Image(systemName: vm.editing != nil ? "checkmark" : "arrow.up")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Palette.ink, in: Circle())
            }
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel(vm.editing != nil ? "Save edit" : "Send")
        } else {
            Button(action: onVoiceStart) {
                Image(systemName: "mic")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Record voice message")
        }
    }

    private var editBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text("Editing message")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(vm.editing?.text ?? "").font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            Button { vm.cancelEdit() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 4)
    }

    private func replyBanner(_ reply: Message) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.ink).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.isOutgoing ? "Replying to You" : "Replying")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                HStack(spacing: 4) {
                    if let symbol = MessageBubbleView.summarySymbol(for: reply) {
                        Image(systemName: symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Text(MessageBubbleView.summaryText(for: reply))
                        .font(.system(size: 13)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            Button { vm.replyingTo = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 4)
    }
}
