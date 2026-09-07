import Foundation

struct SequenceRange: Codable, Equatable, Sendable {
    let lower: DecimalInt64
    let upper: DecimalInt64
}
struct SequenceRanges: Codable, Equatable, Sendable {
    private(set) var ranges: [SequenceRange] = []

    mutating func insert(_ sequence: Int64) {
        guard sequence > 0 else { return }
        var merged: [SequenceRange] = []
        let values = (ranges + [SequenceRange(lower: .init(rawValue: sequence), upper: .init(rawValue: sequence))]).sorted { $0.lower < $1.lower }
        for range in values {
            if let last = merged.last,
               range.lower.rawValue <= last.upper.rawValue || (last.upper.rawValue < Int64.max && range.lower.rawValue == last.upper.rawValue + 1) {
                merged[merged.count - 1] = SequenceRange(lower: last.lower, upper: max(last.upper, range.upper))
            } else { merged.append(range) }
        }
        ranges = merged
    }

    var gapsThroughHighestReceived: [SequenceRange] {
        var next: Int64 = 1
        var gaps: [SequenceRange] = []
        for range in ranges {
            if next < range.lower.rawValue {
                gaps.append(SequenceRange(lower: .init(rawValue: next), upper: .init(rawValue: range.lower.rawValue - 1)))
            }
            if range.upper.rawValue == Int64.max { break }
            next = range.upper.rawValue + 1
        }
        return gaps
    }
}

struct RecordKey: Codable, Hashable, Sendable, Comparable {
    let pairID: UUID
    let type: EntityType
    let entityID: UUID
    static func < (lhs: Self, rhs: Self) -> Bool {
        [lhs.pairID.uuidString, lhs.type.rawValue, lhs.entityID.uuidString].lexicographicallyPrecedes([rhs.pairID.uuidString, rhs.type.rawValue, rhs.entityID.uuidString])
    }
}
struct OriginKey: Codable, Hashable, Sendable, Comparable {
    let pairID: UUID
    let deviceID: UUID
    static func < (lhs: Self, rhs: Self) -> Bool {
        [lhs.pairID.uuidString, lhs.deviceID.uuidString].lexicographicallyPrecedes([rhs.pairID.uuidString, rhs.deviceID.uuidString])
    }
}
struct OriginRanges: Codable, Equatable, Sendable {
    let origin: OriginKey
    let received: SequenceRanges
}
