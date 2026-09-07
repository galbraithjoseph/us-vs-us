import Foundation

@MainActor
protocol CloudAccountService {
    func currentAccount() async throws -> CloudAccount
}

@MainActor
protocol PairShareTransport {
    /// Fetches current server metadata for an existing share; creates only when
    /// requested for a private graph. Never discovers a pair from a caller UUID alone.
    func share(pairID: UUID, create: Bool) async throws -> PairShare
    func resolveRecipient(email: String) async throws -> CloudAccount
    func invite(recipient: CloudAccount, share: PairShare) async throws -> PairShare
    func cancelPending(share: PairShare) async throws -> PairShare
    /// Fetches fresh invitation metadata, validates and accepts into the shared store.
    /// A nil result means acceptance succeeded but the pair graph has not imported.
    func accept(url: URL, account: CloudAccount) async throws -> PairShare?
}

/// UI-facing serialization and account continuity around asynchronous operations.
/// Errors propagate without marking invitations accepted or discarding local work.
@MainActor
final class SharingService {
    private let accounts: any CloudAccountService
    private let transport: any PairShareTransport
    private let account: CloudAccount
    private var busy = false

    init(account: CloudAccount, accounts: any CloudAccountService, transport: any PairShareTransport) {
        self.account = account
        self.accounts = accounts
        self.transport = transport
    }

    private func begin() async throws {
        guard !busy else { throw SharingError.busy }
        busy = true
        do { try await checkAccount() } catch { busy = false; throw error }
    }
    private func checkAccount() async throws {
        guard try await accounts.currentAccount() == account else { throw SharingError.accountChanged }
    }

    func invite(pairID: UUID, email: String) async throws -> PairShare {
        try await begin()
        defer { busy = false }
        let recipient = try await transport.resolveRecipient(email: email)
        guard recipient != account else { throw SharingError.selfInvitation }
        try await checkAccount()
        let share = try await transport.share(pairID: pairID, create: true)
        guard share.pairID == pairID else { throw SharingError.invalidShare }
        try SharingPolicy.invite(recipient, by: account, to: share)
        try await checkAccount()
        let updated = try await transport.invite(recipient: recipient, share: share)
        try SharingPolicy.invite(recipient, by: account, to: updated)
        guard updated.pairID == pairID, updated.identifier == share.identifier,
              updated.members.contains(where: { $0.account == recipient }) else { throw SharingError.incompleteResponse }
        try await checkAccount()
        return updated
    }

    func cancelPending(pairID: UUID) async throws -> PairShare {
        try await begin()
        defer { busy = false }
        let share = try await transport.share(pairID: pairID, create: false)
        guard share.pairID == pairID else { throw SharingError.invalidShare }
        try SharingPolicy.cancel(by: account, share: share)
        try await checkAccount()
        let updated = try await transport.cancelPending(share: share)
        try SharingPolicy.validate(updated)
        guard updated.pairID == pairID, updated.identifier == share.identifier, updated.members.count == 1 else {
            throw SharingError.incompleteResponse
        }
        try await checkAccount()
        return updated
    }

    func accept(url: URL) async throws -> PairShare? {
        try await begin()
        defer { busy = false }
        let share = try await transport.accept(url: url, account: account)
        try await checkAccount()
        if let share {
            try SharingPolicy.validate(share)
            guard share.route == .shared, share.members.contains(where: {
                $0.account == account && $0.role == .privateParticipant && $0.acceptance == .accepted
            }) else { throw SharingError.permissionDenied }
        }
        return share
    }

    func binding(for pair: Pair) async throws -> PairBinding {
        try await begin()
        defer { busy = false }
        let share = try await transport.share(pairID: pair.pairID, create: false)
        try await checkAccount()
        return try SharingPolicy.bind(pair: pair, share: share, account: account)
    }
}
