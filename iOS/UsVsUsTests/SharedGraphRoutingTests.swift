import CoreData
import XCTest
@testable import UsVsUs

@MainActor
final class SharedGraphRoutingTests: XCTestCase {
    func testNewRevisionsStayInTheirOwnPairGraphAndStore() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = try RevisionRepository(directory: path)
        let pairs = [DomainFixture().pair, DomainFixture().pair, DomainFixture().pair]
        for (index, pair) in pairs.enumerated() {
            let route: StoreRoute = index == 0 ? .private : .shared
            _ = try await repository.enroll(pair: pair, playerID: pair.playerOneID, route: route, at: Timestamp(100))
            for _ in 0..<3 {
                let game = Game(gameID: UUID(), pairID: pair.pairID, name: "Game", highScoreWins: true, isArchived: false)
                _ = try await repository.write(WriteCommand(operationID: UUID(), pair: pair, authorPlayerID: pair.playerOneID,
                    route: route, entityType: .game, entityID: game.gameID, operation: .create, payload: .game(game),
                    parentRevisionIDs: [], recordedAt: Timestamp(101)))
            }
        }
        let stack = await repository.stack
        let context = stack.backgroundContext()
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorPair")
            let roots = try context.fetch(request)
            XCTAssertEqual(roots.count, 3)
            for root in roots {
                let pairID = try XCTUnwrap(root.value(forKey: "pairID") as? UUID)
                let revisions = try XCTUnwrap(root.value(forKey: "revisions") as? Set<NSManagedObject>)
                XCTAssertEqual(revisions.count, 4)
                for revision in revisions {
                    XCTAssertEqual(revision.value(forKey: "pairID") as? UUID, pairID)
                    XCTAssertEqual(revision.objectID.persistentStore, root.objectID.persistentStore)
                    let bytes = try XCTUnwrap(revision.value(forKey: "revisionBytes") as? Data)
                    guard case .supported(let value) = try PortableRevision.decode(bytes) else { return XCTFail() }
                    XCTAssertEqual(value.pairID, pairID)
                }
            }
            XCTAssertThrowsError(try repository.revisionRoot(pairID: UUID(), route: .shared, in: context, requireExistingSharedRoot: true)) {
                XCTAssertEqual($0 as? SharingError, .awaitingImport)
            }
            XCTAssertThrowsError(try repository.revisionRoot(pairID: pairs[0].pairID, route: .shared, in: context))
        }
        try await repository.close()
    }

    func testAccountDirectoriesAreStableAndIsolated() {
        let root = URL(fileURLWithPath: "/tmp/cloud-test")
        let a = CloudKitAccountService.directory(under: root, account: CloudAccount(recordName: "a"))
        XCTAssertEqual(a, CloudKitAccountService.directory(under: root, account: CloudAccount(recordName: "a")))
        XCTAssertNotEqual(a, CloudKitAccountService.directory(under: root, account: CloudAccount(recordName: "b")))
        XCTAssertEqual(a.deletingLastPathComponent().path, root.path)
    }
}
