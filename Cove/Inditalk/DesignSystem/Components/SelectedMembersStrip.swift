//
//  SelectedMembersStrip.swift
//  Inditalk
//
//  The row of contacts picked so far in a member picker (new group, new community,
//  add-to-group). Keeps the selection visible and removable while the contact list
//  below scrolls — without it, building a group of more than a handful of people means
//  losing track of who is already in, which is why every messenger shows this strip.
//

import SwiftUI

struct SelectedMembersStrip: View {
    let users: [InditalkUser]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(users) { user in
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            AvatarView(name: user.displayName, imageName: user.avatarAsset,
                                       localName: user.avatarLocalName,
                                       remoteURL: user.avatarURL, size: 52)
                            Button { onRemove(user.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Palette.surface, Palette.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                            .accessibilityLabel("Remove \(user.displayName)")
                        }
                        Text(user.displayName.split(separator: " ").first.map(String.init)
                             ?? user.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .frame(width: 60)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .accessibilityLabel("Selected members")
    }
}
