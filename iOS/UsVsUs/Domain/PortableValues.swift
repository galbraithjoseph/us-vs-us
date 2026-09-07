import Foundation

/// JSON strings prevent silent rounding in languages whose JSON numbers are doubles.
struct DecimalInt64: RawRepresentable, Hashable, Comparable, Codable, Sendable, ExpressibleByIntegerLiteral {
    let rawValue: Int64
    init(rawValue: Int64) { self.rawValue = rawValue }
    init(integerLiteral value: Int64) { rawValue = value }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = Int64(text), String(value) == text else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected canonical signed Int64 decimal string")
        }
        rawValue = value
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(rawValue))
    }
}

/// Absolute microseconds since the Unix epoch, without floating-point conversion.
struct Timestamp: Hashable, Comparable, Codable, Sendable {
    let microsecondsSince1970: Int64
    init(_ microsecondsSince1970: Int64) { self.microsecondsSince1970 = microsecondsSince1970 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.microsecondsSince1970 < rhs.microsecondsSince1970 }
    init(from decoder: any Decoder) throws {
        microsecondsSince1970 = try DecimalInt64(from: decoder).rawValue
    }
    func encode(to encoder: any Encoder) throws {
        try DecimalInt64(rawValue: microsecondsSince1970).encode(to: encoder)
    }
}

enum DomainError: Error, Equatable {
    case invalid(String)
    case missingDependency(UUID)
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw DomainError.invalid(message) }
}
