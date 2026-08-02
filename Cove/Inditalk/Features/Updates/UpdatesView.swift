//
//  UpdatesView.swift
//  Inditalk
//
//  The Updates destination: post and view ephemeral 24h statuses. "My status"
//  opens the composer or the viewer for your own updates; "Recent updates" lists
//  contacts' active statuses with a segmented viewed/unviewed ring; the header
//  search filters those rows by contact name.
//

import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject private var store: DataStore

    @State private var showChooser = false
    @State private var composerMode: StatusComposerMode?
    @State private var viewerTarget: ViewerTarget?
    @State private var searchActive = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    /// Who the full-screen viewer shows (identity = author, so one cover per person).
    private struct ViewerTarget: Identifiable {
        let user: InditalkUser
        let isMine: Bool
        var id: UUID { user.id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if searchActive { searchField }

                List {
                    Section("Status") {
                        myStatusRow
                            .listRowBackground(Palette.surface)
                    }
                    recentSection
                }
                .safeAreaPadding(.bottom, TabBarMetrics.reservedHeight)   // clear the floating tab bar
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Palette.background)
            }
            .background(Palette.background)
        }
        .tint(Palette.ink)
        .confirmationDialog("Post a status", isPresented: $showChooser, titleVisibility: .visible) {
            Button("Text status") { composerMode = .text }
            Button("Photo status") { composerMode = .photo }
            Button("Video status") { composerMode = .video }
        }
        // Covers get the store re-injected explicitly: on "My Mac (Designed for
        // iPhone)" fullScreenCover content is hosted in a separate window that does
        // not inherit the app-level environmentObject, and the viewer would trap.
        .fullScreenCover(item: $composerMode) { mode in
            StatusComposerView(mode: mode)
                .environmentObject(store)
        }
        .fullScreenCover(item: $viewerTarget) { target in
            StatusViewerView(user: target.user, isMine: target.isMine)
                .environmentObject(store)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Updates").font(.inditalkTitle()).foregroundStyle(Palette.textPrimary)
            Spacer()
            CircleButton(symbol: searchActive ? "xmark" : "magnifyingglass") {
                withAnimation(.snappy) {
                    searchActive.toggle()
                    if !searchActive { searchText = "" }
                }
            }
            CircleButton(symbol: "plus", filled: true, tint: Palette.ink) {
                showChooser = true
            }
        }
        .padding(.horizontal, Metrics.screenPadding).padding(.top, 8).padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textSecondary)
            TextField("Search updates by contact", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.searchCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.searchCorner).strokeBorder(Palette.separator, lineWidth: 1))
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.bottom, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear { searchFocused = true }
    }

    // MARK: My status

    private var myStatusRow: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if !myStatuses.isEmpty {
                        StatusRing(segments: myStatuses.map { _ in false })
                    }
                    AvatarView(name: store.currentUser.displayName,
                               localName: store.currentUser.avatarLocalName,
                               size: Metrics.avatar)
                }
                .frame(width: Metrics.avatar + 10, height: Metrics.avatar + 10)

                Button {
                    showChooser = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.ink)
                        .background(Circle().fill(Palette.background))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add status update")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("My status").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                Text(myStatuses.last.map { StatusTime.label($0.createdAt) } ?? "Tap to add status update")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if myStatuses.isEmpty {
                showChooser = true
            } else {
                viewerTarget = ViewerTarget(user: store.currentUser, isMine: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(myStatuses.isEmpty ? "My status. Tap to add status update"
                                               : "My status. \(myStatuses.count) active updates")
    }

    // MARK: Recent updates

    @ViewBuilder
    private var recentSection: some View {
        Section("Recent updates") {
            if othersStatuses.isEmpty {
                EmptyStateView(symbol: "circle.dashed",
                               title: "No recent updates",
                               message: "Statuses from your contacts appear here.")
                    .frame(minHeight: 260)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            } else if filteredOthers.isEmpty {
                Text("No contacts named \u{201C}\(searchText)\u{201D} have updates")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                    .listRowBackground(Palette.surface)
            } else {
                ForEach(filteredOthers, id: \.user.id) { entry in
                    recentRow(entry)
                        .listRowBackground(Palette.surface)
                }
            }
        }
    }

    private func recentRow(_ entry: (user: InditalkUser, updates: [StatusUpdate])) -> some View {
        Button {
            viewerTarget = ViewerTarget(user: entry.user, isMine: false)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    StatusRing(segments: entry.updates.map(\.isViewed))
                    AvatarView(name: entry.user.displayName,
                               imageName: entry.user.avatarAsset,
                               localName: entry.user.avatarLocalName,
                               remoteURL: entry.user.avatarURL,
                               size: Metrics.avatar)
                }
                .frame(width: Metrics.avatar + 10, height: Metrics.avatar + 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.user.displayName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                    Text(entry.updates.last.map { StatusTime.label($0.createdAt) } ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Data

    private var myStatuses: [StatusUpdate] { store.myActiveStatuses }

    private var othersStatuses: [(user: InditalkUser, updates: [StatusUpdate])] {
        store.othersActiveStatuses
    }

    private var filteredOthers: [(user: InditalkUser, updates: [StatusUpdate])] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard searchActive, !query.isEmpty else { return othersStatuses }
        return othersStatuses.filter { $0.user.displayName.localizedCaseInsensitiveContains(query) }
    }
}
