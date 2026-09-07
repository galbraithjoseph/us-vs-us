import XCTest
@testable import UsVsUs

final class RevisionTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "fixtures"))
        return try Data(contentsOf: url)
    }
    private func revision(_ name: String = "07-gameEvent-update") throws -> RecordRevision {
        guard case .supported(let revision) = try PortableRevision.decode(fixture(name)) else {
            throw DomainError.invalid("Expected supported fixture")
        }
        return revision
    }
    private func mutated(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testGoldenFixturesRoundTripAndValidateCompleteGraph() throws {
        let names = ["01-pair-create", "02-player-create", "03-player-create", "04-device-create", "05-game-create", "06-gameEvent-create", "07-gameEvent-update", "08-gameEvent-update", "09-gameEvent-update", "10-gameEvent-void"]
        var revisions: [UUID: RecordRevision] = [:]
        var context = DomainContext()
        for name in names {
            let input = try fixture(name)
            let portable = try PortableRevision.decode(input)
            let output = try portable.encoded()
            XCTAssertEqual(try PortableRevision.decode(output), portable)
            let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? NSDictionary)
            let outputObject = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? NSDictionary)
            XCTAssertEqual(originalObject, outputObject, name)
            guard case .supported(let revision) = portable else { return XCTFail("Expected v1") }
            try revision.validateParents(in: revisions)
            revisions[revision.revisionID] = revision
            switch revision.payload {
            case .pair(let v): context.pairs[v.pairID] = v
            case .player(let v): context.players[v.playerID] = v
            case .game(let v): context.games[v.gameID] = v
            case .device(let v): context.devices[v.deviceID] = v
            default: break
            }
        }
        for revision in revisions.values { try revision.validateReferences(in: context) }
        let matchRevision = try revision()
        guard case .gameEvent(let match) = matchRevision.payload else { return XCTFail("Expected match") }
        XCTAssertEqual(match.playerOneScore?.rawValue, Int64.max)
        XCTAssertEqual(match.playerTwoScore?.rawValue, Int64.min)
        XCTAssertEqual(match.startedAt.microsecondsSince1970, 1_700_000_000_123_456)
        XCTAssertEqual(try revision("09-gameEvent-update").parentRevisionIDs.count, 2)
    }

    func testUnsupportedVersionsRetainOriginalBytesWithoutProjection() throws {
        let bytes = try fixture("unsupported-v2")
        let portable = try PortableRevision.decode(bytes)
        XCTAssertEqual(portable, .unsupported(schemaVersion: 2, bytes: bytes))
        XCTAssertEqual(try portable.encoded(), bytes)
        for data in [Data("{}".utf8), Data("{\"schemaVersion\":0}".utf8), Data("{".utf8)] {
            XCTAssertThrowsError(try PortableRevision.decode(data))
        }
    }

    func testMalformedEnvelopePayloadAndGoldenInvalidFixturesAreRejected() throws {
        for name in ["invalid-overflow", "invalid-winner"] { XCTAssertThrowsError(try PortableRevision.decode(fixture(name))) }
        let input = try fixture("07-gameEvent-update")
        for (key, value) in [("originSequence", "0"), ("originSequence", "-1"), ("operation", "create"),
                             ("operation", "void"), ("entityType", "player"), ("entityID", UUID().uuidString),
                             ("pairID", UUID().uuidString), ("revisionID", "invalid"), ("parentRevisionIDs", []),
                             ("payload", NSNull()), ("unexpected", true)] as [(String, Any)] {
            XCTAssertThrowsError(try PortableRevision.decode(mutated(input) { $0[key] = value }), key)
        }
        let good = try revision()
        XCTAssertThrowsError(try PortableRevision.decode(mutated(input) { $0["parentRevisionIDs"] = [good.revisionID.uuidString] }))
        XCTAssertThrowsError(try PortableRevision.decode(mutated(input) { $0["parentRevisionIDs"] = [good.parentRevisionIDs[0].uuidString, good.parentRevisionIDs[0].uuidString] }))
        let unsorted = try fixture("09-gameEvent-update")
        XCTAssertThrowsError(try PortableRevision.decode(mutated(unsorted) { $0["parentRevisionIDs"] = ($0["parentRevisionIDs"] as! [String]).reversed().map { $0 } }))
        XCTAssertThrowsError(try PortableRevision.decode(mutated(input) {
            var payload = $0["payload"] as! [String: Any]
            var value = payload["value"] as! [String: Any]
            value["futureScore"] = "0"
            payload["value"] = value
            $0["payload"] = payload
        }))
    }

    func testMissingForeignParentsImmutableRuleAndTombstoneResurrection() throws {
        let child = try revision()
        XCTAssertThrowsError(try child.validateParents(in: [:])) { XCTAssertEqual($0 as? DomainError, .missingDependency(child.parentRevisionIDs[0])) }
        let wrongParent = try revision("05-game-create")
        XCTAssertThrowsError(try child.validateParents(in: [child.parentRevisionIDs[0]: wrongParent]))
        let parent = try revision("06-gameEvent-create")
        let changedRule = try mutated(fixture("07-gameEvent-update")) {
            var payload = $0["payload"] as! [String: Any]
            var value = payload["value"] as! [String: Any]
            value["highScoreWinsAtStart"] = false
            value["winnerPlayerID"] = value["playerTwoID"]
            payload["value"] = value
            $0["payload"] = payload
        }
        guard case .supported(let changed) = try PortableRevision.decode(changedRule) else { return XCTFail("Expected v1") }
        XCTAssertThrowsError(try changed.validateParents(in: [parent.revisionID: parent]))
        let tombstone = try revision("10-gameEvent-void")
        let resurrected = try mutated(fixture("07-gameEvent-update")) { $0["parentRevisionIDs"] = [tombstone.revisionID.uuidString] }
        guard case .supported(let resurrection) = try PortableRevision.decode(resurrected) else { return XCTFail("Expected v1") }
        XCTAssertThrowsError(try resurrection.validateParents(in: [tombstone.revisionID: tombstone]))
    }

    func testPairAndDeviceIdentityCannotChangeButMetadataCan() throws {
        for (fixtureName, immutableField, mutableField) in [
            ("01-pair-create", "playerTwoID", "createdAt"),
            ("04-device-create", "playerID", "displayLabel"),
            ("02-player-create", "pairID", "displayName"),
            ("05-game-create", "pairID", "name")
        ] {
            let parent = try revision(fixtureName)
            let base = try mutated(fixture(fixtureName)) {
                $0["revisionID"] = UUID().uuidString
                $0["operation"] = "update"
                $0["originSequence"] = "20"
                $0["parentRevisionIDs"] = [parent.revisionID.uuidString]
            }
            let changed = try mutated(base) {
                var payload = $0["payload"] as! [String: Any]
                var value = payload["value"] as! [String: Any]
                value[immutableField] = UUID().uuidString
                payload["value"] = value
                $0["payload"] = payload
            }
            XCTAssertThrowsError(try {
                guard case .supported(let child) = try PortableRevision.decode(changed) else { throw DomainError.invalid("Expected v1") }
                try child.validateParents(in: [parent.revisionID: parent])
            }())
            if parent.entityType != .pair {
                let renamed = try mutated(base) {
                    var payload = $0["payload"] as! [String: Any]
                    var value = payload["value"] as! [String: Any]
                    value[mutableField] = "Renamed"
                    payload["value"] = value
                    $0["payload"] = payload
                }
                guard case .supported(let child) = try PortableRevision.decode(renamed) else { return XCTFail("Expected v1") }
                try child.validateParents(in: [parent.revisionID: parent])
            }
        }
    }

    func testWriterReferencesRequireMatchingPairAndAuthor() throws {
        let f = DomainFixture()
        let payload = DomainRecord.game(f.game())
        let revision = RecordRevision(schemaVersion: 1, revisionID: UUID(), pairID: f.pair.pairID, entityType: .game,
                                      entityID: f.gameID, originDeviceID: f.deviceID, originSequence: 1,
                                      authorPlayerID: f.pair.playerTwoID, recordedAt: Timestamp(100),
                                      parentRevisionIDs: [], operation: .create, payload: payload)
        XCTAssertThrowsError(try revision.validateReferences(in: f.context))
        var context = f.context
        context.devices = [:]
        XCTAssertThrowsError(try revision.validateReferences(in: context)) { XCTAssertEqual($0 as? DomainError, .missingDependency(f.deviceID)) }
    }
}
