//
//  TabBarClearanceTests.swift
//  InditalkTests
//
//  Regression test for the floating tab bar covering screen content.
//
//  The bar used to be a sibling overlay in RootView's ZStack, drawn ON TOP of the
//  active destination. Every scrolling screen therefore had to guess how much bottom
//  padding would clear it (a hardcoded 96pt). The guess was wrong for Settings: the
//  "Inditalk • v1.0 (1)" version footer — the last row of the list — stayed underneath
//  the bar and was clipped by the screen edge.
//
//  The bar is now a `safeAreaInset(edge: .bottom)`, so SwiftUI reserves exactly its
//  height. This test renders the real RootView on the "You" tab, scrolls the list to
//  the very bottom, and asserts the footer ends up fully above the bar.
//

import XCTest
import SwiftUI
import UIKit
@testable import Inditalk

@MainActor
final class TabBarClearanceTests: XCTestCase {

    /// Renders `RootView` in a real window and returns it once layout has settled.
    private func renderRoot(tab: AppTab) -> UIWindow {
        let store = DataStore.inMemory()
        let session = AppSession()

        let root = RootView(initialTab: tab)
            .environmentObject(store)
            .environmentObject(session)

        let host = UIHostingController(rootView: root)
        // iPhone 17 Pro point size — the device the screenshots are taken on.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()

        // A couple of runloop turns: SwiftUI lays out asynchronously, and the list needs
        // a pass to publish its content size before it can be scrolled.
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()
        }
        return window
    }

    private func firstDescendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let found = firstDescendant(type, in: sub) { return found }
        }
        return nil
    }

    private func allDescendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        var out: [T] = []
        if let match = view as? T { out.append(match) }
        for sub in view.subviews { out.append(contentsOf: allDescendants(type, in: sub)) }
        return out
    }

    /// The version footer is the bottom-most content in Settings, so it is the row the
    /// tab bar covered. Scrolled fully to the bottom it must be completely visible.
    func testSettingsVersionFooterClearsTheTabBar() throws {
        let window = renderRoot(tab: .you)

        let candidates = allDescendants(UIScrollView.self, in: window)
        // The settings list is the scroll view that actually reserves room at the bottom;
        // the navigation bar's search drawer is a scroll view too and reserves nothing.
        let scrollView = try XCTUnwrap(
            candidates.max(by: { $0.adjustedContentInset.bottom < $1.adjustedContentInset.bottom }),
            "Settings should render a scrollable list")

        // The inset the tab bar reserves. Before the fix this was just the home-indicator
        // safe area (~34pt) and the bar's ~76pt sat on top of the content unaccounted for.
        let bottomInset = scrollView.adjustedContentInset.bottom
        XCTAssertGreaterThan(bottomInset, 60,
                             "The tab bar must reserve its own height as a bottom content inset")

        // Measure the bar independently and hold the shared constant to it. The constant
        // is what every screen reserves, so if the bar ever grows past it (new control,
        // larger type) the screens silently start hiding content — that is the bug.
        let barHost = UIHostingController(rootView: InditalkTabBar(
            selection: .constant(.you), unreadChats: 0,
            avatarName: "Test", avatarAsset: nil, avatarLocalName: nil))
        let barHeight = barHost.sizeThatFits(in: CGSize(width: window.bounds.width,
                                                        height: .greatestFiniteMagnitude)).height

        XCTAssertGreaterThanOrEqual(TabBarMetrics.reservedHeight, barHeight, """
            The tab bar lays out at \(barHeight)pt but screens only reserve \
            TabBarMetrics.reservedHeight = \(TabBarMetrics.reservedHeight)pt, so \
            \(barHeight - TabBarMetrics.reservedHeight)pt of content sits underneath it.
            """)
        XCTAssertGreaterThanOrEqual(bottomInset, barHeight, """
            The Settings list reserves \(bottomInset)pt at the bottom but the tab bar is \
            \(barHeight)pt tall, so content sits underneath it.
            """)

        // Scrolled to the very end, the last content must stop at or above the bar's top
        // edge — this is what was violated when the bar was a plain ZStack overlay.
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + bottomInset)
        scrollView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()
        }

        let contentBottomInWindow = scrollView.contentSize.height - scrollView.contentOffset.y
        let barTop = window.bounds.height - bottomInset
        XCTAssertLessThanOrEqual(contentBottomInWindow, barTop + 0.5, """
            Bottom-most list content reaches \(contentBottomInWindow)pt but the tab bar \
            starts at \(barTop)pt.
            """)
    }

    /// Writes a PNG of the You tab so the layout can be eyeballed as well as asserted.
    func testCaptureSettingsScreenshot() throws {
        let window = renderRoot(tab: .you)
        if let scrollView = firstDescendant(UIScrollView.self, in: window) {
            let inset = scrollView.adjustedContentInset.bottom
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + inset)
            scrollView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
            for _ in 0..<3 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                window.layoutIfNeeded()
            }
        }

        // `drawHierarchy(afterScreenUpdates:)` renders blank for a window that was never
        // attached to a real screen; rendering the layer tree works offscreen.
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let png = renderer.image { ctx in
            window.layer.render(in: ctx.cgContext)
        }.pngData()

        if let scrollView = firstDescendant(UIScrollView.self, in: window) {
            print("[diag] window=\(window.bounds.size) safeArea=\(window.safeAreaInsets)")
            print("[diag] adjustedContentInset=\(scrollView.adjustedContentInset)")
            print("[diag] contentSize=\(scrollView.contentSize) offset=\(scrollView.contentOffset)")
        }

        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INDITALK_SHOT_DIR"]
                      ?? NSTemporaryDirectory()).appendingPathComponent("settings-you-tab.png")
        try XCTUnwrap(png).write(to: out)
        print("[shot] wrote \(out.path)")
    }
}
