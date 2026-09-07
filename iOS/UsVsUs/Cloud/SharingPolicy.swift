import Foundation

struct CloudAccount: Equatable, Sendable {
    let recordName: String
}

enum SharingError: Error, Equatable {
    case accountUnavailable, accountChanged, busy, missingPair, awaitingImport
    case invalidShare, wrongContainer, permissionDenied, thirdParticipant, selfInvitation
    case acceptedPartnerCannotBeReplaced, canceledInvitation, incompleteResponse
}

enum ShareRole: Sendable { case owner, privateParticipant, publicParticipant, unknown }
enum ShareAcceptance: Sendable { case pending, accepted, removed, unknown }
struct ShareMember: Equatable, Sendable {
    let account: CloudAccount
    let role: ShareRole
    let acceptance: ShareAcceptance
    let canWrite: Bool
}

/// Only a transport may construct this from CloudKit metadata. Portable UUIDs
/// identify domain records; they are never evidence of CloudKit authorization.
struct PairShare: Equatable, Sendable {
    let identifier: String
    let containerIdentifier: String
    let pairID: UUID
    let route: StoreRoute
    let isPublic: Bool
    let members: [ShareMember]
    let url: URL?
}

struct PairBinding: Equatable, Sendable {
    let pairID: UUID
    let playerID: UUID
    let route: StoreRoute
    let account: CloudAccount
}

enum SharingPolicy {
    static func validate(_ share: PairShare) throws {
        guard share.containerIdentifier == CloudConfiguration.containerIdentifier else { throw SharingError.wrongContainer }
        guard !share.isPublic, share.route != .local,
              share.members.filter({ $0.role == .owner }).count == 1,
              Set(share.members.map(\.account.recordName)).count == share.members.count,
              share.members.allSatisfy({ !$0.account.recordName.isEmpty && ($0.role == .owner || $0.role == .privateParticipant) }) else {
            throw SharingError.invalidShare
        }
        guard share.members.count <= 2 else { throw SharingError.thirdParticipant }
        guard share.members.allSatisfy({ $0.canWrite && ($0.acceptance == .accepted || $0.acceptance == .pending) }),
              share.members.first(where: { $0.role == .owner })?.acceptance == .accepted else { throw SharingError.permissionDenied }
    }

    static func bind(pair: Pair, share: PairShare, account: CloudAccount) throws -> PairBinding {
        try validate(share)
        guard pair.pairID == share.pairID else { throw SharingError.invalidShare }
        guard let member = share.members.first(where: { $0.account == account }), member.acceptance == .accepted else {
            throw SharingError.permissionDenied
        }
        let route: StoreRoute = member.role == .owner ? .private : .shared
        guard share.route == route else { throw SharingError.permissionDenied }
        return PairBinding(pairID: pair.pairID, playerID: member.role == .owner ? pair.playerOneID : pair.playerTwoID,
                           route: route, account: account)
    }

    static func invite(_ recipient: CloudAccount, by owner: CloudAccount, to share: PairShare) throws {
        try validate(share)
        guard share.route == .private, share.members.contains(where: { $0.account == owner && $0.role == .owner }) else {
            throw SharingError.permissionDenied
        }
        guard recipient != owner else { throw SharingError.selfInvitation }
        if let existing = share.members.first(where: { $0.role != .owner }), existing.account != recipient {
            throw SharingError.thirdParticipant
        }
    }

    static func cancel(by owner: CloudAccount, share: PairShare) throws {
        try validate(share)
        guard share.route == .private, share.members.contains(where: { $0.account == owner && $0.role == .owner }) else {
            throw SharingError.permissionDenied
        }
        if share.members.contains(where: { $0.role != .owner && $0.acceptance == .accepted }) {
            throw SharingError.acceptedPartnerCannotBeReplaced
        }
    }
}
