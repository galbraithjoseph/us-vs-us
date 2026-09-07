import XCTest
@testable import UsVsUs

@MainActor
final class SharingTests: XCTestCase {
    let owner = CloudAccount(recordName: "owner")
    let partner = CloudAccount(recordName: "partner")
    let third = CloudAccount(recordName: "third")
    let pair = DomainFixture().pair

    func share(route: StoreRoute = .private, partnerStatus: ShareAcceptance? = .accepted,
               publicAccess: Bool = false, writable: Bool = true, extra: Bool = false) -> PairShare {
        var members = [ShareMember(account: owner, role: .owner, acceptance: .accepted, canWrite: true)]
        if let partnerStatus { members.append(ShareMember(account: partner, role: .privateParticipant, acceptance: partnerStatus, canWrite: writable)) }
        if extra { members.append(ShareMember(account: third, role: .privateParticipant, acceptance: .accepted, canWrite: true)) }
        return PairShare(identifier: "share", containerIdentifier: CloudConfiguration.containerIdentifier,
                         pairID: pair.pairID, route: route, isPublic: publicAccess, members: members,
                         url: URL(string: "https://www.icloud.com/share/example"))
    }

    func testEachAccountMapsToSameExistingPlayerOnEveryDevice() throws {
        for _ in 0..<4 {
            XCTAssertEqual(try SharingPolicy.bind(pair: pair, share: share(), account: owner).playerID, pair.playerOneID)
            XCTAssertEqual(try SharingPolicy.bind(pair: pair, share: share(route: .shared), account: partner).playerID, pair.playerTwoID)
        }
        XCTAssertThrowsError(try SharingPolicy.bind(pair: pair, share: share(), account: partner))
        XCTAssertThrowsError(try SharingPolicy.bind(pair: pair, share: share(route: .shared), account: owner))
        XCTAssertThrowsError(try SharingPolicy.bind(pair: pair, share: share(), account: third))
        XCTAssertThrowsError(try SharingPolicy.bind(pair: DomainFixture().pair, share: share(), account: owner))
    }

    func testUnsupportedParticipantsPermissionsAndPendingWritesFailClosed() throws {
        for invalid in [share(publicAccess: true), share(writable: false), share(extra: true), share(partnerStatus: .removed)] {
            XCTAssertThrowsError(try SharingPolicy.validate(invalid))
        }
        XCTAssertThrowsError(try SharingPolicy.bind(pair: pair, share: share(route: .shared, partnerStatus: .pending), account: partner))
        XCTAssertThrowsError(try SharingPolicy.invite(third, by: owner, to: share(partnerStatus: .pending)))
        XCTAssertThrowsError(try SharingPolicy.invite(owner, by: owner, to: share(partnerStatus: nil)))
        XCTAssertThrowsError(try SharingPolicy.cancel(by: owner, share: share()))
        XCTAssertNoThrow(try SharingPolicy.cancel(by: owner, share: share(partnerStatus: .pending)))
    }

    func testRepeatInvitationCancellationAndTemporaryFailureAreRetryable() async throws {
        let accounts = AccountDouble(owner)
        let transport = ShareDouble(share(partnerStatus: .pending), recipient: partner)
        let service = SharingService(account: owner, accounts: accounts, transport: transport)
        let first = try await service.invite(pairID: pair.pairID, email: "partner@example.invalid")
        let repeated = try await service.invite(pairID: pair.pairID, email: "partner@example.invalid")
        XCTAssertEqual(first, repeated)
        transport.recipient = third
        do { _ = try await service.invite(pairID: pair.pairID, email: "third@example.invalid"); XCTFail() } catch SharingError.thirdParticipant { }
        XCTAssertEqual(transport.invitations, 2)
        transport.fail = true
        do { _ = try await service.cancelPending(pairID: pair.pairID); XCTFail() } catch ShareDouble.Failure.temporary { }
        transport.fail = false
        let canceled = try await service.cancelPending(pairID: pair.pairID)
        let repeatedCancel = try await service.cancelPending(pairID: pair.pairID)
        XCTAssertEqual(canceled, repeatedCancel)
        XCTAssertEqual(canceled.members.count, 1)
        transport.recipient = partner
        let reinvited = try await service.invite(pairID: pair.pairID, email: "partner@example.invalid")
        XCTAssertEqual(reinvited.members.count, 2)
        XCTAssertEqual(transport.cancellations, 2)

    }

    func testAcceptanceFailurePendingImportAndRepeatedAcceptance() async throws {
        let accounts = AccountDouble(partner)
        let transport = ShareDouble(share(route: .shared), recipient: partner)
        let service = SharingService(account: partner, accounts: accounts, transport: transport)
        let url = try XCTUnwrap(transport.value.url)
        transport.fail = true
        do { _ = try await service.accept(url: url); XCTFail() } catch ShareDouble.Failure.temporary { }
        transport.fail = false
        transport.awaitingImport = true
        let pending = try await service.accept(url: url)
        XCTAssertNil(pending)
        transport.awaitingImport = false
        let first = try await service.accept(url: url)
        let repeated = try await service.accept(url: url)
        XCTAssertEqual(first, repeated)
        let binding = try await service.binding(for: pair)
        XCTAssertEqual(binding.playerID, pair.playerTwoID)
    }

    func testAccountChangeRejectsOperationAndDoesNotInvite() async throws {
        let accounts = AccountDouble(owner)
        let transport = ShareDouble(share(partnerStatus: nil), recipient: partner)
        let service = SharingService(account: owner, accounts: accounts, transport: transport)
        transport.onResolve = { accounts.account = self.third }
        do { _ = try await service.invite(pairID: pair.pairID, email: "partner@example.invalid"); XCTFail() } catch SharingError.accountChanged { }
        XCTAssertEqual(transport.invitations, 0)
        accounts.account = owner
        transport.onResolve = nil
        _ = try await service.invite(pairID: pair.pairID, email: "partner@example.invalid")
        XCTAssertEqual(transport.invitations, 1)
    }
    func testVerifiedWriterPreservesIdentityAndStopsOnAccountChange() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = try RevisionRepository(directory: path)
        let accounts = AccountDouble(partner)
        let binding = try SharingPolicy.bind(pair: pair, share: share(route: .shared), account: partner)
        let writer = try AuthorizedPairWriter(pair: pair, binding: binding, accounts: accounts, repository: repository)
        let game = Game(gameID: UUID(), pairID: pair.pairID, name: "Offline probe", highScoreWins: true, isArchived: false)
        let operationID = UUID()
        let first = try await writer.write(operationID: operationID, record: .game(game), entityType: .game,
                                           entityID: game.gameID, operation: .create, at: Timestamp(100))
        let repeated = try await writer.write(operationID: operationID, record: .game(game), entityType: .game,
                                              entityID: game.gameID, operation: .create, at: Timestamp(100))
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.authorPlayerID, pair.playerTwoID)
        accounts.account = third
        do {
            _ = try await writer.write(operationID: UUID(), record: .game(game), entityType: .game,
                                       entityID: game.gameID, operation: .create, at: Timestamp(101))
            XCTFail()
        } catch SharingError.accountChanged { }
        let shared = try await repository.revisions(in: .shared)
        let owned = try await repository.revisions(in: .private)
        XCTAssertEqual(shared.count, 2) // Writer enrollment plus one logical revision.
        XCTAssertTrue(owned.isEmpty)
        try await repository.close()
    }

}

@MainActor
private final class AccountDouble: CloudAccountService {
    var account: CloudAccount
    init(_ account: CloudAccount) { self.account = account }
    func currentAccount() async throws -> CloudAccount { account }
}

@MainActor
private final class ShareDouble: PairShareTransport {
    enum Failure: Error { case temporary }
    var value: PairShare
    var recipient: CloudAccount
    var fail = false
    var awaitingImport = false
    var invitations = 0
    var cancellations = 0
    var onResolve: (() -> Void)?
    init(_ value: PairShare, recipient: CloudAccount) { self.value = value; self.recipient = recipient }
    func share(pairID: UUID, create: Bool) async throws -> PairShare {
        if fail { throw Failure.temporary }
        return value
    }
    func resolveRecipient(email: String) async throws -> CloudAccount { onResolve?(); return recipient }
    func invite(recipient: CloudAccount, share: PairShare) async throws -> PairShare {
        if fail { throw Failure.temporary }
        invitations += 1
        if !value.members.contains(where: { $0.account == recipient }) {
            replaceMembers(value.members + [ShareMember(account: recipient, role: .privateParticipant, acceptance: .pending, canWrite: true)])
        }
        return value
    }
    func cancelPending(share: PairShare) async throws -> PairShare {
        if fail { throw Failure.temporary }
        cancellations += 1
        replaceMembers(value.members.filter { $0.role == .owner })
        return value
    }
    func accept(url: URL, account: CloudAccount) async throws -> PairShare? {
        if fail { throw Failure.temporary }
        return awaitingImport ? nil : value
    }
    private func replaceMembers(_ members: [ShareMember]) {
        value = PairShare(identifier: value.identifier, containerIdentifier: value.containerIdentifier,
                          pairID: value.pairID, route: value.route, isPublic: value.isPublic, members: members, url: value.url)
    }
}
