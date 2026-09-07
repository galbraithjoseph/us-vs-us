import CloudKit
import CoreData
import CryptoKit
import Foundation

@MainActor
final class CloudKitAccountService: CloudAccountService {
    private let container: CKContainer
    private let generation = CloudAccountGeneration()
    private var cached: (generation: UInt64, account: CloudAccount)?
    private var subscription: CloudNotificationSubscription?
    init(container: CKContainer = CKContainer(identifier: CloudConfiguration.containerIdentifier)) {
        self.container = container
        let generation = self.generation
        subscription = CloudNotificationSubscription(name: .CKAccountChanged) { _ in generation.invalidate() }
    }
    func currentAccount() async throws -> CloudAccount {
        let before = generation.value()
        guard try await container.accountStatus() == .available else { throw SharingError.accountUnavailable }
        guard generation.value() == before else { throw SharingError.accountChanged }
        if let cached, cached.generation == before { return cached.account }
        let account = try await CloudAccount(recordName: container.userRecordID().recordName)
        guard generation.value() == before else { throw SharingError.accountChanged }
        cached = (before, account)
        return account
    }

    /// Account-scoped stores prevent an accepted graph being reused by a different
    /// signed-in account. The digest is a directory key, not an authentication token.
    static func directory(under root: URL, account: CloudAccount) -> URL {
        let digest = SHA256.hash(data: Data(account.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }
}

/// Uses Core Data's zone sharing APIs. The only supported invitation mutation
/// resolves one named private participant; no unrestricted sharing controller.
@MainActor
final class CloudKitSharingTransport: PairShareTransport {
    private let stack: StoreStack
    private let cloud: CKContainer
    private let accounts: any CloudAccountService
    private let account: CloudAccount
    private var resolved: [CloudAccount: CKShare.Participant] = [:]

    init(stack: StoreStack, account: CloudAccount, accounts: any CloudAccountService) {
        self.stack = stack
        self.account = account
        self.accounts = accounts
        cloud = CKContainer(identifier: CloudConfiguration.containerIdentifier)
    }

    private func checkAccount() async throws {
        guard try await accounts.currentAccount() == account else { throw SharingError.accountChanged }
    }

    func share(pairID: UUID, create: Bool) async throws -> PairShare {
        try await checkAccount()
        let root = try root(pairID: pairID)
        let route = try route(of: root)
        let cached = try stack.container.fetchShares(matching: [root.objectID])[root.objectID]
        var share: CKShare
        if let cached {
            share = try await fresh(cached, route: route)
        } else {
            guard create, route == .private else { throw SharingError.awaitingImport }
            share = try await withCheckedThrowingContinuation { continuation in
                stack.container.share([root], to: nil) { _, share, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let share { continuation.resume(returning: share) }
                    else { continuation.resume(throwing: SharingError.incompleteResponse) }
                }
            }
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = "Us vs Us" as CKRecordValue
            try SharingPolicy.validate(snapshot(share, pairID: pairID, route: route))
            try await checkAccount()
            share = try await persist(share)
        }
        try await checkAccount()
        let value = try snapshot(share, pairID: pairID, route: route)
        try SharingPolicy.validate(value)
        return value
    }

    func resolveRecipient(email: String) async throws -> CloudAccount {
        try await checkAccount()
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { throw SharingError.invalidShare }
        let store = try stack.store(.private)
        let participants: [CKShare.Participant] = try await withCheckedThrowingContinuation { continuation in
            stack.container.fetchParticipants(matching: [CKUserIdentity.LookupInfo(emailAddress: email)], into: store) { participants, error in
                if let error { continuation.resume(throwing: error) }
                else if let participants { continuation.resume(returning: participants) }
                else { continuation.resume(throwing: SharingError.incompleteResponse) }
            }
        }
        guard participants.count == 1, let participant = participants.first,
              let recordName = participant.userIdentity.userRecordID?.recordName else { throw SharingError.invalidShare }
        try await checkAccount()
        let recipient = CloudAccount(recordName: recordName)
        resolved[recipient] = participant
        return recipient
    }

    func invite(recipient: CloudAccount, share value: PairShare) async throws -> PairShare {
        try await checkAccount()
        let share = try await matchingShare(value)
        let current = try snapshot(share, pairID: value.pairID, route: .private)
        try SharingPolicy.invite(recipient, by: account, to: current)
        if !current.members.contains(where: { $0.account == recipient }) {
            guard let participant = resolved[recipient] else { throw SharingError.invalidShare }
            participant.permission = .readWrite
            share.addParticipant(participant)
        }
        share.publicPermission = .none
        try await checkAccount()
        let saved = try await persist(share)
        return try snapshot(saved, pairID: value.pairID, route: .private)
    }

    func cancelPending(share value: PairShare) async throws -> PairShare {
        try await checkAccount()
        let share = try await matchingShare(value)
        try SharingPolicy.cancel(by: account, share: snapshot(share, pairID: value.pairID, route: .private))
        for member in share.participants where member.role != .owner { share.removeParticipant(member) }
        try await checkAccount()
        let saved = try await persist(share)
        return try snapshot(saved, pairID: value.pairID, route: .private)
    }

    func accept(url: URL, account expected: CloudAccount) async throws -> PairShare? {
        guard expected == account else { throw SharingError.accountChanged }
        try await checkAccount()
        let metadata: CKShare.Metadata = try await withCheckedThrowingContinuation { continuation in
            cloud.fetchShareMetadata(with: url) { metadata, error in
                if let error { continuation.resume(throwing: error) }
                else if let metadata { continuation.resume(returning: metadata) }
                else { continuation.resume(throwing: SharingError.incompleteResponse) }
            }
        }
        return try await accept(metadata: metadata)
    }

    func accept(metadata: CKShare.Metadata) async throws -> PairShare? {
        try await checkAccount()
        guard metadata.containerIdentifier == CloudConfiguration.containerIdentifier else { throw SharingError.wrongContainer }
        guard metadata.participantRole == .privateUser, metadata.participantPermission == .readWrite,
              metadata.participantStatus == .pending || metadata.participantStatus == .accepted else {
            throw SharingError.permissionDenied
        }
        // The invitation has no portable pair ID until its zone imports. This
        // temporary ID is used only for metadata shape checks, never enrollment.
        try SharingPolicy.validate(snapshot(metadata.share, pairID: UUID(), route: .shared))
        try await checkAccount()
        if metadata.participantStatus != .accepted {
            let store = try stack.store(.shared)
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                stack.container.acceptShareInvitations(from: [metadata], into: store) { accepted, error in
                    if let error { continuation.resume(throwing: error) }
                    else if accepted?.count == 1 { continuation.resume() }
                    else { continuation.resume(throwing: SharingError.incompleteResponse) }
                }
            }
        }
        try await checkAccount()
        let roots = try roots(in: .shared)
        let shares = try stack.container.fetchShares(matching: roots.map(\.objectID))
        let matches = roots.filter { shares[$0.objectID]?.recordID == metadata.share.recordID }
        guard matches.count <= 1 else { throw SharingError.invalidShare }
        guard let root = matches.first, let pairID = root.value(forKey: "pairID") as? UUID else { return nil }
        return try await share(pairID: pairID, create: false)
    }

    private func matchingShare(_ value: PairShare) async throws -> CKShare {
        guard value.route == .private else { throw SharingError.permissionDenied }
        let root = try root(pairID: value.pairID)
        guard try route(of: root) == .private,
              let cached = try stack.container.fetchShares(matching: [root.objectID])[root.objectID],
              Self.identifier(cached) == value.identifier else { throw SharingError.invalidShare }
        return try await fresh(cached, route: .private)
    }

    private func fresh(_ share: CKShare, route: StoreRoute) async throws -> CKShare {
        let database = route == .private ? cloud.privateCloudDatabase : cloud.sharedCloudDatabase
        guard let fresh = try await database.record(for: share.recordID) as? CKShare else { throw SharingError.invalidShare }
        return fresh
    }

    private func persist(_ share: CKShare) async throws -> CKShare {
        let store = try stack.store(.private)
        return try await withCheckedThrowingContinuation { continuation in
            stack.container.persistUpdatedShare(share, in: store) { saved, error in
                if let error { continuation.resume(throwing: error) }
                else if let saved { continuation.resume(returning: saved) }
                else { continuation.resume(throwing: SharingError.incompleteResponse) }
            }
        }
    }

    private func roots(in route: StoreRoute) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorPair")
        request.affectedStores = [try stack.store(route)]
        return try stack.container.viewContext.fetch(request)
    }
    private func root(pairID: UUID) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorPair")
        request.affectedStores = [try stack.store(.private), try stack.store(.shared)]
        request.predicate = NSPredicate(format: "pairID == %@", pairID as NSUUID)
        let matches = try stack.container.viewContext.fetch(request)
        guard matches.count == 1, let root = matches.first else { throw SharingError.missingPair }
        return root
    }
    private func route(of root: NSManagedObject) throws -> StoreRoute {
        if root.objectID.persistentStore == (try stack.store(.private)) { return .private }
        if root.objectID.persistentStore == (try stack.store(.shared)) { return .shared }
        throw SharingError.invalidShare
    }
    private static func identifier(_ share: CKShare) -> String {
        [share.recordID.zoneID.ownerName, share.recordID.zoneID.zoneName, share.recordID.recordName]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
    private func snapshot(_ share: CKShare, pairID: UUID, route: StoreRoute) throws -> PairShare {
        let members = try share.participants.map { participant -> ShareMember in
            guard let name = participant.userIdentity.userRecordID?.recordName else { throw SharingError.invalidShare }
            let role: ShareRole = switch participant.role {
            case .owner: .owner
            case .privateUser: .privateParticipant
            case .publicUser: .publicParticipant
            default: .unknown
            }
            let acceptance: ShareAcceptance = switch participant.acceptanceStatus {
            case .pending: .pending
            case .accepted: .accepted
            case .removed: .removed
            default: .unknown
            }
            return ShareMember(account: CloudAccount(recordName: name), role: role,
                               acceptance: acceptance, canWrite: participant.permission == .readWrite)
        }
        return PairShare(identifier: Self.identifier(share), containerIdentifier: CloudConfiguration.containerIdentifier,
                         pairID: pairID, route: route, isPublic: share.publicPermission != .none, members: members, url: share.url)
    }
}
