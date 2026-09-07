import CoreData
import Foundation

enum RebuildStage: CaseIterable, Equatable, Sendable { case afterIngressSave, beforeProjectionSave, afterProjectionSave }

extension RevisionRepository {
    /// Preferred application entry point: recover first, then observe changes.
    static func open(directory: URL, cloudContainerIdentifier: String? = nil) async throws -> RevisionRepository {
        let repository = try RevisionRepository(directory: directory, cloudContainerIdentifier: cloudContainerIdentifier)
        do {
            try await repository.recover()
            await repository.startRemoteChangeProcessing()
            return repository
        } catch { try? await repository.close(); throw error }
    }

    func setRebuildFailureInjector(_ failure: @escaping @Sendable (RebuildStage) throws -> Void) { rebuildFailure = failure }

    func startRemoteChangeProcessing() {
        guard historyObserver == nil else { return }
        historyObserver = RemoteHistoryObserver(coordinator: stack.container.persistentStoreCoordinator) { [weak self] in
            Task { await self?.handleRemoteChange() }
        }
    }
    private func handleRemoteChange() {
        guard !isClosed else { return }
        do { _ = try processHistory(); lastReconciliationError = nil }
        catch { lastReconciliationError = String(describing: error) }
    }

    /// The transport must authorize these pair/route bindings before calling.
    /// Save raw ingress first so a crash cannot discard quarantine/unknown bytes.
    @discardableResult
    func importHistory(_ inputs: [RoutedInput]) throws -> ReconciliationSnapshot {
        try require(inputs.allSatisfy { $0.route != .local }, "Imports need a history route")
        let context = stack.backgroundContext()
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Ingress")
            request.affectedStores = [try stack.store(.local)]
            var existing = Set(try context.fetch(request).map { try Self.ingress($0) })
            for input in inputs where existing.insert(input).inserted {
                let row = try insert("Ingress", in: context, route: .local)
                row.setValue(input.pairID, forKey: "pairID")
                row.setValue(input.route.rawValue, forKey: "route")
                row.setValue(input.bytes, forKey: "bytes")
            }
            if context.hasChanges { try context.save() }
        }
        try rebuildFailure(.afterIngressSave)
        return try processHistory()
    }

    /// Full reductions are intentional in this first version. Tokens identify
    /// observed history, but loss/expiry never prevents a complete rebuild.
    @discardableResult
    func processHistory() throws -> ReconciliationSnapshot {
        let initial = try sources()
        let ingested = RevisionIngestion.ingest(initial.inputs)
        let preliminary = RevisionReducer.rebuild(initial.inputs)
        let prohibited = Set(preliminary.projections.filter { $0.status == .quarantined || $0.status == .unsupported }.map(\.key))
        for input in initial.ingress.sorted(by: { $0.sortKey < $1.sortKey }) {
            guard case .supported(let revision) = try? PortableRevision.decode(input.bytes),
                  revision.pairID == input.pairID, ingested.records[revision.revisionID] == revision,
                  !prohibited.contains(revision.key) else { continue }
            try persistImported(revision, route: input.route)
        }
        // Capture tokens BEFORE reading the source set. A concurrent cloud write
        // after this point is included now or safely replayed on the next pass.
        let tokens = try captureHistoryTokens()
        let source = try sources()
        let snapshot = RevisionReducer.rebuild(source.inputs, routingIncomplete: source.incomplete)
        let context = stack.backgroundContext()
        try context.performAndWait {
            for entity in ["Projection", "SyncCursor", "ReconciliationState"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.affectedStores = [try stack.store(.local)]
                for object in try context.fetch(request) { context.delete(object) }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for projection in snapshot.projections {
                let row = try insert("Projection", in: context, route: .local)
                row.setValue(projection.key.pairID, forKey: "pairID")
                row.setValue(projection.key.entityID, forKey: "entityID")
                row.setValue(projection.key.type.rawValue, forKey: "entityType")
                row.setValue(projection.status.rawValue, forKey: "state")
                row.setValue(try encoder.encode(projection), forKey: "snapshotBytes")
            }
            for origin in snapshot.ranges {
                let row = try insert("SyncCursor", in: context, route: .local)
                row.setValue("ranges", forKey: "scope")
                row.setValue(origin.origin.pairID, forKey: "pairID")
                row.setValue(origin.origin.deviceID, forKey: "originDeviceID")
                row.setValue(try encoder.encode(origin.received), forKey: "receivedRanges")
            }
            for (route, token) in tokens {
                let row = try insert("SyncCursor", in: context, route: .local)
                row.setValue("history-\(route.rawValue)", forKey: "scope")
                row.setValue(token, forKey: "historyToken")
            }
            let state = try insert("ReconciliationState", in: context, route: .local)
            state.setValue("current", forKey: "key")
            state.setValue(try encoder.encode(snapshot), forKey: "snapshotBytes")
            try rebuildFailure(.beforeProjectionSave)
            try context.save() // Projection set, totals, ranges and tokens commit together.
        }
        try rebuildFailure(.afterProjectionSave)
        lastReconciliationError = nil
        return snapshot
    }

    func cachedSnapshot() throws -> ReconciliationSnapshot? {
        let context = stack.backgroundContext()
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ReconciliationState")
            request.affectedStores = [try stack.store(.local)]
            request.predicate = NSPredicate(format: "key == %@", "current")
            guard let bytes = try context.fetch(request).first?.value(forKey: "snapshotBytes") as? Data else { return nil }
            let snapshot = try JSONDecoder().decode(ReconciliationSnapshot.self, from: bytes)
            let projections = NSFetchRequest<NSManagedObject>(entityName: "Projection")
            projections.affectedStores = [try stack.store(.local)]
            guard try context.count(for: projections) == snapshot.projections.count else { return nil }
            return snapshot
        }
    }

    /// Recovery action: never deletes ingress, reservations, enrollments or history.
    func discardRebuildableState() throws {
        let context = stack.backgroundContext()
        try context.performAndWait {
            for entity in ["Projection", "SyncCursor", "ReconciliationState"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.affectedStores = [try stack.store(.local)]
                for object in try context.fetch(request) { context.delete(object) }
            }
            try context.save()
        }
    }

    private nonisolated static func ingress(_ row: NSManagedObject) throws -> RoutedInput {
        guard let pairID = row.value(forKey: "pairID") as? UUID,
              let routeName = row.value(forKey: "route") as? String,
              let route = StoreRoute(rawValue: routeName), route != .local,
              let bytes = row.value(forKey: "bytes") as? Data else { throw PersistenceError.corrupt("Ingress") }
        return RoutedInput(pairID: pairID, route: route, bytes: bytes)
    }

    private struct Sources { let inputs: [RoutedInput]; let ingress: [RoutedInput]; let incomplete: Bool }
    private func sources() throws -> Sources {
        let context = stack.backgroundContext()
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Ingress")
            request.affectedStores = [try stack.store(.local)]
            let ingress = try context.fetch(request).map { try Self.ingress($0) }
            var inputs = ingress
            var incomplete = false
            for route in [StoreRoute.private, .shared] {
                let store = try stack.store(route)
                let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorRevision")
                request.affectedStores = [store]
                for row in try context.fetch(request) {
                    guard let root = row.value(forKey: "root") as? NSManagedObject,
                          root.objectID.persistentStore === store,
                          let pairID = root.value(forKey: "pairID") as? UUID,
                          let bytes = row.value(forKey: "revisionBytes") as? Data else { incomplete = true; continue }
                    inputs.append(RoutedInput(pairID: pairID, route: route, bytes: bytes))
                }
            }
            return Sources(inputs: inputs, ingress: ingress, incomplete: incomplete)
        }
    }

    private func persistImported(_ revision: RecordRevision, route: StoreRoute) throws {
        let bytes = try PortableRevision.supported(revision).encoded()
        let context = stack.backgroundContext()
        try context.performAndWait {
            let store = try stack.store(route)
            let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorRevision")
            request.affectedStores = [store]
            // The raw envelope is authoritative; mirrored index attributes can
            // arrive partially or out of order. Never deduplicate on an index alone.
            for row in try context.fetch(request) {
                guard let existingBytes = row.value(forKey: "revisionBytes") as? Data,
                      case .supported(let existing) = try? PortableRevision.decode(existingBytes) else { continue }
                if existing.revisionID == revision.revisionID || (existing.origin == revision.origin && existing.originSequence == revision.originSequence) {
                    guard try PortableRevision.supported(existing).encoded() == bytes else { throw PersistenceError.corrupt("Concurrent import identity collision") }
                    return
                }
            }
            let roots = NSFetchRequest<NSManagedObject>(entityName: "MirrorPair")
            roots.affectedStores = [store]
            roots.predicate = NSPredicate(format: "pairID == %@", revision.pairID as NSUUID)
            let root = try context.fetch(roots).first ?? insert("MirrorPair", in: context, route: route)
            root.setValue(revision.pairID, forKey: "pairID")
            let row = try insert("MirrorRevision", in: context, route: route)
            row.setValue(revision.revisionID, forKey: "revisionID")
            row.setValue(revision.pairID, forKey: "pairID")
            row.setValue(revision.entityID, forKey: "entityID")
            row.setValue(revision.entityType.rawValue, forKey: "entityType")
            row.setValue(revision.originDeviceID, forKey: "originDeviceID")
            row.setValue(revision.originSequence.rawValue, forKey: "originSequence")
            row.setValue(bytes, forKey: "revisionBytes")
            row.setValue(root, forKey: "root")
            try context.save()
        }
    }

    private func captureHistoryTokens() throws -> [StoreRoute: Data] {
        let context = stack.backgroundContext()
        return try context.performAndWait {
            var tokens: [StoreRoute: Data] = [:]
            for route in [StoreRoute.private, .shared] {
                let cursor = NSFetchRequest<NSManagedObject>(entityName: "SyncCursor")
                cursor.affectedStores = [try stack.store(.local)]
                cursor.predicate = NSPredicate(format: "scope == %@", "history-\(route.rawValue)")
                let data = try context.fetch(cursor).first?.value(forKey: "historyToken") as? Data
                var token: NSPersistentHistoryToken? = data.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: $0) }
                func fetch(after token: NSPersistentHistoryToken?) throws -> [NSPersistentHistoryTransaction] {
                    let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
                    request.affectedStores = [try stack.store(route)]
                    let result = try context.execute(request) as? NSPersistentHistoryResult
                    return result?.result as? [NSPersistentHistoryTransaction] ?? []
                }
                let transactions: [NSPersistentHistoryTransaction]
                do { transactions = try fetch(after: token) }
                catch { token = nil; transactions = try fetch(after: nil) }
                if let latest = transactions.last?.token ?? token {
                    tokens[route] = try NSKeyedArchiver.archivedData(withRootObject: latest, requiringSecureCoding: true)
                }
            }
            return tokens
        }
    }
}

/// NotificationCenter registration/removal is thread-safe; no managed objects
/// or notifications cross the actor boundary, only a request to rebuild.
final class RemoteHistoryObserver: @unchecked Sendable {
    private let token: any NSObjectProtocol
    init(coordinator: NSPersistentStoreCoordinator, onChange: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: coordinator, queue: nil) { _ in onChange() }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}
