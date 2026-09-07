import CoreData
import XCTest
@testable import UsVsUs

@MainActor
final class ReconciliationPersistenceTests: XCTestCase {
    enum Injected: Error { case crash }
    private func path() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func input(_ name: String) throws -> RoutedInput { try ReconciliationFixture.input(name, bundle: Bundle(for: Self.self)) }
    private func baseline() throws -> [RoutedInput] {
        try ["01-pair-create", "02-player-create", "03-player-create", "04-device-create", "05-game-create", "06-gameEvent-create"].map(input)
    }
    private func wins(_ snapshot: ReconciliationSnapshot?) -> Int64? { snapshot?.totals.first { $0.gameID == nil }?.playerOneWins }

    func testImportRestartProjectionDeletionTokenLossAndRelayConverge() async throws {
        let a = path(), b = path()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let inputs = try baseline() + [input("07-gameEvent-update")]
        let repository = try RevisionRepository(directory: a)
        let expected = try await repository.importHistory(inputs)
        XCTAssertEqual(wins(expected), 1)
        let repeated = try await repository.importHistory(Array(inputs.reversed()) + inputs)
        XCTAssertEqual(repeated, expected)
        let raw = try await repository.revisions(in: .private)
        XCTAssertEqual(raw.count, 7)
        let relay = try RevisionRepository(directory: b)
        let relayed = raw.map { RoutedInput(pairID: inputs[0].pairID, route: .private, bytes: $0.bytes) }
        let peer = try await relay.importHistory(relayed)
        XCTAssertEqual(peer.projections, expected.projections)
        XCTAssertEqual(peer.totals, expected.totals)
        _ = try await repository.importHistory(relayed)
        try await repository.discardRebuildableState()
        let empty = try await repository.cachedSnapshot()
        XCTAssertNil(empty)
        let rebuilt = try await repository.processHistory()
        XCTAssertEqual(rebuilt, expected)
        let after = try await repository.revisions(in: .private)
        XCTAssertEqual(Set(after.map(\.bytes)), Set(raw.map(\.bytes)))
        try await repository.close()
        let reopened = try await RevisionRepository.open(directory: a)
        let cached = try await reopened.cachedSnapshot()
        XCTAssertEqual(cached, expected)
        try await reopened.close()
        try await relay.close()
    }

    func testInterruptedIngressAndProjectionTransactionsRecover() async throws {
        for stage in RebuildStage.allCases {
            let directory = path()
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = try RevisionRepository(directory: directory)
            _ = try await repository.importHistory(baseline())
            await repository.setRebuildFailureInjector { if $0 == stage { throw Injected.crash } }
            do { _ = try await repository.importHistory([input("07-gameEvent-update")]); XCTFail("Expected \(stage)") } catch Injected.crash { }
            let cached = try await repository.cachedSnapshot()
            XCTAssertEqual(wins(cached), stage == .afterProjectionSave ? 1 : 0)
            try await repository.close()
            let reopened = try await RevisionRepository.open(directory: directory)
            let recovered = try await reopened.cachedSnapshot()
            XCTAssertEqual(wins(recovered), 1)
            let rows = try await reopened.revisions(in: .private)
            XCTAssertEqual(rows.count, 7)
            try await reopened.close()
        }
    }

    func testLocalWritesRefreshProjectionsWithoutGeneratingRefreshRevisions() async throws {
        let directory = path()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try RevisionRepository(directory: directory)
        _ = try await repository.importHistory(baseline())
        let pair = try JSONDecoder().decode(RecordRevision.self, from: input("01-pair-create").bytes)
        guard case .pair(let value) = pair.payload else { return XCTFail("Pair fixture") }
        _ = try await repository.enroll(pair: value, playerID: value.playerOneID, route: .private, at: Timestamp(100))
        let completed = try JSONDecoder().decode(RecordRevision.self, from: input("07-gameEvent-update").bytes)
        let command = WriteCommand(operationID: UUID(), pair: value, authorPlayerID: value.playerOneID, route: .private,
                                   entityType: completed.entityType, entityID: completed.entityID, operation: .update,
                                   payload: completed.payload, parentRevisionIDs: completed.parentRevisionIDs, recordedAt: Timestamp(101))
        _ = try await repository.write(command)
        let cached = try await repository.cachedSnapshot()
        XCTAssertEqual(wins(cached), 1)
        let before = try await repository.revisions(in: .private)
        _ = try await repository.processHistory()
        let after = try await repository.revisions(in: .private)
        XCTAssertEqual(Set(before.map(\.bytes)), Set(after.map(\.bytes)))
        try await repository.close()
    }

    func testRemoteChangeProcessingAndIncompleteRouting() async throws {
        let directory = path()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try await RevisionRepository.open(directory: directory)
        _ = try await repository.importHistory(baseline())
        let completed = try input("07-gameEvent-update")
        let revision = try JSONDecoder().decode(RecordRevision.self, from: completed.bytes)
        let stack = await repository.stack
        let context = stack.backgroundContext()
        try context.performAndWait {
            let roots = NSFetchRequest<NSManagedObject>(entityName: "MirrorPair")
            roots.affectedStores = [try stack.store(.private)]
            let root = try XCTUnwrap(context.fetch(roots).first)
            let row = NSEntityDescription.insertNewObject(forEntityName: "MirrorRevision", into: context)
            context.assign(row, to: try stack.store(.private))
            row.setValue(revision.revisionID, forKey: "revisionID")
            row.setValue(revision.pairID, forKey: "pairID")
            row.setValue(revision.originDeviceID, forKey: "originDeviceID")
            row.setValue(revision.originSequence.rawValue, forKey: "originSequence")
            row.setValue(completed.bytes, forKey: "revisionBytes")
            row.setValue(root, forKey: "root")
            try context.save()
        }
        NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: stack.container.persistentStoreCoordinator)
        var observed = false
        for _ in 0..<100 {
            if wins(try await repository.cachedSnapshot()) == 1 { observed = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(observed)
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorRevision")
            request.predicate = NSPredicate(format: "revisionID == %@", revision.revisionID as NSUUID)
            try context.fetch(request).first?.setValue(nil, forKey: "root")
            try context.save()
        }
        let pending = try await repository.processHistory()
        XCTAssertTrue(pending.routingIncomplete)
        XCTAssertTrue(pending.totals.isEmpty)
        try context.performAndWait {
            let roots = NSFetchRequest<NSManagedObject>(entityName: "MirrorPair")
            roots.affectedStores = [try stack.store(.private)]
            let root = try XCTUnwrap(context.fetch(roots).first)
            let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorRevision")
            request.predicate = NSPredicate(format: "revisionID == %@", revision.revisionID as NSUUID)
            try context.fetch(request).first?.setValue(root, forKey: "root")
            try context.save()
        }
        let repaired = try await repository.processHistory()
        XCTAssertFalse(repaired.routingIncomplete)
        XCTAssertEqual(wins(repaired), 1)
        try await repository.close()
    }

    func testCorruptTokenAndQuarantineSurviveRebuild() async throws {
        let directory = path()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try RevisionRepository(directory: directory)
        let expected = try await repository.importHistory(baseline() + [input("07-gameEvent-update")])
        let stack = await repository.stack
        let context = stack.backgroundContext()
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "SyncCursor")
            request.predicate = NSPredicate(format: "scope == %@", "history-private")
            let row = try XCTUnwrap(context.fetch(request).first)
            row.setValue(Data("lost token".utf8), forKey: "historyToken")
            try context.save()
        }
        let replayed = try await repository.processHistory()
        XCTAssertEqual(replayed, expected)
        let unknown = try input("unsupported-v2")
        let quarantined = try await repository.importHistory([input("invalid-winner"), unknown])
        XCTAssertFalse(quarantined.quarantined.isEmpty)
        XCTAssertEqual(quarantined.unsupported, [unknown])
        XCTAssertTrue(quarantined.totals.isEmpty)
        try await repository.discardRebuildableState()
        let rebuilt = try await repository.processHistory()
        XCTAssertEqual(rebuilt, quarantined)
        try await repository.close()
    }

    func testV1ReservationsMigrateAndRecoverUnderV2() async throws {
        let directory = path()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try StoreStack.model(version: "UsVsUsModelV1")
        XCTAssertEqual(source.versionIdentifiers, ["1"])
        let fixture = try input("05-game-create")
        let revision = try JSONDecoder().decode(RecordRevision.self, from: fixture.bytes)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: source)
            let store = try coordinator.addPersistentStore(type: .sqlite, configuration: "Local", at: directory.appendingPathComponent("local.sqlite"), options: [NSPersistentHistoryTrackingKey: true])
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            try context.performAndWait {
                let row = NSEntityDescription.insertNewObject(forEntityName: "Reservation", into: context)
                context.assign(row, to: store)
                row.setValue(UUID(), forKey: "operationID")
                row.setValue(revision.revisionID, forKey: "revisionID")
                row.setValue(revision.pairID, forKey: "pairID")
                row.setValue(fixture.bytes, forKey: "revisionBytes")
                row.setValue("private", forKey: "route")
                row.setValue(true, forKey: "acknowledged")
                try context.save()
            }
            try coordinator.remove(store)
        }
        let repository = try await RevisionRepository.open(directory: directory)
        let recovered = try await repository.revisions(in: .private)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.bytes, fixture.bytes)
        try await repository.close()
    }
}
