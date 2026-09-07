import CoreData
import XCTest
@testable import UsVsUs

final class StoreMigrationTests: XCTestCase {
    func testBaselineCanMigrateToAdditiveModelWithoutLosingSourceOrValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        do {
            let stack = try StoreStack(directory: directory)
            defer { try? stack.close() }
            let context = stack.backgroundContext()
            try context.performAndWait {
                let object = NSEntityDescription.insertNewObject(forEntityName: "Projection", into: context)
                context.assign(object, to: try stack.store(.local))
                object.setValue(id, forKey: "entityID")
                object.setValue(Data("retained".utf8), forKey: "snapshotBytes")
                try context.save()
            }
        }
        let source = try StoreStack.model()
        let archive = try NSKeyedArchiver.archivedData(withRootObject: source, requiringSecureCoding: true)
        let destination = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: NSManagedObjectModel.self, from: archive))
        destination.versionIdentifiers = ["test-next-version"]
        let entity = try XCTUnwrap(destination.entitiesByName["Projection"])
        let added = NSAttributeDescription()
        added.name = "futureOptionalLabel"
        added.attributeType = .stringAttributeType
        added.isOptional = true
        entity.properties.append(added)
        let original = directory.appendingPathComponent("local.sqlite")
        let migrated = directory.appendingPathComponent("staged.sqlite")
        try StoreMigration.migrateCopy(from: original, to: migrated, sourceModel: source,
                                       destinationModel: destination, configuration: "Local")
        let sourceMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: original)
        XCTAssertTrue(source.isConfiguration(withName: "Local", compatibleWithStoreMetadata: sourceMetadata))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: destination)
        let store = try coordinator.addPersistentStore(type: .sqlite, configuration: "Local", at: migrated)
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let rows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Projection"))
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.value(forKey: "entityID") as? UUID, id)
            XCTAssertEqual(rows.first?.value(forKey: "snapshotBytes") as? Data, Data("retained".utf8))
            XCTAssertNil(rows.first?.value(forKey: "futureOptionalLabel"))
        }
        XCTAssertThrowsError(try StoreMigration.migrateCopy(from: original, to: original, sourceModel: source, destinationModel: destination, configuration: "Local"))
        XCTAssertThrowsError(try StoreMigration.migrateCopy(from: original, to: migrated, sourceModel: source, destinationModel: destination, configuration: "Local"))
    }
}
