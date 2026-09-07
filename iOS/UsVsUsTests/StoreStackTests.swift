import CoreData
import XCTest
@testable import UsVsUs

final class StoreStackTests: XCTestCase {
    func testVersionedModelMeetsMirroringConstraints() throws {
        let model = try StoreStack.model()
        XCTAssertEqual(model.versionIdentifiers, ["1"])
        let mirrored = try XCTUnwrap(model.entities(forConfigurationName: "Mirrored"))
        XCTAssertEqual(Set(mirrored.compactMap(\.name)), ["MirrorPair", "MirrorRevision"])
        for entity in mirrored {
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
            for attribute in entity.attributesByName.values { XCTAssertTrue(attribute.isOptional || attribute.defaultValue != nil) }
            for relationship in entity.relationshipsByName.values {
                XCTAssertTrue(relationship.isOptional)
                XCTAssertFalse(relationship.isOrdered)
                XCTAssertNotNil(relationship.inverseRelationship)
                XCTAssertTrue(mirrored.contains { $0 === relationship.destinationEntity })
            }
        }
        let local = try XCTUnwrap(model.entities(forConfigurationName: "Local"))
        XCTAssertEqual(Set(local.compactMap(\.name)), ["Enrollment", "Reservation", "Projection", "SyncCursor"])
        XCTAssertTrue(local.allSatisfy { $0.relationshipsByName.isEmpty })
    }

    func testOnDiskRoutingAndBaselineReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairID = UUID()
        do {
            let stack = try StoreStack(directory: directory)
            defer { try? stack.close() }
            XCTAssertThrowsError(try StoreStack(directory: directory))
            XCTAssertTrue(stack.container.persistentStoreDescriptions.allSatisfy { $0.cloudKitContainerOptions == nil })
            for route in [StoreRoute.private, .shared] {
                let context = stack.backgroundContext()
                try context.performAndWait {
                    let root = NSEntityDescription.insertNewObject(forEntityName: "MirrorPair", into: context)
                    root.setValue(pairID, forKey: "pairID")
                    context.assign(root, to: try stack.store(route))
                    try context.save()
                }
            }
        }
        let reopened = try StoreStack(directory: directory)
        defer { try? reopened.close() }
        let context = reopened.backgroundContext()
        try context.performAndWait {
            for route in [StoreRoute.private, .shared] {
                let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorPair")
                request.affectedStores = [try reopened.store(route)]
                let rows = try context.fetch(request)
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows.first?.value(forKey: "pairID") as? UUID, pairID)
                XCTAssertTrue(rows.first?.objectID.persistentStore === (try reopened.store(route)))
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: directory.appendingPathComponent("\(route.rawValue).sqlite"))
                XCTAssertTrue(try StoreStack.model().isConfiguration(withName: "Mirrored", compatibleWithStoreMetadata: metadata))
            }
        }
    }

    func testLoadFailureDoesNotEraseOrReplaceInvalidStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("private.sqlite")
        let bytes = Data("not a database".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try StoreStack(directory: directory))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
