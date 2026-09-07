import Foundation

struct DomainContext {
    var pairs: [UUID: Pair] = [:]
    var players: [UUID: Player] = [:]
    var games: [UUID: Game] = [:]
    var devices: [UUID: Device] = [:]

    func pair(_ id: UUID) throws -> Pair {
        guard let pair = pairs[id] else { throw DomainError.missingDependency(id) }
        try require(pair.pairID == id, "Pair index does not match identity")
        try DomainRecord.pair(pair).validateStructure()
        return pair
    }
    func player(_ id: UUID, in pair: Pair) throws {
        guard let player = players[id] else { throw DomainError.missingDependency(id) }
        try require(player.playerID == id && player.pairID == pair.pairID, "Player belongs to another pair")
        try require(id == pair.playerOneID || id == pair.playerTwoID, "Player is not a pair member")
        try DomainRecord.player(player).validateStructure()
    }
}

extension DomainRecord {
    func validateStructure() throws {
        switch self {
        case .pair(let pair):
            try require(pair.playerOneID != pair.playerTwoID, "Pair needs two distinct players")
        case .player(let player):
            try require(!player.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Player name is empty")
        case .game(let game):
            try require(!game.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Game name is empty")
        case .device:
            break
        case .gameEvent(let match):
            try match.validateScoresAndTimes()
        }
    }

    /// Missing dependencies are deferred, not silently accepted as valid projections.
    func validate(in context: DomainContext) throws {
        try validateStructure()
        if case .pair = self { return }
        let pair = try context.pair(pairID)
        switch self {
        case .pair: break
        case .player(let player):
            try require(player.playerID == pair.playerOneID || player.playerID == pair.playerTwoID, "Player is not a pair member")
        case .game: break
        case .device(let device):
            try context.player(device.playerID, in: pair)
        case .gameEvent(let match):
            try require(match.playerOneID == pair.playerOneID && match.playerTwoID == pair.playerTwoID, "Match player slots do not match the pair")
            try context.player(match.playerOneID, in: pair)
            try context.player(match.playerTwoID, in: pair)
            guard let game = context.games[match.gameID] else { throw DomainError.missingDependency(match.gameID) }
            try require(game.gameID == match.gameID && game.pairID == match.pairID, "Game belongs to another pair")
            try DomainRecord.game(game).validateStructure()
            // Archived games and changed rules remain valid for existing history.
        }
    }
}

extension GameEvent {
    static func start(eventID: UUID, pair: Pair, game: Game, at time: Timestamp) throws -> Self {
        try DomainRecord.pair(pair).validateStructure()
        try DomainRecord.game(game).validateStructure()
        try require(game.pairID == pair.pairID, "Game belongs to another pair")
        try require(!game.isArchived, "Cannot start an archived game")
        return Self(eventID: eventID, pairID: pair.pairID, gameID: game.gameID,
                    playerOneID: pair.playerOneID, playerTwoID: pair.playerTwoID,
                    startedAt: time, finishedAt: nil, playerOneScore: nil, playerTwoScore: nil,
                    highScoreWinsAtStart: game.highScoreWins, status: .inProgress, outcome: .none, winnerPlayerID: nil)
    }

    func completing(one: Int64, two: Int64, at time: Timestamp) throws -> Self {
        try validateScoresAndTimes()
        try require(status == .inProgress, "Only an in-progress match can complete")
        let winner = Self.winner(one: one, two: two, highScoreWins: highScoreWinsAtStart,
                                 playerOneID: playerOneID, playerTwoID: playerTwoID)
        let completed = Self(eventID: eventID, pairID: pairID, gameID: gameID,
                             playerOneID: playerOneID, playerTwoID: playerTwoID,
                             startedAt: startedAt, finishedAt: time,
                             playerOneScore: DecimalInt64(rawValue: one), playerTwoScore: DecimalInt64(rawValue: two),
                             highScoreWinsAtStart: highScoreWinsAtStart, status: .completed,
                             outcome: winner == nil ? .draw : .win, winnerPlayerID: winner)
        try completed.validateScoresAndTimes()
        return completed
    }

    private static func winner(one: Int64, two: Int64, highScoreWins: Bool, playerOneID: UUID, playerTwoID: UUID) -> UUID? {
        if one == two { return nil }
        return (highScoreWins ? one > two : one < two) ? playerOneID : playerTwoID
    }

    func validateScoresAndTimes() throws {
        try require(playerOneID != playerTwoID, "Match needs distinct players")
        if let finishedAt { try require(finishedAt >= startedAt, "Finish precedes start") }
        switch status {
        case .inProgress:
            try require(finishedAt == nil && outcome == .none && winnerPlayerID == nil, "In-progress match has a result")
        case .voided:
            try require(outcome == .none && winnerPlayerID == nil, "Voided match has an active result")
        case .completed:
            guard let one = playerOneScore, let two = playerTwoScore, finishedAt != nil else {
                throw DomainError.invalid("Completed match requires both scores and a finish time")
            }
            let winner = Self.winner(one: one.rawValue, two: two.rawValue, highScoreWins: highScoreWinsAtStart,
                                     playerOneID: playerOneID, playerTwoID: playerTwoID)
            try require(winnerPlayerID == winner && outcome == (winner == nil ? .draw : .win), "Winner/outcome disagrees with scores and snapshot rule")
        }
    }
}
