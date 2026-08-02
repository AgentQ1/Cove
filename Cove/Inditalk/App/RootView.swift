//
//  RootView.swift
//  Inditalk
//
//  Hosts the five primary destinations behind a custom bottom tab bar. A custom bar
//  (rather than the stock TabView chrome) gives us the floating pill highlight,
//  per-tab badge, and the "You" tab showing the user's avatar — matching the
//  product reference's bottom navigation.
//

import SwiftUI

/// Controls the floating tab bar's visibility. The custom bar is a sibling overlay in
/// RootView's ZStack, so it would otherwise float *over* pushed detail screens and cover
/// their bottom chrome (e.g. the chat composer). Screens that need the full height — the
/// chat detail — hide it while they're on screen.
@MainActor
final class TabBarVisibility: ObservableObject {
    @Published var isHidden = false
}

struct RootView: View {
    @EnvironmentObject private var store: DataStore
    @StateObject private var tabBar = TabBarVisibility()
    @ObservedObject private var call = CallCenter.shared
    @State private var selection: AppTab

    /// `initialTab` exists so a test can render a specific destination inside the real
    /// RootView chrome (tab bar included) rather than re-creating that composition.
    init(initialTab: AppTab = .chats) {
        _selection = State(initialValue: initialTab)
    }

    /// The live call screen is presented HERE, off CallCenter state, so it appears for
    /// calls placed from any screen AND for answered incoming calls — and dismisses
    /// itself the moment the call returns to idle (hangup, remote end, or failure).
    private var isCallPresented: Binding<Bool> {
        Binding(
            get: {
                switch call.state {
                // ended/failed stay presented briefly (CallCenter resets to .idle right
                // after) so "Call ended" is readable instead of vanishing mid-frame.
                case .dialing, .connecting, .active, .held, .ended, .failed: return true
                // ringing is CallKit's native incoming UI — except on platforms with no
                // CallKit (iOS app on macOS), where this screen is the only ring there is.
                case .ringing: return !CallCenter.usesCallKit
                case .idle: return false
                }
            },
            set: { _ in }   // fullScreenCover has no interactive dismissal; state drives it
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.background.ignoresSafeArea()

            // Active destination.
            Group {
                switch selection {
                case .updates:     UpdatesView()
                case .calls:       CallsListView()
                case .communities: CommunitiesView()
                case .chats:       ChatListView()
                case .you:         SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environmentObject(tabBar)

            InditalkTabBar(selection: $selection, unreadChats: store.totalUnread,
                       avatarName: store.currentUser.displayName,
                       avatarAsset: store.currentUser.avatarAsset,
                       avatarLocalName: store.currentUser.avatarLocalName)
                // Opaque strip behind the floating capsule: scrolling rows would
                // otherwise be visible sliding through the gap around it.
                .background(Palette.background)
                .opacity(tabBar.isHidden ? 0 : 1)
                .offset(y: tabBar.isHidden ? 140 : 0)
                .allowsHitTesting(!tabBar.isHidden)
                .animation(.snappy(duration: 0.25), value: tabBar.isHidden)
        }
        .background(Palette.background)
        .tint(selection.accent)
        .fullScreenCover(isPresented: isCallPresented) {
            LiveCallView()
        }
    }
}

/// How much room scrolling screens must leave at the bottom for the floating tab bar.
///
/// The bar is an overlay — it floats over the page background and does not shrink the
/// screen beneath it — so each scrolling tab root reserves this much instead. It is one
/// named value rather than a literal repeated per screen, and `TabBarClearanceTests`
/// fails if the bar ever lays out taller than this, which is how the Settings version
/// footer silently ended up underneath it.
enum TabBarMetrics {
    static let reservedHeight: CGFloat = 84
}

/// The floating bottom tab bar.
struct InditalkTabBar: View {
    @Binding var selection: AppTab
    var unreadChats: Int
    var avatarName: String
    var avatarAsset: String?
    var avatarLocalName: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        )
        .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func tabButton(_ tab: AppTab) -> some View {
        let isSelected = tab == selection
        return Button {
            withAnimation(.snappy(duration: 0.22)) { selection = tab }
            Haptics.selection()
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    if tab == .you {
                        // No selection ring: the rounded active background behind the tab
                        // already marks selection, and the ring drew a SECOND outline
                        // around it (AvatarView always strokes its circle).
                        AvatarView(name: avatarName, imageName: avatarAsset,
                                   localName: avatarLocalName,
                                   size: 26)
                    } else {
                        Image(systemName: isSelected ? tab.symbolFilled : tab.symbol)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(isSelected ? tab.accent : Palette.textSecondary)
                    }
                    if tab == .chats, unreadChats > 0 {
                        UnreadBadge(count: unreadChats, tint: Palette.ochre)
                            .offset(x: 16, y: -12)
                    }
                }
                .frame(height: 28)

                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? tab.accent : Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? tab.accent.opacity(0.10) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab == .chats && unreadChats > 0 ? "\(unreadChats) unread" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
