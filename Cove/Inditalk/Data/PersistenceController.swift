//
//  PersistenceController.swift
//  Inditalk
//
//  Owns the SwiftData ModelContainer. `.shared` is the on-disk store used by the app;
//  `.inMemory()` is an ephemeral store used by tests and previews so they stay
//  deterministic and never touch the user's data.
//

import Foundation
import SwiftData

enum PersistenceController {

    /// All persistent model types in Inditalk's schema.
    static let schema = Schema([
        PersistedUser.self,
        PersistedChat.self,
        PersistedMessage.self,
        PersistedCall.self,
        PersistedStatus.self,
        PersistedScheduledCall.self,
    ])

    /// On-disk container for the running app.
    static let shared: ModelContainer = {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // A schema migration failure shouldn't crash the app on launch; fall back
            // to a fresh in-memory store and log. Production adds a VersionedSchema
            // migration plan (see docs/ARCHITECTURE.md).
            assertionFailure("Persistent store failed to load: \(error). Falling back to memory.")
            return inMemoryContainer()
        }
    }()

    /// Fresh ephemeral container (tests, previews).
    static func inMemoryContainer() -> ModelContainer {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // Force-try is acceptable here: an in-memory container has no external
        // dependency that can realistically fail.
        return try! ModelContainer(for: schema, configurations: config)
    }
}
