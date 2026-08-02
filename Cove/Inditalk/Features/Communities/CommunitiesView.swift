//
//  CommunitiesView.swift
//  Inditalk
//
//  The Communities destination: the user's group threads (avatar, member count,
//  last activity) with navigation straight into the conversation, plus real
//  community creation. Locally a community is a group chat owned by its creator
//  (see CreateCommunityView); first-run shows the intro state.
//

import SwiftUI

struct CommunitiesView: View {
    @EnvironmentObject private var store: DataStore
    @EnvironmentObject private var tabBar: TabBarVisibility
    @State private var showCreate = false
    @State private var path = NavigationPath()

    private var groups: [Chat] {
        store.chats.filter { $0.kind == .group }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                if groups.isEmpty {
                    intro
                } else {
                    groupList
                }
            }
            .background(Palette.background)
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chatID: chat.id)
            }
            // Hide the floating tab bar while a conversation (or deeper) is open so
            // it doesn't cover the composer — same behavior as the Chats tab.
            .onChange(of: path.count) { _, depth in tabBar.isHidden = depth > 0 }
            .sheet(isPresented: $showCreate) {
                CreateCommunityView { chat in
                    showCreate = false
                    path.append(chat)
                }
            }
        }
        .tint(Palette.ink)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Communities").font(.inditalkTitle()).foregroundStyle(Palette.textPrimary)
            Spacer()
            Menu {
                Button { showCreate = true } label: {
                    Label("New community", systemImage: "plus")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 42, height: 42)
                    .background(Palette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.separator, lineWidth: 1))
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, Metrics.screenPadding).padding(.top, 8)
    }

    // MARK: Groups list

    private var groupList: some View {
        List {
            Button { showCreate = true } label: {
                HStack(spacing: 16) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.textOnAccent)
                        .frame(width: Metrics.avatar, height: Metrics.avatar)
                        .background(Palette.ink, in: Circle())
                    Text("New community").font(.inditalkRowName()).foregroundStyle(Palette.textPrimary)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: Metrics.screenPadding,
                                      bottom: 0, trailing: Metrics.screenPadding))
            .listRowBackground(Palette.background)
            .listRowSeparatorTint(Palette.separator)

            Section {
                ForEach(groups) { chat in
                    groupRow(chat)
                }
            } header: {
                Text("Your groups")
                    .font(.inditalkSectionTitle())
                    .foregroundStyle(Palette.textPrimary)
                    .textCase(nil)
                    .padding(.top, 8)
            }
        }
        .safeAreaPadding(.bottom, TabBarMetrics.reservedHeight)   // clear the floating tab bar
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
    }

    private func groupRow(_ chat: Chat) -> some View {
        Button {
            path.append(chat)
            store.markRead(chat.id)
        } label: {
            HStack(spacing: 16) {
                AvatarView(name: chat.title, imageName: chat.avatarAsset,
                           systemImage: "person.3.fill", size: Metrics.avatar)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.inditalkRowName()).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    Text(memberLine(chat))
                        .font(.inditalkRowSubtitle()).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Spacer()
                Text(RelativeDate.listStamp(chat.lastActivity))
                    .font(.inditalkCaption()).foregroundStyle(Palette.textSecondary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: Metrics.screenPadding,
                                  bottom: 0, trailing: Metrics.screenPadding))
        .listRowBackground(Palette.background)
        .listRowSeparatorTint(Palette.separator)
        .alignmentGuide(.listRowSeparatorLeading) { _ in Metrics.avatar + 12 }
    }

    private func memberLine(_ chat: Chat) -> String {
        let count = chat.participantIDs.count
        return count == 1 ? "1 member" : "\(count) members"
    }

    // MARK: Intro / empty state

    private var intro: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Palette.ink.opacity(0.85))
                    .padding(.top, 40)
                Text("Stay connected with a community")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Communities bring members together in topic-based groups, and make it easy for admins to send announcements.")
                    .font(.system(size: 15)).foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)

                Button { showCreate = true } label: {
                    Label("New community", systemImage: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.textOnAccent)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Palette.ink, in: Capsule())
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
