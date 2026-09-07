import Foundation

enum RevisionOperation: String, Codable, Sendable { case create, update, void }

struct RecordRevision: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let revisionID: UUID
    let pairID: UUID
    let entityType: EntityType
    let entityID: UUID
    let originDeviceID: UUID
    let originSequence: DecimalInt64
    let authorPlayerID: UUID
    let recordedAt: Timestamp
    let parentRevisionIDs: [UUID]
    let operation: RevisionOperation
    let payload: DomainRecord?

    func validateStructure() throws {
        try require(schemaVersion == 1, "Unsupported revision schema")
        try require(originSequence.rawValue > 0, "Origin sequence must be positive")
        try require(Set(parentRevisionIDs).count == parentRevisionIDs.count, "Duplicate revision parents")
        try require(parentRevisionIDs.map(\.uuidString) == parentRevisionIDs.map(\.uuidString).sorted(), "Parents must be sorted by UUID")
        try require(!parentRevisionIDs.contains(revisionID), "Revision cannot parent itself")
        try require(operation == .create ? parentRevisionIDs.isEmpty : !parentRevisionIDs.isEmpty, "Invalid parents for operation")
        if operation == .void {
            try require(payload == nil, "Tombstone must not contain a payload")
        } else {
            guard let payload else { throw DomainError.invalid("Snapshot payload is required") }
            try require(payload.entityType == entityType && payload.entityID == entityID && payload.pairID == pairID, "Envelope and payload identities disagree")
            try payload.validateStructure()
        }
    }

    /// Call only once dependencies are present. Missing parents remain pending.
    func validateParents(in revisions: [UUID: RecordRevision]) throws {
        try validateStructure()
        for id in parentRevisionIDs {
            guard let parent = revisions[id] else { throw DomainError.missingDependency(id) }
            try parent.validateStructure()
            try require(parent.revisionID == id && parent.entityID == entityID && parent.entityType == entityType && parent.pairID == pairID, "Parent belongs to another record")
            try require(parent.operation != .void || operation == .void, "Tombstones cannot be resurrected")
            if let old = parent.payload, let new = payload {
                switch (old, new) {
                case (.pair(let a), .pair(let b)):
                    try require(a.playerOneID == b.playerOneID && a.playerTwoID == b.playerTwoID && a.createdAt == b.createdAt, "Pair membership and creation time are immutable")
                case (.device(let a), .device(let b)):
                    try require(a.playerID == b.playerID && a.createdAt == b.createdAt, "Device enrollment is immutable")
                case (.gameEvent(let a), .gameEvent(let b)):
                    try require(a.gameID == b.gameID && a.playerOneID == b.playerOneID && a.playerTwoID == b.playerTwoID && a.highScoreWinsAtStart == b.highScoreWinsAtStart, "Match participants, game, and rule snapshot are immutable")
                default: break
                }
            }
        }
        // DAG cycle detection, ancestry/head selection, and competing-create detection
        // require the full revision graph and belong to reconciliation (issue #5).
    }

    func validateReferences(in context: DomainContext) throws {
        try validateWriter(in: context)
        try payload?.validate(in: context)
    }

    func validateWriter(in context: DomainContext) throws {
        try validateStructure()
        let pair = try context.pair(pairID)
        try context.player(authorPlayerID, in: pair)
        guard let device = context.devices[originDeviceID] else { throw DomainError.missingDependency(originDeviceID) }
        try require(device.deviceID == originDeviceID && device.pairID == pairID && device.playerID == authorPlayerID, "Writer does not belong to the author/pair")
        // These UUID relationships validate data consistency, not transport authorization.
    }
}

enum PortableRevision: Equatable {
    case supported(RecordRevision)
    case unsupported(schemaVersion: Int, bytes: Data)

    static func decode(_ data: Data) throws -> Self {
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        let version = try decoder.decode(Header.self, from: data).schemaVersion
        try require(version > 0, "Schema version must be positive")
        guard version == 1 else { return .unsupported(schemaVersion: version, bytes: data) }
        let revision = try decoder.decode(RecordRevision.self, from: data)
        try revision.validateStructure()
        try rejectUnknownFields(data, type: revision.entityType)
        return .supported(revision)
    }

    func encoded() throws -> Data {
        switch self {
        case .unsupported(_, let data): return data
        case .supported(let revision):
            try revision.validateStructure()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(revision)
        }
    }

    private static func rejectUnknownFields(_ data: Data, type: EntityType) throws {
        func check(_ object: [String: Any], _ keys: String) throws {
            try require(Set(object.keys).isSubset(of: Set(keys.split(separator: " ").map(String.init))), "Unknown version-1 field; use a new schema version")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DomainError.invalid("Revision must be an object")
        }
        try check(object, "schemaVersion revisionID pairID entityType entityID originDeviceID originSequence authorPlayerID recordedAt parentRevisionIDs operation payload")
        guard let payload = object["payload"] as? [String: Any] else { return }
        try check(payload, "type value")
        guard let value = payload["value"] as? [String: Any] else { throw DomainError.invalid("Snapshot must be an object") }
        switch type {
        case .pair: try check(value, "pairID playerOneID playerTwoID createdAt")
        case .player: try check(value, "playerID pairID displayName")
        case .game: try check(value, "gameID pairID name highScoreWins isArchived")
        case .gameEvent: try check(value, "eventID pairID gameID playerOneID playerTwoID startedAt finishedAt playerOneScore playerTwoScore highScoreWinsAtStart status outcome winnerPlayerID")
        case .device: try check(value, "deviceID pairID playerID createdAt displayLabel")
        }
    }
}
