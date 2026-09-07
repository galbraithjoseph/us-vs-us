import Foundation

enum ProjectionStatus: String, Codable, Sendable { case ready, pending, conflict, voided, quarantined, unsupported }
struct EntityProjection: Codable, Equatable, Sendable {
    let key: RecordKey
    var status: ProjectionStatus
    let headIDs: [UUID]
    var record: DomainRecord?
}
struct ScoreboardTotal: Codable, Equatable, Sendable {
    let pairID: UUID
    let gameID: UUID?
    let playerOneID: UUID
    let playerTwoID: UUID
    var playerOneWins: Int64 = 0
    var playerTwoWins: Int64 = 0
    var draws: Int64 = 0
    var sortKey: String { pairID.uuidString + (gameID?.uuidString ?? "") }
}
struct ReconciliationSnapshot: Codable, Equatable, Sendable {
    let projections: [EntityProjection]
    let totals: [ScoreboardTotal]
    let ranges: [OriginRanges]
    let quarantined: [QuarantinedInput]
    let unsupported: [RoutedInput]
}

enum RevisionReducer {
    private enum NodeStatus { case valid, pending, invalid }

    static func rebuild(_ inputs: [RoutedInput]) -> ReconciliationSnapshot {
        let ingested = RevisionIngestion.ingest(inputs)
        let records = ingested.records
        let states = graphStates(records)
        let groups = Dictionary(grouping: records.values, by: \.key)
        let historical = historicalContext(records, states: states)
        var missingWriters = Set<RecordKey>()
        var invalidWriters = Set<UUID>()
        for revision in records.values where states[revision.revisionID] != .invalid {
            do { try revision.validateWriter(in: historical) }
            catch {
                if case DomainError.missingDependency = error { missingWriters.insert(revision.key) }
                else { invalidWriters.insert(revision.revisionID) }
            }
        }
        let unsupportedPairs = Set(ingested.unsupported.map(\.pairID))
        var keys = Set(groups.keys).union(ingested.poisonedRecords)
        keys.formUnion(unsupportedPairs.map { RecordKey(pairID: $0, type: .pair, entityID: $0) })
        var projections: [EntityProjection] = keys.sorted().map { key in
            let revisions = groups[key] ?? []
            let superseded = Set(revisions.filter { states[$0.revisionID] != .invalid }.flatMap(\.parentRevisionIDs))
            let heads = revisions.filter { !superseded.contains($0.revisionID) }.sorted { $0.revisionID.uuidString < $1.revisionID.uuidString }
            let status: ProjectionStatus
            if unsupportedPairs.contains(key.pairID) { status = .unsupported }
            else if ingested.poisonedRecords.contains(key) || revisions.contains(where: { states[$0.revisionID] == .invalid || invalidWriters.contains($0.revisionID) }) { status = .quarantined }
            else if missingWriters.contains(key) || revisions.contains(where: { states[$0.revisionID] == .pending }) || heads.isEmpty { status = .pending }
            else if heads.count > 1 { status = .conflict }
            else if heads[0].operation == .void { status = .voided }
            else { status = .ready }
            return EntityProjection(key: key, status: status, headIDs: heads.map(\.revisionID), record: status == .ready ? heads.first?.payload : nil)
        }

        // Monotone dependency filtering terminates: projections only move from
        // ready to unavailable. Rebuild starts afresh when more history arrives.
        var referenceInvalidIDs = invalidWriters
        var changed = true
        while changed {
            changed = false
            let context = makeContext(projections, records: records, states: states)
            for index in projections.indices where projections[index].status == .ready {
                let revisions = (groups[projections[index].key] ?? []).sorted { $0.revisionID.uuidString < $1.revisionID.uuidString }
                for revision in revisions {
                    do { try revision.validateReferences(in: context) }
                    catch {
                        if case DomainError.missingDependency = error { projections[index].status = .pending }
                        else { projections[index].status = .quarantined; referenceInvalidIDs.insert(revision.revisionID) }
                        projections[index].record = nil
                        changed = true
                        break
                    }
                }
            }
        }
        let invalidIDs = Set(states.filter { $0.value == .invalid }.map(\.key)).union(referenceInvalidIDs)
        var quarantine = ingested.quarantined
        for input in Set(inputs).sorted(by: { $0.sortKey < $1.sortKey }) {
            if let revision = try? JSONDecoder().decode(RecordRevision.self, from: input.bytes), invalidIDs.contains(revision.revisionID) {
                quarantine.append(QuarantinedInput(input: input, reason: "invalidRevisionGraphOrReferences"))
            }
        }
        quarantine.sort { $0.input.sortKey + $0.reason < $1.input.sortKey + $1.reason }
        return ReconciliationSnapshot(projections: projections, totals: totals(projections), ranges: ingested.ranges,
                                      quarantined: quarantine, unsupported: ingested.unsupported)
    }

    private static func graphStates(_ records: [UUID: RecordRevision]) -> [UUID: NodeStatus] {
        var direct: [UUID: NodeStatus] = [:]
        var remaining: [UUID: Int] = [:]
        var children: [UUID: [UUID]] = [:]
        for revision in records.values {
            do { try revision.validateParents(in: records); direct[revision.revisionID] = .valid }
            catch {
                if case DomainError.missingDependency = error { direct[revision.revisionID] = .pending }
                else { direct[revision.revisionID] = .invalid }
            }
            remaining[revision.revisionID] = revision.parentRevisionIDs.filter { records[$0] != nil }.count
            for parent in revision.parentRevisionIDs where records[parent] != nil { children[parent, default: []].append(revision.revisionID) }
        }
        var queue = remaining.filter { $0.value == 0 }.map(\.key).sorted { $0.uuidString < $1.uuidString }
        var states: [UUID: NodeStatus] = [:]
        var index = 0
        while index < queue.count {
            let id = queue[index]
            index += 1
            let parents = records[id]!.parentRevisionIDs
            let status = direct[id]!
            states[id] = status == .valid && parents.contains(where: { states[$0] != .valid }) ? .pending : status
            for child in (children[id] ?? []).sorted(by: { $0.uuidString < $1.uuidString }) {
                remaining[child]! -= 1
                if remaining[child] == 0 { queue.append(child) }
            }
        }
        // Any unprocessed nodes are cyclic or depend on cycles. No recursion is
        // used, so a long hostile ancestry chain cannot overflow the call stack.
        for id in records.keys where states[id] == nil { states[id] = .invalid }
        return states
    }

    private static func historicalContext(_ records: [UUID: RecordRevision], states: [UUID: NodeStatus]) -> DomainContext {
        var context = DomainContext()
        let creates = records.values.filter { states[$0.revisionID] == .valid && $0.operation == .create }
        for (_, candidates) in Dictionary(grouping: creates, by: \.key) {
            let values = candidates.compactMap(\.payload)
            switch values.first {
            case .pair(let pair):
                if values.allSatisfy({ $0 == .pair(pair) }) { context.pairs[pair.pairID] = pair }
            case .player(let player):
                if values.allSatisfy({ value in if case .player(let p) = value { return p.pairID == player.pairID }; return false }) { context.players[player.playerID] = player }
            case .device(let device):
                if values.allSatisfy({ value in if case .device(let d) = value { return d.playerID == device.playerID && d.pairID == device.pairID && d.createdAt == device.createdAt }; return false }) { context.devices[device.deviceID] = device }
            default: break
            }
        }
        return context
    }

    private static func makeContext(_ projections: [EntityProjection], records: [UUID: RecordRevision], states: [UUID: NodeStatus]) -> DomainContext {
        var context = DomainContext()
        for projection in projections where projection.status == .ready {
            switch projection.record {
            case .pair(let value): context.pairs[value.pairID] = value
            case .player(let value): context.players[value.playerID] = value
            case .game(let value): context.games[value.gameID] = value
            default: break
            }
        }
        // Historical enrollment validates old authors even after device label
        // changes/voids. Conflicting enrollment bindings never pick a winner.
        let devices = records.values.compactMap { revision -> Device? in
            guard states[revision.revisionID] == .valid, revision.operation == .create,
                  case .device(let device) = revision.payload else { return nil }
            return device
        }
        for (id, candidates) in Dictionary(grouping: devices, by: \.deviceID) {
            guard let first = candidates.first,
                  candidates.allSatisfy({ $0.pairID == first.pairID && $0.playerID == first.playerID && $0.createdAt == first.createdAt }),
                  (try? DomainRecord.device(first).validate(in: context)) != nil else { continue }
            context.devices[id] = first
        }
        return context
    }

    private static func totals(_ projections: [EntityProjection]) -> [ScoreboardTotal] {
        let ready = projections.compactMap { $0.status == .ready ? $0.record : nil }
        var result: [ScoreboardTotal] = []
        for record in ready {
            guard case .pair(let pair) = record else { continue }
            let games = ready.compactMap { value -> Game? in if case .game(let game) = value, game.pairID == pair.pairID { return game }; return nil }
            let matches = ready.compactMap { value -> GameEvent? in if case .gameEvent(let match) = value, match.pairID == pair.pairID, match.status == .completed { return match }; return nil }
            for gameID in [nil] + games.map({ Optional($0.gameID) }) {
                var total = ScoreboardTotal(pairID: pair.pairID, gameID: gameID, playerOneID: pair.playerOneID, playerTwoID: pair.playerTwoID)
                for match in matches where gameID == nil || match.gameID == gameID {
                    if match.outcome == .draw { total.draws += 1 }
                    else if match.winnerPlayerID == pair.playerOneID { total.playerOneWins += 1 }
                    else if match.winnerPlayerID == pair.playerTwoID { total.playerTwoWins += 1 }
                }
                result.append(total)
            }
        }
        return result.sorted { $0.sortKey < $1.sortKey }
    }
}
