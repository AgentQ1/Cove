//
//  CallsListView.swift
//  Inditalk
//
//  The Calls destination: serif header, a search field, a quick-actions tray (Call /
//  Schedule / Keypad / Favorites), an "Upcoming" section for scheduled calls, and a
//  "Recent" call history list. Uses the pine accent. Tapping a row (or "Call") starts
//  a call, which is logged back to history.
//

import SwiftUI
import UIKit

struct CallsListView: View {
    @EnvironmentObject private var store: DataStore
    @StateObject private var vm = CallsViewModel()
    @State private var showPickCall = false
    @State private var showSchedule = false
    @State private var showKeypad = false
    @State private var showFavorites = false
    @State private var showClearConfirm = false
    @State private var pendingScheduled: ScheduledCall?
    @State private var showCamera = false
    @State private var capturedPhoto: CapturedPhoto?
    @State private var pendingCapture: PendingCapture?

    private struct PendingCapture: Identifiable {
        let id = UUID()
        let image: UIImage
        let chat: Chat
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchField
                quickActions
                list
            }
            .background(Palette.background)
            // Every launch site below places a REAL call via CallLauncher → CallCenter
            // (WebRTC + Firestore signaling); RootView presents LiveCallView off
            // CallCenter state. The simulated screen is no longer reachable from here —
            // it looked like a call while the peer heard nothing.
            .sheet(isPresented: $showPickCall) {
                PickChatSheet(title: "New call", directOnly: true) { chat in
                    CallLauncher.call(chatID: chat.id, video: false, store: store)
                }
            }
            .sheet(isPresented: $showSchedule) { ScheduleCallSheet() }
            .sheet(isPresented: $showKeypad) { KeypadView() }
            .sheet(isPresented: $showFavorites) { FavoritesView() }
            .sheet(item: $capturedPhoto) { photo in
                PickChatSheet(title: "Send photo to") { chat in stagePreview(photo.image, for: chat) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in capturedPhoto = CapturedPhoto(image: image) }
                    .ignoresSafeArea()
            }
            .fullScreenCover(item: $pendingCapture) { capture in
                AttachmentPreviewSheet(
                    drafts: [AttachmentDraft(content: .image(capture.image))],
                    destinationTitle: capture.chat.title,
                    onSend: { drafts, caption in
                        AttachmentSender.send(drafts, caption: caption, to: capture.chat.id, store: store)
                        Haptics.impact(.light)
                        pendingCapture = nil
                    },
                    onCancel: { pendingCapture = nil }
                )
            }
            .alert("Clear call history?", isPresented: $showClearConfirm) {
                Button("Clear all", role: .destructive) { clearHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every call from your history on this device.")
            }
            .confirmationDialog(
                pendingScheduled?.title ?? "",
                isPresented: Binding(get: { pendingScheduled != nil },
                                     set: { if !$0 { pendingScheduled = nil } }),
                titleVisibility: .visible,
                presenting: pendingScheduled
            ) { scheduled in
                Button("Start call now") { startScheduled(scheduled) }
                Button("Remove", role: .destructive) {
                    store.deleteScheduledCall(scheduled.id)
                    Haptics.impact(.light)
                }
                Button("Cancel", role: .cancel) {}
            } message: { scheduled in
                Text("\(scheduled.displayName) · \(CallsViewModel.upcomingStamp(scheduled.date))")
            }
        }
        .tint(Palette.pine)
    }

    private var header: some View {
        HStack {
            Menu {
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Label("Clear call history", systemImage: "trash")
                }
                .disabled(store.calls.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.pine)
                    .frame(width: 42, height: 42)
                    .background(Palette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.separator, lineWidth: 1))
            }
            .accessibilityLabel("More")
            Text("Calls").font(.inditalkTitle()).foregroundStyle(Palette.textPrimary)
                .padding(.leading, 4)
            Spacer()
            CircleButton(symbol: "camera", tint: Palette.pine) { captureFromCamera() }
            CircleButton(symbol: "plus", filled: true, tint: Palette.pine) { showPickCall = true }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 8).padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
            TextField("Search calls", text: $vm.searchText)
                .autocorrectionDisabled()
                .foregroundStyle(Palette.textPrimary)
            if !vm.searchText.isEmpty {
                Button { vm.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.searchCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.searchCorner).strokeBorder(Palette.separator, lineWidth: 1))
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.bottom, 12)
    }

    private var quickActions: some View {
        HStack(spacing: 0) {
            quickAction("Call", "phone.fill", filled: true) { showPickCall = true }
            quickAction("Schedule", "calendar") { showSchedule = true }
            quickAction("Keypad", "circle.grid.3x3.fill") { showKeypad = true }
            quickAction("Favorites", "heart") { showFavorites = true }
        }
        .padding(.vertical, 14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.separator, lineWidth: 0.5))
        .padding(.horizontal, Metrics.screenPadding)
    }

    private func quickAction(_ title: String, _ symbol: String, filled: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(filled ? Palette.textOnAccent : Palette.pine)
                    .frame(width: 48, height: 48)
                    .background(filled ? Palette.pine : Palette.pine.opacity(0.10), in: Circle())
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.textPrimary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    // MARK: List (Upcoming + Recent)

    private var list: some View {
        List {
            if !store.scheduledCalls.isEmpty {
                upcomingSection
            }
            recentSection
        }
        .safeAreaPadding(.bottom, TabBarMetrics.reservedHeight)   // clear the floating tab bar
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
    }

    private var upcomingSection: some View {
        Section {
            ForEach(store.scheduledCalls) { scheduled in
                Button { pendingScheduled = scheduled } label: {
                    ScheduledCallRow(call: scheduled, avatarAsset: avatarAsset(for: scheduled))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: Metrics.screenPadding, bottom: 0, trailing: Metrics.screenPadding))
                .listRowBackground(Palette.background)
                .listRowSeparatorTint(Palette.separator)
                .alignmentGuide(.listRowSeparatorLeading) { _ in Metrics.avatarSmall + 12 }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { store.deleteScheduledCall(scheduled.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            sectionHeader("Upcoming")
        }
    }

    private var recentSection: some View {
        Section {
            ForEach(vm.rows(store.calls)) { row in
                Button { callBack(row.record) } label: { CallRowView(row: row) { callBack(row.record) } }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: Metrics.screenPadding, bottom: 0, trailing: Metrics.screenPadding))
                    .listRowBackground(Palette.background)
                    .listRowSeparatorTint(Palette.separator)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in Metrics.avatarSmall + 12 }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.deleteCall(row.record.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }

            if vm.rows(store.calls).isEmpty {
                emptyState
            }
        } header: {
            sectionHeader("Recent")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.inditalkSectionTitle()).foregroundStyle(Palette.textPrimary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16).padding(.bottom, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: Metrics.screenPadding, bottom: 0, trailing: Metrics.screenPadding))
            .background(Palette.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.badge.waveform")
                .font(.system(size: 44)).foregroundStyle(Palette.textSecondary.opacity(0.6))
            Text(vm.searchText.isEmpty ? "No recent calls" : "No results for “\(vm.searchText)”")
                .font(.inditalkRowName()).foregroundStyle(Palette.textPrimary)
            if vm.searchText.isEmpty {
                Text("Tap + to start a call.")
                    .font(.inditalkRowSubtitle()).foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
        .listRowBackground(Palette.background)
        .listRowSeparator(.hidden)
    }

    // MARK: Actions

    private func callBack(_ record: CallRecord) {
        CallLauncher.call(chatID: record.chatID, video: record.media == .video, store: store)
    }

    private func startScheduled(_ scheduled: ScheduledCall) {
        CallLauncher.call(chatID: scheduled.chatID, video: scheduled.media == .video, store: store)
    }

    private func avatarAsset(for scheduled: ScheduledCall) -> String? {
        scheduled.contactID.flatMap { store.users[$0]?.avatarAsset }
    }

    private func clearHistory() {
        for record in store.calls { store.deleteCall(record.id) }
        Haptics.impact(.light)
    }

    private func captureFromCamera() {
        guard CameraPicker.isAvailable else {
            ToastCenter.shared.show("Camera isn't available on the Simulator")
            return
        }
        Task {
            if await PermissionsManager.shared.requestCamera() {
                showCamera = true
            } else {
                ToastCenter.shared.show("Camera access is off — enable it in Settings")
            }
        }
    }

    /// Hand a captured photo to the WhatsApp-style preview/caption screen once the
    /// chat-picker sheet has finished dismissing (avoids competing presentations).
    private func stagePreview(_ image: UIImage, for chat: Chat) {
        capturedPhoto = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            pendingCapture = PendingCapture(image: image, chat: chat)
        }
    }
}

#Preview {
    CallsListView().environmentObject(DataStore.inMemory())
}
