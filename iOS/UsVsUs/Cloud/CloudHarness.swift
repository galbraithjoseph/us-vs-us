#if DEBUG
import CloudKit
import CoreData
import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class CloudInvitationInbox {
    static let shared = CloudInvitationInbox()
    var metadata: CKShare.Metadata?
    var generation = 0
    func receive(_ metadata: CKShare.Metadata) { self.metadata = metadata; generation += 1 }
}

@MainActor
final class CloudApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        CloudInvitationInbox.shared.receive(metadata)
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = CloudInvitationSceneDelegate.self
        return configuration
    }
}

@MainActor
final class CloudInvitationSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let metadata = options.cloudKitShareMetadata { CloudInvitationInbox.shared.receive(metadata) }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        CloudInvitationInbox.shared.receive(metadata)
    }
}

/// Development evidence tooling, separate from the forthcoming product pairing UI.
/// Every created graph is visibly named as disposable; no existing share is reset.
@MainActor @Observable
final class CloudHarnessModel {
    var status = "Connecting to iCloud…"
    var pairs: [Pair] = []
    var selectedPairID: UUID?
    var email = ""
    var invitationURL = ""
    var busy = false
    var report = ""
    var sync: CloudSyncMonitor?
    private var repository: RevisionRepository?
    private var transport: CloudKitSharingTransport?
    private var sharing: SharingService?
    private var account: CloudAccount?
    private let accounts = CloudKitAccountService()
    private var writers: [UUID: AuthorizedPairWriter] = [:]
    private var actions: [String] = []

    func connect() async throws {
        guard repository == nil else { return }
        let account = try await accounts.currentAccount()
        self.account = account
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("CloudHarness", isDirectory: true)
        let repository = try await RevisionRepository.open(directory: CloudKitAccountService.directory(under: base, account: account),
                                                            cloudContainerIdentifier: CloudConfiguration.containerIdentifier)
        self.repository = repository
        let stack = await repository.stack
        sync = CloudSyncMonitor(container: stack.container)
        let transport = CloudKitSharingTransport(stack: stack, account: account, accounts: accounts)
        self.transport = transport
        sharing = SharingService(account: account, accounts: accounts, transport: transport)
        status = "Connected. Development container."
        if ProcessInfo.processInfo.arguments.contains("--cloudkit-initialize-schema") {
            try stack.container.initializeCloudKitSchema(options: [])
            actions.append("Development schema initialization requested; inspect setup/export events for result.")
        }
        if ProcessInfo.processInfo.arguments.contains("--cloudkit-create-pair") { try await createPair() }
        try await refresh()
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await action() }
        catch { status = String(describing: error); actions.append("ERROR: \(error)"); try? await refresh() }
    }

    func createPair() async throws {
        guard let repository, let account, try await accounts.currentAccount() == account else { throw SharingError.accountChanged }
        let pair = Pair(pairID: UUID(), playerOneID: UUID(), playerTwoID: UUID(), createdAt: now())
        let binding = PairBinding(pairID: pair.pairID, playerID: pair.playerOneID, route: .private, account: account)
        let writer = try AuthorizedPairWriter(pair: pair, binding: binding, accounts: accounts, repository: repository)
        for record in [DomainRecord.pair(pair), .player(Player(playerID: pair.playerOneID, pairID: pair.pairID, displayName: "Test owner")),
                       .player(Player(playerID: pair.playerTwoID, pairID: pair.pairID, displayName: "Test partner"))] {
            _ = try await writer.write(operationID: UUID(), record: record, entityType: record.entityType, entityID: record.entityID,
                                       operation: .create, at: now())
        }
        writers[pair.pairID] = writer
        selectedPairID = pair.pairID
        actions.append("Created disposable pair \(pair.pairID)")
        try await refresh()
    }

    func invite() async throws {
        guard let sharing, let selectedPairID else { throw SharingError.missingPair }
        let share = try await sharing.invite(pairID: selectedPairID, email: email)
        invitationURL = share.url?.absoluteString ?? ""
        status = share.url == nil ? "Invitation saved; URL is not available yet. Retry." : "Private invitation ready. Share its link with the named partner."
        actions.append("Prepared private invitation for pair \(selectedPairID)")
        try await refresh()
    }
    func cancel() async throws {
        guard let sharing, let selectedPairID else { throw SharingError.missingPair }
        _ = try await sharing.cancelPending(pairID: selectedPairID)
        invitationURL = ""
        status = "Pending invitation canceled."
        try await refresh()
    }
    func accept(metadata: CKShare.Metadata? = nil) async throws {
        guard let sharing, let transport else { throw SharingError.accountUnavailable }
        let result: PairShare?
        if let metadata { result = try await transport.accept(metadata: metadata) }
        else {
            guard let url = URL(string: invitationURL) else { throw SharingError.invalidShare }
            result = try await sharing.accept(url: url)
        }
        selectedPairID = result?.pairID
        status = result == nil ? "Accepted. Waiting for the shared pair to import; tap Refresh." : "Accepted existing pair."
        actions.append(status)
        try await refresh()
    }
    func verifyMembership() async throws {
        guard let sharing, let repository, let pair = pairs.first(where: { $0.pairID == selectedPairID }) else { throw SharingError.missingPair }
        let binding = try await sharing.binding(for: pair)
        writers[pair.pairID] = try AuthorizedPairWriter(pair: pair, binding: binding, accounts: accounts, repository: repository)
        status = "Verified \(binding.route.rawValue) player \(binding.playerID). Offline writes enabled for this session."
        actions.append(status)
        try await refresh()
    }
    func appendRevision() async throws {
        guard let pair = pairs.first(where: { $0.pairID == selectedPairID }), let writer = writers[pair.pairID] else { throw SharingError.permissionDenied }
        let game = Game(gameID: UUID(), pairID: pair.pairID, name: "Device probe \(UIDevice.current.model)", highScoreWins: true, isArchived: false)
        let revision = try await writer.write(operationID: UUID(), record: .game(game), entityType: .game, entityID: game.gameID,
                                              operation: .create, at: now())
        status = "Saved revision \(revision.revisionID) locally; export may be pending."
        actions.append(status)
        try await refresh()
    }
    func refresh() async throws {
        guard let repository else { return }
        let snapshot = try await repository.processHistory()
        pairs = snapshot.projections.compactMap { projection in
            guard projection.status == .ready, case .pair(let pair) = projection.record else { return nil }
            return pair
        }.sorted { $0.pairID.uuidString < $1.pairID.uuidString }
        if selectedPairID == nil { selectedPairID = pairs.first?.pairID }
        var lines = ["Us vs Us development CloudKit report", "Generated: \(Date().ISO8601Format())",
                     "Device: \(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                     "Container: \(CloudConfiguration.containerIdentifier)", "Team: \(CloudConfiguration.teamIdentifier)",
                     "Account directory: \(CloudKitAccountService.directory(under: URL(fileURLWithPath: "/"), account: account!).lastPathComponent)",
                     "Routing incomplete: \(snapshot.routingIncomplete)", "Quarantine: \(snapshot.quarantined.count)"]
        for pair in pairs { lines.append("PAIR \(pair.pairID) PLAYER_ONE \(pair.playerOneID) PLAYER_TWO \(pair.playerTwoID)") }
        for route in [StoreRoute.private, .shared] {
            let rows = try await repository.revisions(in: route)
            var identities: [UUID] = []
            for row in rows {
                if case .supported(let revision) = try PortableRevision.decode(row.bytes) {
                    identities.append(revision.revisionID)
                    lines.append("REV \(route.rawValue) \(revision.pairID) \(revision.revisionID) \(revision.originDeviceID) \(revision.originSequence.rawValue) \(revision.authorPlayerID)")
                }
            }
            lines.append("\(route.rawValue) rows=\(rows.count) distinctIDs=\(Set(identities).count)")
        }
        for event in sync?.events ?? [] {
            lines.append("SYNC \(event.kind) \(event.identifier) ended=\(event.endedAt?.ISO8601Format() ?? "pending") success=\(event.succeeded) error=\(event.error ?? "none")")
        }
        lines.append(contentsOf: actions)
        report = lines.joined(separator: "\n")
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try report.write(to: documents.appendingPathComponent("cloudkit-report.txt"), atomically: true, encoding: .utf8)
    }
    private func now() -> Timestamp { Timestamp(Int64(Date().timeIntervalSince1970 * 1_000_000)) }
}

struct CloudHarnessView: View {
    @State private var model = CloudHarnessModel()
    private let inbox = CloudInvitationInbox.shared
    var body: some View {
        NavigationStack {
            Form {
                Section("Development device checks") {
                    Text("Creates disposable pair data in the development CloudKit container.")
                    Text(model.status).textSelection(.enabled)
                    Button("Create disposable pair") { Task { await model.perform { try await model.createPair() } } }
                    Picker("Pair", selection: $model.selectedPairID) {
                        Text("Select pair").tag(UUID?.none)
                        ForEach(model.pairs, id: \.pairID) { Text($0.pairID.uuidString).tag(Optional($0.pairID)) }
                    }
                    Button("Refresh imported history and report") { Task { await model.perform { try await model.refresh() } } }
                    Button("Verify membership online") { Task { await model.perform { try await model.verifyMembership() } } }
                    Button("Append independent revision") { Task { await model.perform { try await model.appendRevision() } } }
                }
                Section("One private partner") {
                    TextField("Partner iCloud email", text: $model.email).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Prepare private invitation") { Task { await model.perform { try await model.invite() } } }
                    Button("Cancel pending invitation") { Task { await model.perform { try await model.cancel() } } }
                    TextField("Invitation URL", text: $model.invitationURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let url = URL(string: model.invitationURL), !model.invitationURL.isEmpty { ShareLink("Share invitation link", item: url) }
                    Button("Accept invitation URL") { Task { await model.perform { try await model.accept() } } }
                }
                Section("Evidence") { Text(model.report).font(.caption.monospaced()).textSelection(.enabled) }
            }
            .disabled(model.busy)
            .navigationTitle("CloudKit device checks")
            .task(id: inbox.generation) {
                await model.perform {
                    try await model.connect()
                    if let metadata = inbox.metadata { try await model.accept(metadata: metadata) }
                }
            }
        }
    }
}
#endif
