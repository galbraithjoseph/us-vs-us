import XCTest
@testable import UsVsUs

final class ReducerTests: XCTestCase {
    private func input(_ name: String) throws -> RoutedInput { try ReconciliationFixture.input(name, bundle: Bundle(for: Self.self)) }
    private func baseline() throws -> [RoutedInput] {
        try ["01-pair-create", "02-player-create", "03-player-create", "04-device-create", "05-game-create", "06-gameEvent-create"].map(input)
    }
    private func match(_ snapshot: ReconciliationSnapshot) -> EntityProjection? { snapshot.projections.first { $0.key.type == .gameEvent } }
    private func total(_ snapshot: ReconciliationSnapshot) -> ScoreboardTotal? { snapshot.totals.first { $0.gameID == nil } }

    func testShuffledRepeatedAndIncrementalDeliveryConverges() throws {
        let set = try baseline() + [input("07-gameEvent-update"), input("08-gameEvent-update"), input("09-gameEvent-update")]
        let expected = RevisionReducer.rebuild(set)
        XCTAssertEqual(match(expected)?.status, .ready)
        XCTAssertEqual(total(expected)?.playerOneWins, 1)
        XCTAssertEqual(expected.totals.first { $0.gameID != nil }?.playerOneWins, 1)
        XCTAssertEqual(total(expected)?.playerTwoWins, 0)
        var generator = DeterministicGenerator()
        for _ in 0..<60 {
            let shuffled = (set + set).shuffled(using: &generator)
            XCTAssertEqual(RevisionReducer.rebuild(shuffled), expected)
            var received: [RoutedInput] = []
            for next in shuffled {
                received.append(next)
                let partial = RevisionReducer.rebuild(received)
                XCTAssertLessThanOrEqual(partial.totals.reduce(0) { $0 + $1.playerOneWins }, 2)
            }
            XCTAssertEqual(RevisionReducer.rebuild(received), expected)
        }
    }
    func testConcurrentEditsNeedAllHeadsAndVoidDoesNotWinByTimestamp() throws {
        let base = try baseline()
        let a = try input("07-gameEvent-update"), b = try input("08-gameEvent-update")
        let conflicting = RevisionReducer.rebuild(base + [a, b])
        XCTAssertEqual(match(conflicting)?.status, .conflict)
        XCTAssertEqual(total(conflicting)?.playerOneWins, 0)
        let partialResolution = try ReconciliationFixture.changed(input("09-gameEvent-update")) { $0["parentRevisionIDs"] = ["00000000-0000-0000-0000-000000000107"] }
        XCTAssertEqual(match(RevisionReducer.rebuild(base + [a, b, partialResolution]))?.status, .conflict)
        let resolution = try input("09-gameEvent-update")
        XCTAssertEqual(total(RevisionReducer.rebuild(base + [a, b, resolution]))?.playerOneWins, 1)
        let void = try ReconciliationFixture.changed(input("10-gameEvent-void")) { $0["parentRevisionIDs"] = ["00000000-0000-0000-0000-000000000107"] }
        XCTAssertEqual(match(RevisionReducer.rebuild(base + [a, b, void]))?.status, .conflict)
        let resolvedVoid = try ReconciliationFixture.changed(void) {
            $0["revisionID"] = "00000000-0000-0000-0000-000000000111"
            $0["originSequence"] = "11"
            $0["parentRevisionIDs"] = ["00000000-0000-0000-0000-000000000108", "00000000-0000-0000-0000-000000000110"]
        }
        let final = RevisionReducer.rebuild(base + [a, b, void, resolvedVoid])
        XCTAssertEqual(match(final)?.status, .voided)
        XCTAssertEqual(total(final)?.playerOneWins, 0)
    }
    func testMissingParentsEntitiesAndUnsupportedSchemasNeverProduceWins() throws {
        let base = try baseline()
        let complete = try input("07-gameEvent-update")
        XCTAssertEqual(match(RevisionReducer.rebuild(Array(base.dropLast()) + [complete]))?.status, .pending)
        let missingGame = base.filter { (try? JSONDecoder().decode(RecordRevision.self, from: $0.bytes).entityType) != .game }
        let pending = RevisionReducer.rebuild(missingGame + [complete])
        XCTAssertEqual(match(pending)?.status, .pending)
        XCTAssertEqual(total(pending)?.playerOneWins, 0)
        let unsupported = RevisionReducer.rebuild(base + [complete, try input("unsupported-v2")])
        XCTAssertEqual(match(unsupported)?.status, .unsupported)
        XCTAssertTrue(unsupported.totals.isEmpty)
    }
    func testDrawInProgressAndVoidedResults() throws {
        let base = try baseline()
        XCTAssertEqual(total(RevisionReducer.rebuild(base))?.playerOneWins, 0)
        let draw = try ReconciliationFixture.changed(input("07-gameEvent-update")) {
            var payload = $0["payload"] as! [String: Any]
            var value = payload["value"] as! [String: Any]
            value["playerOneScore"] = "-5"; value["playerTwoScore"] = "-5"
            value["outcome"] = "draw"; value.removeValue(forKey: "winnerPlayerID")
            payload["value"] = value; $0["payload"] = payload
        }
        let drawn = RevisionReducer.rebuild(base + [draw])
        XCTAssertEqual(total(drawn)?.draws, 1)
        XCTAssertEqual(total(drawn)?.playerOneWins, 0)
        XCTAssertEqual(total(drawn)?.playerTwoWins, 0)
        let void = try ReconciliationFixture.changed(input("10-gameEvent-void")) { $0["parentRevisionIDs"] = ["00000000-0000-0000-0000-000000000107"] }
        XCTAssertEqual(total(RevisionReducer.rebuild(base + [draw, void]))?.draws, 0)
        let badWriterVoid = try ReconciliationFixture.changed(void) { $0["authorPlayerID"] = "00000000-0000-0000-0000-000000000003" }
        XCTAssertEqual(match(RevisionReducer.rebuild(base + [draw, badWriterVoid]))?.status, .quarantined)
    }
    func testMetadataConflictsDeferMatchesAndRetiredDevicesPreserveHistory() throws {
        let base = try baseline() + [input("07-gameEvent-update")]
        let originalGame = try input("05-game-create")
        func edit(_ id: Int, _ name: String, parents: [String]) throws -> RoutedInput {
            try ReconciliationFixture.changed(originalGame) {
                $0["revisionID"] = String(format: "00000000-0000-0000-0000-%012d", id)
                $0["originSequence"] = String(id)
                $0["operation"] = "update"; $0["parentRevisionIDs"] = parents
                var payload = $0["payload"] as! [String: Any]
                var value = payload["value"] as! [String: Any]
                value["name"] = name; payload["value"] = value; $0["payload"] = payload
            }
        }
        let a = try edit(200, "A", parents: ["00000000-0000-0000-0000-000000000105"])
        let b = try edit(201, "B", parents: ["00000000-0000-0000-0000-000000000105"])
        let conflicting = RevisionReducer.rebuild(base + [a, b])
        XCTAssertEqual(conflicting.projections.first { $0.key.type == .game }?.status, .conflict)
        XCTAssertEqual(match(conflicting)?.status, .pending)
        XCTAssertEqual(total(conflicting)?.playerOneWins, 0)
        let resolved = try edit(202, "Resolved", parents: ["00000000-0000-0000-0000-000000000200", "00000000-0000-0000-0000-000000000201"])
        XCTAssertEqual(total(RevisionReducer.rebuild(base + [a, b, resolved]))?.playerOneWins, 1)
        let retired = try ReconciliationFixture.changed(input("04-device-create")) {
            $0["revisionID"] = "00000000-0000-0000-0000-000000000203"
            $0["originSequence"] = "203"; $0["operation"] = "void"
            $0["parentRevisionIDs"] = ["00000000-0000-0000-0000-000000000104"]
            $0.removeValue(forKey: "payload")
        }
        let retirement = RevisionReducer.rebuild(base + [retired])
        XCTAssertEqual(retirement.projections.first { $0.key.type == .device }?.status, .voided)
        XCTAssertEqual(total(retirement)?.playerOneWins, 1)
    }

    func testCyclesInvalidParentsAndIdentityCollisionsDoNotProject() throws {
        let base = try baseline()
        let a = try ReconciliationFixture.changed(input("07-gameEvent-update")) { $0["parentRevisionIDs"] = ["00000000-0000-0000-0000-000000000108"] }
        let b = try ReconciliationFixture.changed(input("08-gameEvent-update")) { $0["parentRevisionIDs"] = ["00000000-0000-0000-0000-000000000107"] }
        let cycle = RevisionReducer.rebuild(base + [a, b])
        XCTAssertEqual(match(cycle)?.status, .quarantined)
        XCTAssertEqual(cycle.quarantined.count, 2)
        let foreign = try ReconciliationFixture.changed(input("07-gameEvent-update")) { $0["parentRevisionIDs"] = ["00000000-0000-0000-0000-000000000105"] }
        XCTAssertEqual(match(RevisionReducer.rebuild(base + [foreign]))?.status, .quarantined)
        let original = try input("07-gameEvent-update")
        let collision = try ReconciliationFixture.changed(original) { $0["recordedAt"] = "999" }
        let conflicted = RevisionReducer.rebuild(base + [original, collision])
        XCTAssertEqual(match(conflicted)?.status, .quarantined)
        XCTAssertEqual(total(conflicted)?.playerOneWins, 0)
    }
}

private struct DeterministicGenerator: RandomNumberGenerator {
    var state: UInt64 = 42
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}
