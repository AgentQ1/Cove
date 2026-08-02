//
//  FirebaseStorageService.swift
//  Inditalk
//
//  Media upload/download via Firebase Storage. For E2EE chats, encrypt the media
//  bytes on-device (CryptoService.seal) BEFORE upload and store only ciphertext —
//  the download URL then points at an encrypted blob the server can't read. The
//  symmetric media key travels inside the (already E2EE) message envelope.
//
//  REQUIRES: FirebaseStorage SPM package + Storage enabled in the console.
//

import Foundation
import FirebaseStorage
import FirebaseAuth

// Not @MainActor: the Storage SDK is thread-safe, and staying off the main actor
// avoids Swift 6 "sending non-Sendable StorageReference across actor boundary" errors.
// State is immutable (a single `let`), so @unchecked Sendable is sound.
final class FirebaseStorageService: @unchecked Sendable {
    static let shared = FirebaseStorageService()
    private let storage = Storage.storage()

    private var uid: String? { Auth.auth().currentUser?.uid }

    /// Upload bytes (ideally already-encrypted) and return the download URL string.
    /// `path` is a stable key like "chats/<chatId>/<messageId>.bin".
    func upload(_ data: Data, path: String, contentType: String = "application/octet-stream") async throws -> String {
        let ref = storage.reference().child(path)
        let meta = StorageMetadata()
        meta.contentType = contentType
        _ = try await ref.putDataAsync(data, metadata: meta)
        let url = try await ref.downloadURL()
        return url.absoluteString
    }

    func download(path: String, maxBytes: Int64 = 25 * 1024 * 1024) async throws -> Data {
        let ref = storage.reference().child(path)
        return try await ref.data(maxSize: maxBytes)
    }

    /// Convenience path for a chat attachment. The uploader's uid is embedded in the
    /// path so Storage rules can enforce attributable writes (see storage.rules).
    func attachmentPath(chatId: String, messageId: String, ext: String) -> String {
        "chats/\(chatId)/\(uid ?? "anon")/\(messageId).\(ext)"
    }

    /// Path for a status photo/video. Owner-writable, any-signed-in readable — the same
    /// broadcast model as avatars (see storage.rules).
    func statusPath(statusId: String, ext: String) -> String {
        "status/\(uid ?? "anon")/\(statusId).\(ext)"
    }

    enum StorageError: Error { case notSignedIn }

    /// Upload the profile photo to the owner-writable avatars/{uid}/ folder
    /// (storage.rules) and return its download URL for the users/{uid} doc.
    func uploadAvatar(_ data: Data) async throws -> String {
        guard let uid else { throw StorageError.notSignedIn }
        return try await upload(data, path: avatarPath, contentType: "image/jpeg")
    }

    private var avatarPath: String { "avatars/\(uid ?? "anon")/avatar.jpg" }

    /// Remove the uploaded profile photo itself.
    ///
    /// Clearing users/{uid}.avatarURL stops NEW readers finding the photo, but the
    /// download URL keeps working for anyone who already has it (their client cached it,
    /// and the object is still readable). Hiding the photo therefore has to delete the
    /// object, not just the pointer.
    func deleteAvatar() async throws {
        guard uid != nil else { throw StorageError.notSignedIn }
        do {
            try await delete(path: avatarPath)
        } catch {
            // "Object not found" just means there was nothing to hide.
            let code = StorageErrorCode(rawValue: (error as NSError).code)
            guard code == .objectNotFound else { throw error }
        }
    }

    func delete(path: String) async throws {
        try await storage.reference().child(path).delete()
    }
}
