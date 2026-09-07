import XCTest
@testable import UsVsUs

struct ReconciliationFixture {
    static func input(_ name: String, bundle: Bundle) throws -> RoutedInput {
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json", subdirectory: "fixtures"))
        let bytes = try Data(contentsOf: url)
        return RoutedInput(pairID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, route: .private, bytes: bytes)
    }
    static func changed(_ input: RoutedInput, _ edit: (inout [String: Any]) -> Void) throws -> RoutedInput {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: input.bytes) as? [String: Any])
        edit(&object)
        return RoutedInput(pairID: input.pairID, route: input.route, bytes: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
    }
}

final class IngestionTests: XCTestCase {
    func testRangesRetainGapsAndHandleInt64MaximumWithoutOverflow() {
        var ranges = SequenceRanges()
        for n: Int64 in [10, 1, 3, 2, 10, Int64.max, Int64.max - 1, 0, -1] { ranges.insert(n) }
        XCTAssertEqual(ranges.ranges.map { [$0.lower.rawValue, $0.upper.rawValue] }, [[1, 3], [10, 10], [Int64.max - 1, Int64.max]])
        XCTAssertEqual(ranges.gapsThroughHighestReceived.map { [$0.lower.rawValue, $0.upper.rawValue] }, [[4, 9], [11, Int64.max - 2]])
        for n: Int64 in [4, 5, 6, 7, 8, 9] { ranges.insert(n) }
        XCTAssertEqual(ranges.ranges.first?.upper.rawValue, 10)
    }
    func testRepeatedAndReformattedInputsAreIdempotent() throws {
        let input = try ReconciliationFixture.input("07-gameEvent-update", bundle: Bundle(for: Self.self))
        let formatted = try ReconciliationFixture.changed(input) { _ in }
        let result = RevisionIngestion.ingest([input, input, formatted, input])
        XCTAssertEqual(result.records.count, 1)
        XCTAssertTrue(result.quarantined.isEmpty)
        XCTAssertEqual(result.ranges.first?.received.ranges.first?.lower.rawValue, 7)
        XCTAssertEqual(result.ranges.first?.received.gapsThroughHighestReceived.first?.upper.rawValue, 6)
    }
    func testIdentityCollisionsQuarantineBothVariantsInEitherOrder() throws {
        let input = try ReconciliationFixture.input("07-gameEvent-update", bundle: Bundle(for: Self.self))
        let changedID = try ReconciliationFixture.changed(input) { $0["revisionID"] = UUID().uuidString }
        let changedContent = try ReconciliationFixture.changed(input) { $0["recordedAt"] = "999" }
        let invalidContent = try ReconciliationFixture.changed(input) { $0["originSequence"] = "0" }
        for other in [changedID, changedContent, invalidContent] {
            let forward = RevisionIngestion.ingest([input, other])
            let backward = RevisionIngestion.ingest([other, input])
            XCTAssertTrue(forward.records.isEmpty)
            XCTAssertEqual(forward.quarantined, backward.quarantined)
            XCTAssertEqual(forward.poisonedRecords.count, 1)
            XCTAssertEqual(forward.quarantined.count, 2)
        }
    }
    func testMalformedWrongPairAndUnsupportedAreRetainedWithoutProjection() throws {
        let original = try ReconciliationFixture.input("01-pair-create", bundle: Bundle(for: Self.self))
        let wrongPair = RoutedInput(pairID: UUID(), route: .shared, bytes: original.bytes)
        let malformed = RoutedInput(pairID: original.pairID, route: .private, bytes: Data("{".utf8))
        let unsupported = try ReconciliationFixture.input("unsupported-v2", bundle: Bundle(for: Self.self))
        let result = RevisionIngestion.ingest([wrongPair, malformed, unsupported, unsupported])
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.quarantined.count, 2)
        XCTAssertEqual(result.unsupported, [unsupported])
    }
}
