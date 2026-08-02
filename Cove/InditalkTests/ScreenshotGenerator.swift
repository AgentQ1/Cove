//
//  ScreenshotGenerator.swift
//  InditalkTests
//
//  Renders the App Store screenshot set from the real SwiftUI screens instead of
//  capturing a simulator by hand. Output is 1290x2796 (iPhone 6.9" portrait), the size
//  App Store Connect requires for an iPhone-only app.
//
//  These are the shipping views driven by the DEBUG fixture store, so the UI in the
//  screenshots is the UI the app actually renders — only the conversations are fixtures
//  (fictional names, 555-reserved numbers). `site/shots.py` then composites each render
//  into a captioned marketing frame; it never redraws the app itself, because a
//  screenshot that shows UI the app does not have breaches App Review 2.3.3.
//
//  Run:
//    xcodebuild ... test -only-testing:InditalkTests/ScreenshotGenerator
//  then collect the PNGs from the directory printed as [shot-dir].
//

import XCTest
import SwiftUI
import UIKit
@testable import Inditalk

@MainActor
final class ScreenshotGenerator: XCTestCase {

    /// iPhone 16 Pro Max points; @3x renders to the required 1290x2796.
    private let size = CGSize(width: 430, height: 932)
    /// Approximate the device's notch/home-indicator insets — a detached window has none,
    /// which would push content into the status-bar area and misrepresent the layout.
    private let safeArea = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)

    private var outputDirectory: URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("appstore-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func capture<V: View>(_ name: String, _ view: V) throws {
        let host = UIHostingController(rootView: view)
        host.additionalSafeAreaInsets = safeArea

        // Attach to the host app's scene: an unattached window renders blank through
        // `drawHierarchy`, which is the only path that captures SwiftUI list content.
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.rootViewController = host
        window.makeKeyAndVisible()

        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.layoutIfNeeded()
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3          // 430x932 @3x == 1290x2796
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }

        XCTAssertEqual(image.scale * image.size.width, 1290, accuracy: 1, "\(name) width")
        XCTAssertEqual(image.scale * image.size.height, 2796, accuracy: 1, "\(name) height")

        let url = outputDirectory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("[shot] \(url.lastPathComponent)")
    }

    /// A tab root, rendered inside the real RootView chrome (tab bar included).
    private func captureTab(_ name: String, _ tab: AppTab) throws {
        let store = DataStore.inMemory()
        try capture(name, RootView(initialTab: tab)
            .environmentObject(store)
            .environmentObject(AppSession()))
    }

    /// A pushed detail screen. These are presented inside a NavigationStack with the tab
    /// bar hidden, which is how they appear in the app.
    private func captureDetail<V: View>(_ name: String, @ViewBuilder _ build: (DataStore) -> V) throws {
        let store = DataStore.inMemory()
        let session = AppSession()
        try capture(name, NavigationStack { build(store) }
            .tint(Palette.ink)
            .environmentObject(store)
            .environmentObject(session)
            .environmentObject(TabBarVisibility()))
    }

    func testGenerateAppStoreScreenshots() throws {
        try captureTab("01-chats", .chats)

        // The richest fixture thread, so the bubbles, reactions and composer all show.
        try captureDetail("02-chat") { store in
            let chat = store.visibleChats.first { $0.kind == .direct && $0.title.contains("Alexandra") }
                ?? store.visibleChats.first { $0.kind == .direct }
                ?? store.visibleChats[0]
            ChatDetailView(chatID: chat.id)
        }

        try captureTab("03-calls", .calls)
        try captureTab("04-communities", .communities)
        try captureTab("05-updates", .updates)
        try captureTab("06-settings", .you)

        try captureDetail("07-privacy") { _ in PrivacySettingsView() }
        try captureDetail("08-qr")      { _ in ContactQRView() }
        try captureDetail("09-support") { _ in HelpSupportView() }
        try captureDetail("10-account") { _ in AccountSettingsView() }

        print("[shot-dir] \(outputDirectory.path)")
    }
}
