import CoreData
import XCTest
@testable import UsVsUs

@MainActor
final class RevisionRepositoryTests: XCTestCase {
    enum Injected: Error { case crash }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func command(_ f: DomainFixture, id: UUID = UUID(), route: StoreRoute = .private) -> WriteCommand {
        WriteCommand(operationID: id, pair: f.pair, authorPlayerID: f.pair.playerOneID, route: route,
                     entityType: .game, entityID: f.gameID, operation: .create, payload: .game(f.game()),
                     parentRevisionIDs: [], recordedAt: Timestamp(101))
    }
    private func records(_ repository: RevisionRepository, route: StoreRoute = .private) async throws -> [RecordRevision] {
        try await repository.revisions(in: route).map {
            guard case .supported(let revision) = try PortableRevision.decode($0.bytes) else { throw Injected.crash }
            return revision
        }
    }

    func testFailuresAtEveryDurableBoundaryRecoverWithoutDuplicatesOrLoss() async throws {
        for stage in WriteStage.allCases {
            let path = directory()
            defer { try? FileManager.default.removeItem(at: path) }
            let f = DomainFixture()
            let input = command(f)
            let repository = try RevisionRepository(directory: path)
            let device = try await repository.enroll(pair: f.pair, playerID: f.pair.playerOneID, route: .private, at: Timestamp(100))
            await repository.setFailureInjector { if $0 == stage { throw Injected.crash } }
            do { _ = try await repository.write(input); XCTFail("Expected \(stage)") } catch Injected.crash { }
            let before = try await records(repository).filter { $0.entityType == .game }
            try await repository.close()
            let reopened = try RevisionRepository(directory: path)
            try await reopened.recover()
            let restored = try await records(reopened).filter { $0.entityType == .game }
            if stage == .beforeReservation {
                XCTAssertTrue(restored.isEmpty)
                let newDevice = try await reopened.enroll(pair: f.pair, playerID: f.pair.playerOneID, route: .private, at: Timestamp(102))
                XCTAssertNotEqual(newDevice.deviceID, device.deviceID)
            } else {
                XCTAssertEqual(restored.count, 1, "\(stage)")
                XCTAssertEqual(restored.first?.originDeviceID, device.deviceID)
                XCTAssertEqual(restored.first?.originSequence.rawValue, 2)
                if let original = before.first { XCTAssertEqual(restored.first, original) }
            }
            let retry = try await reopened.write(input)
            let acknowledged = try await reopened.isAcknowledged(input.operationID)
            XCTAssertTrue(acknowledged)
            try await reopened.recover()
            let final = try await records(reopened).filter { $0.entityType == .game }
            XCTAssertEqual(final, [retry])
            try await reopened.close()
        }
    }

    func testConcurrentWritesUseUniqueMonotonicSequencesAndRetryKeepsIdentity() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let f = DomainFixture()
        let repository = try RevisionRepository(directory: path)
        _ = try await repository.enroll(pair: f.pair, playerID: f.pair.playerOneID, route: .private, at: Timestamp(100))
        let inputs = (0..<20).map { _ in command(f) }
        let revisions = try await withThrowingTaskGroup(of: RecordRevision.self) { group in
            for input in inputs { group.addTask { try await repository.write(input) } }
            var values: [RecordRevision] = []
            for try await revision in group { values.append(revision) }
            return values
        }
        XCTAssertEqual(Set(revisions.map(\.revisionID)).count, 20)
        XCTAssertEqual(revisions.map(\.originSequence.rawValue).sorted(), Array(2...21).map(Int64.init))
        let retry = try await repository.write(inputs[0])
        XCTAssertTrue(revisions.contains(retry))
        let count = try await records(repository).count
        XCTAssertEqual(count, 21) // enrollment plus 20 writes
        try await repository.close()
    }

    func testCorrectRoutingAndNoCrossStoreRelationships() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = try RevisionRepository(directory: path)
        for route in [StoreRoute.private, .shared] {
            let f = DomainFixture()
            _ = try await repository.enroll(pair: f.pair, playerID: f.pair.playerOneID, route: route, at: Timestamp(100))
            let revision = try await repository.write(command(f, route: route))
            let stored = try await records(repository, route: route)
            XCTAssertTrue(stored.contains(revision))
            XCTAssertEqual(stored.count, 2)
        }
        try await repository.close()
        let stack = try StoreStack(directory: path)
        defer { try? stack.close() }
        let context = stack.backgroundContext()
        try context.performAndWait {
            for row in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "MirrorRevision")) {
                let root = try XCTUnwrap(row.value(forKey: "root") as? NSManagedObject)
                XCTAssertTrue(root.objectID.persistentStore === row.objectID.persistentStore)
            }
            for name in ["Reservation", "Enrollment"] {
                for row in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) {
                    XCTAssertTrue(row.objectID.persistentStore === (try stack.store(.local)))
                }
            }
        }
    }

    func testCopiedBackupStartsNewWriterAndRepairsMissingMirroredHistory() async throws {
        let path = directory(), copy = directory()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: copy) }
        let f = DomainFixture()
        let original = try RevisionRepository(directory: path)
        let firstDevice = try await original.enroll(pair: f.pair, playerID: f.pair.playerOneID, route: .private, at: Timestamp(100))
        let firstRevision = try await original.write(command(f))
        try await original.close()
        try FileManager.default.copyItem(at: path, to: copy)
        // Emulate a backup with a committed receipt but an older/missing mirror.
        for suffix in ["", "-wal", "-shm"] {
            let file = copy.appendingPathComponent("private.sqlite\(suffix)")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        let restored = try RevisionRepository(directory: copy)
        try await restored.recover()
        let recovered = try await records(restored)
        XCTAssertTrue(recovered.contains(firstRevision))
        let newDevice = try await restored.enroll(pair: f.pair, playerID: f.pair.playerOneID, route: .private, at: Timestamp(102))
        XCTAssertNotEqual(newDevice.deviceID, firstDevice.deviceID)
        let next = try await restored.write(command(f))
        XCTAssertEqual(next.originDeviceID, newDevice.deviceID)
        XCTAssertEqual(next.originSequence.rawValue, 2)
        try await restored.close()
        let reopenedOriginal = try RevisionRepository(directory: path)
        let originalNewDevice = try await reopenedOriginal.enroll(pair: f.pair, playerID: f.pair.playerOneID, route: .private, at: Timestamp(103))
        XCTAssertNotEqual(originalNewDevice.deviceID, newDevice.deviceID)
        XCTAssertNotEqual(originalNewDevice.deviceID, firstDevice.deviceID)
        try await reopenedOriginal.close()
    }

    func testInvalidWritesRollbackAndOperationIDsCannotChangeMeaning() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let f = DomainFixture()
        let repository = try RevisionRepository(directory: path)
        _ = try await repository.enroll(pair: f.pair, playerID: f.pair.playerOneID, route: .private, at: Timestamp(100))
        let invalid = WriteCommand(operationID: UUID(), pair: f.pair, authorPlayerID: f.pair.playerOneID,
                                   route: .private, entityType: .game, entityID: UUID(), operation: .create,
                                   payload: .game(f.game()), parentRevisionIDs: [], recordedAt: Timestamp(101))
        do { _ = try await repository.write(invalid); XCTFail("Expected invalid payload") } catch { }
        let input = command(f)
        let revision = try await repository.write(input)
        XCTAssertEqual(revision.originSequence.rawValue, 2)
        do {
            _ = try await repository.enroll(pair: f.pair, playerID: f.pair.playerOneID, route: .shared, at: Timestamp(102))
            XCTFail("An enrollment must not silently switch stores")
        } catch PersistenceError.operationMismatch { }
        do { _ = try await repository.write(command(f, route: .shared)); XCTFail("Expected wrong route rejection") } catch PersistenceError.operationMismatch { }
        let changed = command(f, id: input.operationID, route: .shared)
        do { _ = try await repository.write(changed); XCTFail("Expected operation mismatch") } catch PersistenceError.operationMismatch { }
        try await repository.close()
    }
}
