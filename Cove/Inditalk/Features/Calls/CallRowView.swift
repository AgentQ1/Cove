//
//  CallRowView.swift
//  Inditalk
//

import SwiftUI

struct CallRowView: View {
    let row: CallsViewModel.Row
    var onInfo: () -> Void

    private var record: CallRecord { row.record }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: record.displayName, imageName: record.avatarAsset,
                       systemImage: record.participantsSummary != nil ? "person.2.fill" : nil,
                       size: Metrics.avatarSmall)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(record.displayName)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(row.titleColor ? Palette.danger : Palette.textPrimary)
                        .lineLimit(1)
                    if record.groupCount > 1 {
                        Text("(\(record.groupCount))")
                            .font(.system(size: 15))
                            .foregroundStyle(row.titleColor ? Palette.danger : Palette.textSecondary)
                    }
                    if record.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12)).foregroundStyle(Palette.pine)
                    }
                }
                HStack(spacing: 5) {
                    let g = CallsViewModel.directionGlyph(record)
                    Image(systemName: g.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(g.tint)
                    Image(systemName: record.media == .video ? "video.fill" : "phone.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            Spacer(minLength: 8)

            Text(row.stamp).font(.inditalkCaption()).foregroundStyle(Palette.textSecondary)

            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityLabel("Call info")
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.displayName), \(subtitle), \(row.stamp)")
    }

    private var subtitle: String {
        switch record.direction {
        case .outgoing: return record.participantsSummary ?? "Outgoing"
        case .incoming: return record.participantsSummary ?? "Incoming"
        case .missed:   return "Missed"
        }
    }
}

/// Row in the Calls tab "Upcoming" section for a scheduled call.
struct ScheduledCallRow: View {
    let call: ScheduledCall
    var avatarAsset: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: call.displayName, imageName: avatarAsset, size: Metrics.avatarSmall)

            VStack(alignment: .leading, spacing: 3) {
                Text(call.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: call.media == .video ? "video.fill" : "phone.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ochre)
                    Text("\(call.displayName) · \(CallsViewModel.upcomingStamp(call.date))")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "calendar")
                .font(.system(size: 17))
                .foregroundStyle(Palette.pine)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(call.title), \(call.media == .video ? "video" : "voice") call with \(call.displayName), \(CallsViewModel.upcomingStamp(call.date))")
    }
}
