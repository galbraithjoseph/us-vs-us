import Foundation

struct RoutedInput: Codable, Equatable, Hashable, Sendable {
    let pairID: UUID
    let route: StoreRoute
    let bytes: Data
    var sortKey: String { pairID.uuidString + route.rawValue + bytes.base64EncodedString() }
}
struct QuarantinedInput: Codable, Equatable, Sendable {
    let input: RoutedInput
    let reason: String
}
struct IngestedRevisions {
    let records: [UUID: RecordRevision]
    let poisonedRecords: Set<RecordKey>
    let quarantined: [QuarantinedInput]
    let unsupported: [RoutedInput]
    let ranges: [OriginRanges]
}

extension RecordRevision {
    var key: RecordKey { RecordKey(pairID: pairID, type: entityType, entityID: entityID) }
    var origin: OriginKey { OriginKey(pairID: pairID, deviceID: originDeviceID) }
}

enum RevisionIngestion {
    private struct Candidate {
        let input: RoutedInput
        let revision: RecordRevision?
        let content: Data
        let error: String?
    }
    private struct SequenceIdentity: Hashable { let origin: OriginKey; let sequence: Int64 }

    /// Re-evaluates the entire immutable set so collision handling never depends
    /// on which variant arrived first. Unsupported bytes are preserved exactly.
    static func ingest(_ inputs: [RoutedInput]) -> IngestedRevisions {
        var candidates: [Candidate] = []
        var unsupported: [RoutedInput] = []
        for input in Set(inputs).sorted(by: { $0.sortKey < $1.sortKey }) {
            do {
                try require(input.route != .local, "History requires private/shared route")
                switch try PortableRevision.decode(input.bytes) {
                case .unsupported:
                    unsupported.append(input)
                case .supported(let revision):
                    try require(revision.pairID == input.pairID, "Revision routed to wrong pair")
                    candidates.append(Candidate(input: input, revision: revision,
                                                content: try PortableRevision.supported(revision).encoded(), error: nil))
                }
            } catch {
                // Invalid snapshots may still claim an existing identity. Include
                // those claims in collision detection without accepting the data.
                let decoded = try? JSONDecoder().decode(RecordRevision.self, from: input.bytes)
                let claim = decoded.flatMap { $0.schemaVersion == 1 && $0.pairID == input.pairID ? $0 : nil }
                candidates.append(Candidate(input: input, revision: claim, content: input.bytes, error: "invalidRevision"))
            }
        }
        let idGroups = Dictionary(grouping: candidates.compactMap { c in c.revision.map { ($0.revisionID, c) } }, by: { $0.0 })
        var collidedIDs = Set<UUID>()
        for (id, group) in idGroups where Set(group.map { $0.1.content }).count > 1 { collidedIDs.insert(id) }
        let sequenceGroups = Dictionary(grouping: candidates.compactMap { c in c.revision.map { (SequenceIdentity(origin: $0.origin, sequence: $0.originSequence.rawValue), $0.revisionID) } }, by: { $0.0 })
        for group in sequenceGroups.values where Set(group.map(\.1)).count > 1 { collidedIDs.formUnion(group.map(\.1)) }

        var records: [UUID: RecordRevision] = [:]
        var poisoned = Set<RecordKey>()
        var quarantined: [QuarantinedInput] = []
        var ranges: [OriginKey: SequenceRanges] = [:]
        for candidate in candidates {
            if let revision = candidate.revision, candidate.error == nil {
                ranges[revision.origin, default: SequenceRanges()].insert(revision.originSequence.rawValue)
            }
            if let revision = candidate.revision, collidedIDs.contains(revision.revisionID) {
                poisoned.insert(revision.key)
                quarantined.append(QuarantinedInput(input: candidate.input, reason: "identityCollision"))
            } else if let error = candidate.error {
                quarantined.append(QuarantinedInput(input: candidate.input, reason: error))
            } else if let revision = candidate.revision {
                records[revision.revisionID] = revision
            }
        }
        return IngestedRevisions(records: records, poisonedRecords: poisoned,
                                 quarantined: quarantined, unsupported: unsupported,
                                 ranges: ranges.keys.sorted().map { OriginRanges(origin: $0, received: ranges[$0]!) })
    }
}
