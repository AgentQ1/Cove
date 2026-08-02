//
//  MediaStore.swift
//  Inditalk
//
//  On-device storage for user-sent media (photos, imported documents). Real bytes
//  are written under Application Support/Media and referenced by `Attachment.localName`
//  so a sent photo survives relaunch and renders in the transcript. Cross-device sync
//  (encrypt + upload, download + decrypt) is layered on top by FirebaseSyncCoordinator.
//

import Foundation
import UIKit
import ImageIO
import CryptoKit

@MainActor
enum MediaStore {

    private nonisolated static let folderName = "Media"

    // MARK: - Content addressing (de-duplication)
    //
    // Media used to be stored under a fresh UUID (or the sending message's id), so the
    // SAME picture forwarded to three chats — or sent and then received back from the
    // server — occupied three copies of the same bytes, and the Storage screen counted
    // all of them. Naming a file after a hash of its contents makes identical media one
    // file that every referencing message points at, which is also what makes the
    // storage totals honest.
    //
    // Opt out (`dedupe: false`) for media whose file is owned and deleted by ONE record —
    // profile photos and 24h statuses both delete their file when replaced/expired, and
    // must not be able to delete a file a chat message is still showing.

    private nonisolated static func contentName(for data: Data, ext: String) -> String {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(40)).\(ext)"
    }

    /// Streaming hash for imported files, which can be arbitrarily large (the document
    /// picker accepts any UTType) and must never be loaded into memory just to name them.
    private nonisolated static func contentName(forFileAt url: URL, ext: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(40)).\(ext)"
    }

    // Path/existence helpers are nonisolated (pure FileManager, thread-safe) so the
    // off-main downsampling decode below can resolve files without actor hops.
    private nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    nonisolated static func url(for localName: String) -> URL {
        directory.appendingPathComponent(localName)
    }

    /// Persist a JPEG for a captured/picked image. Returns the stored filename (nil on failure).
    static func saveImage(_ image: UIImage, quality: CGFloat = 0.85,
                          dedupe: Bool = true) -> (name: String, bytes: Int)? {
        guard let data = image.jpegData(compressionQuality: quality) else { return nil }
        let name = dedupe ? contentName(for: data, ext: "jpg") : "\(UUID().uuidString).jpg"
        // Identical bytes are already on disk — reference them instead of writing again.
        if dedupe, exists(name) { return (name, data.count) }
        do {
            try data.write(to: url(for: name), options: .atomic)
            return (name, data.count)
        } catch { return nil }
    }

    /// Copy an imported file (Files/document) into our store. Returns the stored filename.
    static func importFile(from source: URL, dedupe: Bool = true) -> (name: String, displayName: String, bytes: Int)? {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        let display = source.lastPathComponent
        // Keep the display name in the stored filename so the extension (and therefore
        // the storage category) still reflects the document.
        let hashed = dedupe ? contentName(forFileAt: source, ext: display) : nil
        let name = hashed ?? "\(UUID().uuidString)-\(display)"
        let dest = url(for: name)
        if hashed != nil, exists(name) {
            let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (name, display, bytes)
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: source, to: dest)
            // Read the size from filesystem metadata, not by loading the whole file into
            // RAM — the Document tile accepts any UTType, so this can be a multi-GB file.
            let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (name, display, bytes)
        } catch { return nil }
    }

    /// Persist downloaded bytes, preferring `name` (the sync layer's deterministic
    /// message/status-derived name).
    ///
    /// Returns the name the caller must reference from now on — which is NOT always the
    /// requested one: when the same bytes are already stored (the same photo forwarded
    /// into several chats arrives as several messages), the existing file is reused and
    /// nothing is written. Callers MUST use the returned name.
    @discardableResult
    static func saveData(_ data: Data, named name: String) -> String? {
        let ext = (name as NSString).pathExtension
        let deduped = contentName(for: data, ext: ext.isEmpty ? "bin" : ext)
        if exists(deduped) { return deduped }
        do {
            try data.write(to: url(for: deduped), options: .atomic)
            return deduped
        } catch {
            print("[Inditalk media] failed to save \(deduped): \(error)")
            return nil
        }
    }

    /// Persist raw bytes with a given extension (e.g. picked movie data, avatar JPEG).
    static func saveData(_ data: Data, fileExtension: String,
                         dedupe: Bool = true) -> (name: String, bytes: Int)? {
        let ext = fileExtension.hasPrefix(".") ? String(fileExtension.dropFirst()) : fileExtension
        let name = dedupe ? contentName(for: data, ext: ext) : "\(UUID().uuidString).\(ext)"
        if dedupe, exists(name) { return (name, data.count) }
        do {
            try data.write(to: url(for: name), options: .atomic)
            return (name, data.count)
        } catch { return nil }
    }

    /// Copy a picked/exported movie into our store, keeping its extension so
    /// AVFoundation can play it back. Returns the stored filename.
    static func importMovie(from source: URL, dedupe: Bool = true) -> (name: String, bytes: Int)? {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let hashed = dedupe ? contentName(forFileAt: source, ext: ext) : nil
        let name = hashed ?? "\(UUID().uuidString).\(ext)"
        let dest = url(for: name)
        if hashed != nil, exists(name) {
            let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (name, bytes)
        }
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (name, bytes)
        } catch { return nil }
    }

    /// Mint the filename + destination URL for a new voice-note recording. The file
    /// itself is written by AVAudioRecorder; the name goes into `Attachment.localName`.
    static func newAudioFile() -> (name: String, url: URL) {
        let name = "\(UUID().uuidString).m4a"
        return (name, url(for: name))
    }

    /// Remove a single stored file (cancelled recordings, replaced avatars, …).
    static func delete(_ localName: String) {
        try? FileManager.default.removeItem(at: url(for: localName))
    }

    /// Whether a referenced file is still on disk.
    nonisolated static func exists(_ localName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: localName).path)
    }

    /// Load a stored image at FULL resolution, decoding on the calling thread. One-shot
    /// consumers only (share sheets, the zoom viewer); anything that renders repeatedly
    /// (bubbles, the status pager) must use `downsampledImage` or it will re-decode a
    /// multi-megapixel photo on the main thread every render.
    static func image(named localName: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: localName).path)
    }

    /// Decode a stored image scaled to at most `maxPixels` on its longest side, off the
    /// main thread via ImageIO. This bounds both CPU (a 48 MP decode costs 100s of ms)
    /// and memory (~4 bytes/pixel), which is what froze/killed the status viewer.
    nonisolated static func downsampledImage(named localName: String,
                                             maxPixels: CGFloat) async -> UIImage? {
        let fileURL = url(for: localName)
        let boxed = await Task.detached(priority: .userInitiated) { () -> UncheckedSendableBox<UIImage>? in
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options) else { return nil }
            let thumbOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF rotation
                kCGImageSourceShouldCacheImmediately: true,          // decode HERE, not at render
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
            return UncheckedSendableBox(UIImage(cgImage: cg))
        }.value
        return boxed?.value
    }

    /// Human-readable file size for document chips. `nonisolated` so value types that
    /// carry a size (MediaStore.Item) can format it without hopping to the main actor.
    nonisolated static func sizeLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Total bytes currently stored on device (for the Storage settings screen).
    static func totalBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Delete every stored media file (used by account deletion / local wipe).
    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Storage breakdown

    /// Broad media categories, keyed off the stored file's extension. These are what the
    /// Storage screen offers to clear individually.
    enum Category: String, CaseIterable, Identifiable {
        case photos, videos, voice, documents

        var id: String { rawValue }

        var title: String {
            switch self {
            case .photos:    return "Photos"
            case .videos:    return "Videos"
            case .voice:     return "Voice messages"
            case .documents: return "Documents"
            }
        }

        var symbol: String {
            switch self {
            case .photos:    return "photo.fill"
            case .videos:    return "video.fill"
            case .voice:     return "waveform"
            case .documents: return "doc.fill"
            }
        }

        fileprivate static func of(fileExtension ext: String) -> Category {
            switch ext.lowercased() {
            case "jpg", "jpeg", "png", "heic", "gif", "webp":  return .photos
            case "mp4", "mov", "m4v":                           return .videos
            case "m4a", "caf", "aac", "wav", "mp3":             return .voice
            default:                                            return .documents
            }
        }
    }

    /// Bytes stored per category. Categories with nothing in them are omitted, so the
    /// Storage screen only ever lists rows that are real and actionable.
    static func breakdown() -> [Category: Int] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var totals: [Category: Int] = [:]
        for url in files {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard bytes > 0 else { continue }
            totals[Category.of(fileExtension: url.pathExtension), default: 0] += bytes
        }
        return totals
    }

    /// One stored file, with everything the Storage browser needs to list it.
    struct Item: Identifiable, Hashable {
        let localName: String
        let bytes: Int
        let createdAt: Date
        let category: Category

        var id: String { localName }
        var sizeLabel: String { MediaStore.sizeLabel(bytes) }
        /// Documents keep their original name in the stored filename ("<hash>.report.pdf",
        /// or "<uuid>-report.pdf" for files stored before content addressing).
        var displayName: String {
            let name = localName
            if let dash = name.firstIndex(of: "-"), name.prefix(36).count == 36 {
                return String(name[name.index(after: dash)...])
            }
            let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? String(parts[1]) : name
        }
    }

    /// Every stored file, newest first. One directory pass — the browser sorts/filters
    /// in memory rather than hitting the filesystem per category.
    static func items() -> [Item] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let bytes = values?.fileSize ?? 0
            guard bytes > 0 else { return nil }
            return Item(localName: url.lastPathComponent,
                        bytes: bytes,
                        createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                        category: Category.of(fileExtension: url.pathExtension))
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func items(in category: Category) -> [Item] {
        items().filter { $0.category == category }
    }

    /// Delete specific files (the browser's multi-select). Returns the names actually
    /// removed so the caller can detach the messages that referenced them.
    @discardableResult
    static func delete(_ localNames: [String]) -> [String] {
        localNames.filter { name in
            (try? FileManager.default.removeItem(at: url(for: name))) != nil
        }
    }

    /// Delete every stored file in `category`.
    ///
    /// Returns the names removed so the caller can detach them from any message that
    /// referenced them — leaving a message pointing at a deleted file would render an
    /// attachment that silently fails to load.
    @discardableResult
    static func clear(_ category: Category) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed: [String] = []
        for url in files where Category.of(fileExtension: url.pathExtension) == category {
            try? FileManager.default.removeItem(at: url)
            removed.append(url.lastPathComponent)
        }
        return removed
    }
}
