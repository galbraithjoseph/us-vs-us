import Foundation

/// An online-verified membership can queue offline revisions for this session.
/// CloudKit still enforces the server ACL at export; cached metadata cannot prove
/// that a disconnected participant has not been revoked elsewhere.
@MainActor
final class AuthorizedPairWriter {
    private let repository: RevisionRepository
    private let accounts: any CloudAccountService
    private let binding: PairBinding
    let pair: Pair

    init(pair: Pair, binding: PairBinding, accounts: any CloudAccountService, repository: RevisionRepository) throws {
        guard binding.pairID == pair.pairID, binding.route != .local,
              binding.playerID == (binding.route == .private ? pair.playerOneID : pair.playerTwoID) else { throw SharingError.permissionDenied }
        self.pair = pair
        self.binding = binding
        self.accounts = accounts
        self.repository = repository
    }

    @discardableResult
    func write(operationID: UUID, record: DomainRecord?, entityType: EntityType, entityID: UUID,
               operation: RevisionOperation, parents: [UUID] = [], at time: Timestamp) async throws -> RecordRevision {
        guard try await accounts.currentAccount() == binding.account else { throw SharingError.accountChanged }
        _ = try await repository.enroll(pair: pair, playerID: binding.playerID, route: binding.route, at: time)
        guard try await accounts.currentAccount() == binding.account else { throw SharingError.accountChanged }
        return try await repository.write(WriteCommand(operationID: operationID, pair: pair, authorPlayerID: binding.playerID,
            route: binding.route, entityType: entityType, entityID: entityID, operation: operation,
            payload: record, parentRevisionIDs: parents, recordedAt: time))
    }
}
