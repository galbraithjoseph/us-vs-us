import Foundation

struct Pair: Codable, Equatable, Sendable {
    let pairID: UUID
    let playerOneID: UUID
    let playerTwoID: UUID
    let createdAt: Timestamp
}
struct Player: Codable, Equatable, Sendable {
    let playerID: UUID
    let pairID: UUID
    let displayName: String
}
struct Game: Codable, Equatable, Sendable {
    let gameID: UUID
    let pairID: UUID
    let name: String
    let highScoreWins: Bool
    let isArchived: Bool
}
struct Device: Codable, Equatable, Sendable {
    let deviceID: UUID
    let pairID: UUID
    let playerID: UUID
    let createdAt: Timestamp
    let displayLabel: String?
}

enum MatchStatus: String, Codable, Sendable { case inProgress, completed, voided }
enum MatchOutcome: String, Codable, Sendable { case none, draw, win }

struct GameEvent: Codable, Equatable, Sendable {
    let eventID: UUID
    let pairID: UUID
    let gameID: UUID
    let playerOneID: UUID
    let playerTwoID: UUID
    let startedAt: Timestamp
    let finishedAt: Timestamp?
    let playerOneScore: DecimalInt64?
    let playerTwoScore: DecimalInt64?
    let highScoreWinsAtStart: Bool
    let status: MatchStatus
    let outcome: MatchOutcome
    let winnerPlayerID: UUID?
}

enum EntityType: String, Codable, Sendable { case pair, player, game, gameEvent, device }

/// Complete immutable snapshots. Codable uses an explicit discriminator and payload.
enum DomainRecord: Equatable, Sendable, Codable {
    case pair(Pair), player(Player), game(Game), gameEvent(GameEvent), device(Device)

    var entityType: EntityType {
        switch self {
        case .pair: .pair
        case .player: .player
        case .game: .game
        case .gameEvent: .gameEvent
        case .device: .device
        }
    }
    var entityID: UUID {
        switch self {
        case .pair(let v): v.pairID
        case .player(let v): v.playerID
        case .game(let v): v.gameID
        case .gameEvent(let v): v.eventID
        case .device(let v): v.deviceID
        }
    }
    var pairID: UUID {
        switch self {
        case .pair(let v): v.pairID
        case .player(let v): v.pairID
        case .game(let v): v.pairID
        case .gameEvent(let v): v.pairID
        case .device(let v): v.pairID
        }
    }
    private enum CodingKeys: String, CodingKey { case type, value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(EntityType.self, forKey: .type) {
        case .pair: self = .pair(try c.decode(Pair.self, forKey: .value))
        case .player: self = .player(try c.decode(Player.self, forKey: .value))
        case .game: self = .game(try c.decode(Game.self, forKey: .value))
        case .gameEvent: self = .gameEvent(try c.decode(GameEvent.self, forKey: .value))
        case .device: self = .device(try c.decode(Device.self, forKey: .value))
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entityType, forKey: .type)
        switch self {
        case .pair(let v): try c.encode(v, forKey: .value)
        case .player(let v): try c.encode(v, forKey: .value)
        case .game(let v): try c.encode(v, forKey: .value)
        case .gameEvent(let v): try c.encode(v, forKey: .value)
        case .device(let v): try c.encode(v, forKey: .value)
        }
    }
}
