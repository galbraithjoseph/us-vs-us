import CloudKit
import CoreData
import Darwin
import Foundation

enum StoreRoute: String, CaseIterable, Codable, Sendable { case `private`, shared, local }
enum PersistenceError: Error {
    case modelUnavailable
    case alreadyOpen
    case loadFailed(String)
    case missingStore(StoreRoute)
    case corrupt(String)
    case sequenceExhausted
    case operationMismatch
}

/// Immutable stack handles; managed objects never leave their private context queues.
final class StoreStack: @unchecked Sendable {
    let container: NSPersistentCloudKitContainer
    let directory: URL
    private var lockDescriptor: Int32 = -1

    static func model(version: String? = nil) throws -> NSManagedObjectModel {
        guard let root = Bundle.main.url(forResource: "UsVsUsModel", withExtension: "momd") else { throw PersistenceError.modelUnavailable }
        let url = version.map { root.appendingPathComponent("\($0).mom") } ?? root
        guard let model = NSManagedObjectModel(contentsOf: url) else { throw PersistenceError.modelUnavailable }
        return model
    }

    init(directory: URL, cloudContainerIdentifier: String? = nil) throws {
        self.directory = directory
        let model = try Self.model()
        container = NSPersistentCloudKitContainer(name: "UsVsUsModel", managedObjectModel: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lockDescriptor = Darwin.open(directory.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { throw PersistenceError.loadFailed("Cannot open writer lock") }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
            throw PersistenceError.alreadyOpen
        }
        container.persistentStoreDescriptions = StoreRoute.allCases.map { route in
            let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("\(route.rawValue).sqlite"))
            description.configuration = route == .local ? "Local" : "Mirrored"
            description.shouldAddStoreAsynchronously = false
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.setOption(["journal_mode": "WAL", "synchronous": "FULL"] as NSDictionary, forKey: NSSQLitePragmasOption)
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption((route != .local) as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            if route != .local, let cloudContainerIdentifier {
                let options = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudContainerIdentifier)
                options.databaseScope = route == .private ? .private : .shared
                description.cloudKitContainerOptions = options
            }
            return description
        }
        let result = LoadResult()
        container.loadPersistentStores { _, error in result.record(error) }
        if let error = result.error {
            try? close()
            throw PersistenceError.loadFailed(error.localizedDescription)
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
    }

    func store(_ route: StoreRoute) throws -> NSPersistentStore {
        let url = directory.appendingPathComponent("\(route.rawValue).sqlite")
        guard let store = container.persistentStoreCoordinator.persistentStore(for: url) else { throw PersistenceError.missingStore(route) }
        return store
    }

    func backgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        context.transactionAuthor = "UsVsUs"
        return context
    }

    /// Call after repository operations have drained, before opening the same directory.
    func close() throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }
    deinit {
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); Darwin.close(lockDescriptor) }
    }
}

private final class LoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    var error: Error? { lock.withLock { storedError } }
    func record(_ error: Error?) { lock.withLock { if let error { storedError = error } } }
}
