//
//  MediaViewers.swift
//  Inditalk
//
//  Full-screen media consumption for message bubbles: zoomable image viewer with
//  drag-to-dismiss + share, an AVKit video player screen, a QuickLook wrapper for
//  documents, and the off-main video thumbnail/duration probes.
//

import SwiftUI
import UIKit
import AVKit
import AVFoundation
import QuickLook

// MARK: - Image viewer (zoom, drag-dismiss, share)

struct ImageViewerScreen: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var dragOffset: CGSize = .zero
    @State private var showShare = false

    private var effectiveZoom: CGFloat { max(1, min(5, zoom * pinch)) }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(effectiveZoom)
                .offset(dragOffset)
                .gesture(dragGesture)
                .simultaneousGesture(pinchGesture)
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 2.5 }
                }
        }
        .overlay(alignment: .top) { topBar }
        .sheet(isPresented: $showShare) { ShareSheet(items: [image]) }
        .statusBarHidden()
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("Close")

            Spacer()

            Button { showShare = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("Share photo")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var backgroundOpacity: Double {
        guard effectiveZoom <= 1.01 else { return 1 }
        return max(0.4, 1 - Double(abs(dragOffset.height)) / 600)
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in zoom = max(1, min(5, zoom * value)) }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard effectiveZoom <= 1.01 else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                if effectiveZoom <= 1.01 && abs(value.translation.height) > 140 {
                    dismiss()
                } else {
                    withAnimation(.snappy) { dragOffset = .zero }
                }
            }
    }
}

// MARK: - Video player

struct VideoPlayerScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("Close")
            .padding(.leading, 16)
            .padding(.top, 8)
        }
        .onAppear {
            if player == nil {
                AudioPlayerService.shared.stop()   // don't play video over a voice note
                let created = AVPlayer(url: url)
                player = created
                created.play()
            }
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - QuickLook (documents)

/// QLPreviewController wrapper for tapping a document bubble. The data source
/// lives on a plain (nonisolated) coordinator class as QuickLook expects.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Video probes (off-main)

/// Async AVFoundation probes for video bubbles. Nonisolated so thumbnail decode
/// and duration loads run off the main actor; the returned UIImage is Sendable.
enum VideoTools {
    static func thumbnail(for url: URL, maxDimension: CGFloat = 800) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func durationSeconds(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds > 0.1 ? seconds : nil
    }
}
