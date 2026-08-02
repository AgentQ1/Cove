//
//  InChatSearchView.swift
//  Inditalk
//
//  Read-only in-chat search, reached from the contact/chat info screen's Search
//  quick action. Filters the conversation's transcript (no system notices, no
//  deleted messages) by a case-insensitive text match, grouped by day newest
//  first, with the matched ranges highlighted in each row.
//

import SwiftUI

struct InChatSearchView: View {
    @EnvironmentObject private var store: DataStore
    let chat: Chat

    @State private var query = ""

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// Real user messages only — system notices and deleted messages are skipped.
    private var searchableMessages: [Message] {
        store.messages(in: chat.id).filter { $0.kind != .system && !$0.isDeleted && !$0.text.isEmpty }
    }

    private struct DayGroup: Identifiable {
        let id: Date              // start of day
        let title: String
        let messages: [Message]   // newest first
    }

    private var results: [DayGroup] {
        guard !trimmedQuery.isEmpty else { return [] }
        let matches = searchableMessages
            .filter { $0.text.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { $0.sentAt > $1.sentAt }
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [Message]] = [:]
        for message in matches {
            let day = calendar.startOfDay(for: message.sentAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(message)
        }
        return order.map { DayGroup(id: $0, title: RelativeDate.daySeparator($0), messages: buckets[$0] ?? []) }
    }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                EmptyStateView(symbol: "magnifyingglass",
                               title: "Search this chat",
                               message: "Find any message in “\(chat.title)” by typing above.")
            } else if results.isEmpty {
                EmptyStateView(symbol: "text.magnifyingglass",
                               title: "No results",
                               message: "No messages in “\(chat.title)” match “\(trimmedQuery)”.")
            } else {
                List {
                    ForEach(results) { group in
                        Section(group.title) {
                            ForEach(group.messages) { message in
                                resultRow(message)
                            }
                        }
                        .listRowBackground(Palette.surface)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Palette.background)
            }
        }
        .background(Palette.background)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search messages")
    }

    private func resultRow(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if chat.kind != .direct {
                    Text(senderName(message))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                Spacer()
                Text(RelativeDate.listStamp(message.sentAt))
                    .font(.inditalkCaption()).foregroundStyle(Palette.textSecondary)
            }
            Text(highlighted(message.text))
                .font(.system(size: 15))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    private func senderName(_ message: Message) -> String {
        message.senderID == store.currentUser.id
            ? "You"
            : (store.users[message.senderID]?.displayName ?? "Unknown")
    }

    /// The message text with every occurrence of the query emphasized. Built
    /// piecewise so String and AttributedString indices never need converting.
    private func highlighted(_ text: String) -> AttributedString {
        let needle = trimmedQuery
        guard !needle.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let match = text.range(of: needle,
                                     options: [.caseInsensitive, .diacriticInsensitive],
                                     range: cursor..<text.endIndex) {
            result += AttributedString(String(text[cursor..<match.lowerBound]))
            var hit = AttributedString(String(text[match]))
            hit.font = .system(size: 15, weight: .bold)
            hit.foregroundColor = Palette.ink
            hit.backgroundColor = Palette.ochre.opacity(0.28)
            result += hit
            cursor = match.upperBound
        }
        result += AttributedString(String(text[cursor...]))
        return result
    }
}
