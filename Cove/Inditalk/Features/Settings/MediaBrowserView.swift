//
//  MediaBrowserView.swift
//  Inditalk
//
//  Settings › Storage and Data › <category>. The actual files, not just a total:
//  thumbnail, size, and which conversation each one came from, with multi-select
//  deletion and largest/newest sorting. This is the screen that makes "48.3 MB of
//  videos" actionable — you can see WHAT is taking the space and remove exactly that.
//

import SwiftUI
import AVFoundation

struct MediaBrowserView: View {
    let category: MediaStore.Category

    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss

    @State private var items: [MediaStore.Item] = []
    @State private var origins: [String: DataStore.MediaOrigin] = [:]
    @State private var sort: SortOrder = .largest
    @State private var selection: Set<String> = []
    @State private var isSelecting = false
    @State private var confirmingDelete = false
    @State private var preview: MediaStore.Item?

    enum SortOrder: String, CaseIterable, Identifiable {
        case largest, newest
        var id: String { rawValue }
        var label: String { self == .largest ? "Largest first" : "Newest first" }
    }

    /// Photos and videos read as a grid of thumbnails; documents and voice notes carry
    /// no useful image, so they stay a list of named rows.
    private var isGrid: Bool { category == .photos || category == .videos }

    private var sorted: [MediaStore.Item] {
        switch sort {
        case .largest: return items.sorted { $0.bytes > $1.bytes }
        case .newest:  return items.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }
    private var selectedBytes: Int {
        items.filter { selection.contains($0.localName) }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No \(category.title.lowercased())",
                                       systemImage: category.symbol,
                                       description: Text("Media you send or receive shows up here."))
            } else if isGrid {
                grid
            } else {
                list
            }
        }
        .background(Palette.background)
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { if isSelecting { selectionBar } }
        .onAppear(perform: refresh)
        .fullScreenCover(item: $preview) { item in
            MediaPreviewSheet(item: item, origin: origins[item.localName])
        }
        .confirmationDialog(
            "Delete \(selection.count) item\(selection.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete \(MediaStore.sizeLabel(selectedBytes))", role: .destructive, action: deleteSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files are removed from this device. The messages stay, but their "
                 + "media can't be reopened.")
        }
    }

    // MARK: Layouts

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 3)], spacing: 3) {
                ForEach(sorted) { item in
                    tile(item)
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 24)
        }
        .background(Palette.background)
    }

    private func tile(_ item: MediaStore.Item) -> some View {
        Button {
            tap(item)
        } label: {
            ZStack(alignment: .bottomLeading) {
                MediaThumbnail(item: item)
                    .frame(minHeight: 104)
                    .clipped()

                // Size always visible: it is the reason to be on this screen.
                Text(item.sizeLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(5)

                if isSelecting {
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(selection.contains(item.localName) ? 0.35 : 0)
                        Image(systemName: selection.contains(item.localName)
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selection.contains(item.localName)
                                             ? Palette.pine : .white.opacity(0.6))
                            .padding(6)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.displayName), \(item.sizeLabel)")
    }

    private var list: some View {
        List {
            Section {
                ForEach(sorted) { item in
                    Button { tap(item) } label: { row(item) }
                        .buttonStyle(.plain)
                }
            } footer: {
                Text("\(items.count) file\(items.count == 1 ? "" : "s") • \(MediaStore.sizeLabel(totalBytes))")
            }
            .listRowBackground(Palette.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
    }

    private func row(_ item: MediaStore.Item) -> some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: selection.contains(item.localName)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(item.localName)
                                     ? Palette.pine : Palette.textSecondary)
            }
            Image(systemName: item.category.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text(subtitle(for: item))
                    .font(.system(size: 13)).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            Text(item.sizeLabel)
                .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func subtitle(for item: MediaStore.Item) -> String {
        origins[item.localName]?.label ?? "Not in any chat"
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .tint(Palette.ink)
        }
    }

    private var selectionBar: some View {
        HStack {
            Button(selection.count == items.count ? "Deselect all" : "Select all") {
                selection = selection.count == items.count ? [] : Set(items.map(\.localName))
            }
            .tint(Palette.ink)
            Spacer()
            Button {
                confirmingDelete = true
            } label: {
                Label(selection.isEmpty ? "Delete"
                                        : "Delete \(MediaStore.sizeLabel(selectedBytes))",
                      systemImage: "trash")
            }
            .tint(Palette.danger)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Actions

    private func tap(_ item: MediaStore.Item) {
        if isSelecting {
            if selection.contains(item.localName) { selection.remove(item.localName) }
            else { selection.insert(item.localName) }
        } else {
            preview = item
        }
    }

    private func refresh() {
        items = MediaStore.items(in: category)
        origins = store.mediaOrigins()
        // Files deleted elsewhere must not linger in the selection.
        selection = selection.intersection(Set(items.map(\.localName)))
    }

    private func deleteSelected() {
        let removed = MediaStore.delete(Array(selection))
        // Detach first so no bubble is left pointing at bytes that are gone.
        store.detachDeletedMedia(named: removed)
        selection.removeAll()
        isSelecting = false
        refresh()
        ToastCenter.shared.show(removed.isEmpty ? "Nothing deleted" : "Freed up space",
                                pending: false)
    }
}

// MARK: - Thumbnail

/// Thumbnail for one stored file. Photos decode downsampled (never full-size — that is
/// what froze the status viewer); videos render their first frame; anything else falls
/// back to its category glyph.
private struct MediaThumbnail: View {
    let item: MediaStore.Item
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Palette.surface
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.category.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.textSecondary)
            }
            if item.category == .videos {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 3)
            }
        }
        .task(id: item.localName) { image = await Self.thumbnail(for: item) }
    }

    private static func thumbnail(for item: MediaStore.Item) async -> UIImage? {
        switch item.category {
        case .photos:
            return await MediaStore.downsampledImage(named: item.localName, maxPixels: 320)
        case .videos:
            return await videoFrame(at: MediaStore.url(for: item.localName))
        case .voice, .documents:
            return nil
        }
    }

    private static func videoFrame(at url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Preview

/// Full-screen look at one stored file, with where it came from and how big it is.
private struct MediaPreviewSheet: View {
    let item: MediaStore.Item
    let origin: DataStore.MediaOrigin?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: item.category.symbol)
                            .font(.system(size: 44)).foregroundStyle(.white.opacity(0.7))
                        Text(item.displayName)
                            .font(.system(size: 15)).foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 2) {
                    Text(origin?.label ?? "Not in any chat")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    Text(item.sizeLabel + (origin.map { $0.referenceCount > 1
                                                       ? " • shared by \($0.referenceCount) messages" : "" } ?? ""))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.black.opacity(0.6))
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
        }
        .task {
            if item.category == .photos {
                image = await MediaStore.downsampledImage(named: item.localName, maxPixels: 2000)
            }
        }
    }
}
