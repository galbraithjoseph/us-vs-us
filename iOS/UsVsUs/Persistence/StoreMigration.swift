import CoreData
import Foundation

/// Explicit staging harness for future version upgrades. Never mutates the source.
/// Call only while the store is closed and the caller holds its writer lock.
enum StoreMigration {
    static func migrateCopy(from source: URL, to destination: URL,
                            sourceModel: NSManagedObjectModel, destinationModel: NSManagedObjectModel,
                            configuration: String) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw PersistenceError.loadFailed("Migration requires a new staging path")
        }
        let old = sourceModel
        let new = destinationModel
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: source)
        guard old.isConfiguration(withName: configuration, compatibleWithStoreMetadata: metadata) else {
            throw PersistenceError.loadFailed("Source model does not match migration input")
        }
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: old, destinationModel: new)
        let manager = NSMigrationManager(sourceModel: old, destinationModel: new)
        manager.usesStoreSpecificMigrationManager = false
        try manager.migrateStore(from: source, sourceType: NSSQLiteStoreType, options: nil,
                                 with: mapping, toDestinationURL: destination, destinationType: NSSQLiteStoreType,
                                 destinationOptions: nil)
        let migrated = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: destination)
        guard new.isConfiguration(withName: configuration, compatibleWithStoreMetadata: migrated) else {
            throw PersistenceError.loadFailed("Migrated store did not validate")
        }
        // Promotion is deliberately separate; future migrations must verify their
        // data invariants before coordinator-managed replacement of each store.
    }

}
