import XCTest
@testable import UsVsUs

struct DomainFixture {
    let pair = Pair(pairID: UUID(), playerOneID: UUID(), playerTwoID: UUID(), createdAt: Timestamp(100))
    let gameID = UUID()
    let deviceID = UUID()
    func game(high: Bool = true, archived: Bool = false) -> Game {
        Game(gameID: gameID, pairID: pair.pairID, name: "Cards", highScoreWins: high, isArchived: archived)
    }
    var context: DomainContext {
        DomainContext(pairs: [pair.pairID: pair], players: [
            pair.playerOneID: Player(playerID: pair.playerOneID, pairID: pair.pairID, displayName: "One"),
            pair.playerTwoID: Player(playerID: pair.playerTwoID, pairID: pair.pairID, displayName: "Two")
        ], games: [gameID: game()], devices: [deviceID: Device(deviceID: deviceID, pairID: pair.pairID, playerID: pair.playerOneID, createdAt: Timestamp(100), displayLabel: nil)])
    }
    func start(high: Bool = true) throws -> GameEvent {
        try .start(eventID: UUID(), pair: pair, game: game(high: high), at: Timestamp(100))
    }
}

final class ScoringTests: XCTestCase {
    func testHighLowDrawNegativeAndInt64Boundaries() throws {
        let f = DomainFixture()
        for high in [true, false] {
            for (one, two) in [(Int64.min, Int64.max), (Int64.max, Int64.min), (-5, -10), (-10, -5), (0, 0), (Int64.max, Int64.max), (Int64.min, Int64.min)] {
                let match = try f.start(high: high).completing(one: one, two: two, at: Timestamp(100))
                try DomainRecord.gameEvent(match).validate(in: f.context)
                let expected: UUID? = one == two ? nil : ((high ? one > two : one < two) ? f.pair.playerOneID : f.pair.playerTwoID)
                XCTAssertEqual(match.winnerPlayerID, expected)
                XCTAssertEqual(match.outcome, expected == nil ? .draw : .win)
            }
        }
    }
    func testRuleEditAndArchiveDoNotChangeExistingMatch() throws {
        let f = DomainFixture()
        let start = try f.start()
        var context = f.context
        context.games[f.gameID] = f.game(high: false, archived: true)
        let finished = try start.completing(one: 10, two: 1, at: Timestamp(101))
        try DomainRecord.gameEvent(finished).validate(in: context)
        XCTAssertEqual(finished.winnerPlayerID, f.pair.playerOneID)
        XCTAssertTrue(finished.highScoreWinsAtStart)
        XCTAssertThrowsError(try GameEvent.start(eventID: UUID(), pair: f.pair, game: f.game(archived: true), at: Timestamp(100)))
        XCTAssertThrowsError(try finished.completing(one: 0, two: 1, at: Timestamp(102)))
    }
    func testMissingScoresFinishInvalidTimesAndWinnersAreRejected() throws {
        let f = DomainFixture()
        let finished = try f.start().completing(one: 10, two: 1, at: Timestamp(101))
        // Mutate the portable representation to exercise hostile imported fields.
        let good = try JSONEncoder().encode(finished)
        for (key, value) in [("playerOneScore", NSNull()), ("playerTwoScore", NSNull()), ("finishedAt", NSNull()),
                             ("finishedAt", "99"), ("winnerPlayerID", f.pair.playerTwoID.uuidString),
                             ("winnerPlayerID", UUID().uuidString), ("winnerPlayerID", NSNull()), ("outcome", "draw")] as [(String, Any)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
            object[key] = value
            let bad = try JSONDecoder().decode(GameEvent.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try bad.validateScoresAndTimes(), key)
        }
        XCTAssertThrowsError(try f.start().completing(one: 1, two: 2, at: Timestamp(99)))
    }
    func testInProgressAndVoidedHaveNoActiveWinner() throws {
        let f = DomainFixture()
        let start = try f.start()
        try start.validateScoresAndTimes()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(start)) as? [String: Any])
        object["playerOneScore"] = "-3"
        try JSONDecoder().decode(GameEvent.self, from: JSONSerialization.data(withJSONObject: object)).validateScoresAndTimes()
        object["winnerPlayerID"] = f.pair.playerOneID.uuidString
        for status in ["inProgress", "voided"] {
            object["status"] = status
            XCTAssertThrowsError(try JSONDecoder().decode(GameEvent.self, from: JSONSerialization.data(withJSONObject: object)).validateScoresAndTimes())
        }
        object.removeValue(forKey: "winnerPlayerID")
        try JSONDecoder().decode(GameEvent.self, from: JSONSerialization.data(withJSONObject: object)).validateScoresAndTimes()
    }
    func testDuplicateSlotsAndCrossPairReferencesFail() throws {
        let f = DomainFixture()
        let other = DomainFixture()
        let badPair = Pair(pairID: f.pair.pairID, playerOneID: f.pair.playerOneID, playerTwoID: f.pair.playerOneID, createdAt: Timestamp(100))
        XCTAssertThrowsError(try DomainRecord.pair(badPair).validateStructure())
        XCTAssertThrowsError(try GameEvent.start(eventID: UUID(), pair: f.pair, game: other.game(), at: Timestamp(100)))
        let start = try f.start()
        var badSlots = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(start)) as? [String: Any])
        badSlots["playerTwoID"] = f.pair.playerOneID.uuidString
        XCTAssertThrowsError(try JSONDecoder().decode(GameEvent.self, from: JSONSerialization.data(withJSONObject: badSlots)).validateScoresAndTimes())
        badSlots["playerOneID"] = f.pair.playerTwoID.uuidString
        let swapped = try JSONDecoder().decode(GameEvent.self, from: JSONSerialization.data(withJSONObject: badSlots))
        XCTAssertThrowsError(try DomainRecord.gameEvent(swapped).validate(in: f.context))
        let event = DomainRecord.gameEvent(start)
        var context = f.context
        context.games[f.gameID] = Game(gameID: f.gameID, pairID: other.pair.pairID, name: "Other", highScoreWins: true, isArchived: false)
        XCTAssertThrowsError(try event.validate(in: context))
        context = f.context
        context.players[f.pair.playerOneID] = Player(playerID: f.pair.playerOneID, pairID: other.pair.pairID, displayName: "Other")
        XCTAssertThrowsError(try event.validate(in: context))
        XCTAssertThrowsError(try DomainRecord.player(Player(playerID: UUID(), pairID: f.pair.pairID, displayName: "Third")).validate(in: f.context))
        context = f.context
        context.games = [:]
        XCTAssertThrowsError(try event.validate(in: context)) { XCTAssertEqual($0 as? DomainError, .missingDependency(f.gameID)) }
    }
}
