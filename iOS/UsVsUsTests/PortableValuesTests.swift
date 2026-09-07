import XCTest
@testable import UsVsUs

final class PortableValuesTests: XCTestCase {
    func testInt64AndTimestampRoundTripsWithoutPrecisionLoss() throws {
        for value in [Int64.min, -9_007_199_254_740_993, -1, 0, 9_007_199_254_740_993, Int64.max] {
            let score = DecimalInt64(rawValue: value)
            let data = try JSONEncoder().encode(score)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(value)\"")
            XCTAssertEqual(try JSONDecoder().decode(DecimalInt64.self, from: data), score)
            let timestamp = Timestamp(value)
            XCTAssertEqual(try JSONDecoder().decode(Timestamp.self, from: JSONEncoder().encode(timestamp)), timestamp)
        }
    }
    func testRejectsOverflowAndNonCanonicalIntegers() {
        for text in ["9223372036854775808", "-9223372036854775809", "1.2", "1e2", "01", "-0", "+1", " 1", "", "NaN"] {
            XCTAssertThrowsError(try JSONDecoder().decode(DecimalInt64.self, from: Data("\"\(text)\"".utf8)), text)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(DecimalInt64.self, from: Data("9007199254740993".utf8)))
    }
    func testRecordRoundTripKeepsStableReferences() throws {
        let pair = Pair(pairID: UUID(), playerOneID: UUID(), playerTwoID: UUID(), createdAt: Timestamp(1_700_000_000_123_456))
        let record = DomainRecord.pair(pair)
        XCTAssertEqual(try JSONDecoder().decode(DomainRecord.self, from: JSONEncoder().encode(record)), record)
        XCTAssertEqual(record.entityID, pair.pairID)
        XCTAssertEqual(record.pairID, pair.pairID)
    }
}
