import CoreData
import Foundation

/// One actor and one OS directory lock serialize all local reservations/writes.
/// A fresh epoch on every open prevents copied/rewound backups cloning a writer.
actor RevisionRepository {
    private let stack: StoreStack
    private let epoch: String
    private let makeUUID: @Sendable () -> UUID
    private var failure: @Sendable (WriteStage) throws -> Void = { _ in }

    init(directory: URL, cloudContainerIdentifier: String? = nil, makeUUID: @escaping @Sendable () -> UUID = UUID.init) throws {
        self.makeUUID = makeUUID
        epoch = makeUUID().uuidString
        stack = try StoreStack(directory: directory, cloudContainerIdentifier: cloudContainerIdentifier)
    }

    func setFailureInjector(_ failure: @escaping @Sendable (WriteStage) throws -> Void) { self.failure = failure }
    func close() throws { try stack.close() }

    /// Starts a new writer enrollment for this repository session and pair.
    /// Its Device create is itself durably reserved before any user revision.
    func enroll(pair: Pair, playerID: UUID, route: StoreRoute, at time: Timestamp) throws -> Device {
        try DomainRecord.pair(pair).validateStructure()
        try require(route != .local, "Revisions require a mirrored route")
        try require(playerID == pair.playerOneID || playerID == pair.playerTwoID, "Writer is not a pair member")
        let context = stack.backgroundContext()
        let device: Device = try context.performAndWait {
            if let row = try enrollment(pairID: pair.pairID, in: context) {
                try require(row.value(forKey: "playerID") as? UUID == playerID, "Writer cannot switch player")
                guard let id = row.value(forKey: "deviceID") as? UUID, let created = row.value(forKey: "createdAt") as? Int64 else { throw PersistenceError.corrupt("Enrollment") }
                guard try reservation(id, in: context)?.value(forKey: "route") as? String == route.rawValue else { throw PersistenceError.operationMismatch }
                return Device(deviceID: id, pairID: pair.pairID, playerID: playerID, createdAt: Timestamp(created), displayLabel: nil)
            }
            let device = Device(deviceID: makeUUID(), pairID: pair.pairID, playerID: playerID, createdAt: time, displayLabel: nil)
            let row = try insert("Enrollment", in: context, route: .local)
            row.setValue(pair.pairID, forKey: "pairID")
            row.setValue(playerID, forKey: "playerID")
            row.setValue(device.deviceID, forKey: "deviceID")
            row.setValue(epoch, forKey: "installationToken")
            row.setValue(Int64(1), forKey: "nextSequence")
            row.setValue(time.microsecondsSince1970, forKey: "createdAt")
            // The first device revision and enrollment are reserved in one local save.
            let command = WriteCommand(operationID: device.deviceID, pair: pair, authorPlayerID: playerID, route: route,
                                       entityType: .device, entityID: device.deviceID, operation: .create,
                                       payload: .device(device), parentRevisionIDs: [], recordedAt: time)
            _ = try reserve(command, enrollment: row, in: context)
            try context.save()
            return device
        }
        try deliver(operationID: device.deviceID, pair: pair)
        return device
    }

    @discardableResult
    func write(_ command: WriteCommand) throws -> RecordRevision {
        try require(command.route != .local, "Revisions require a mirrored route")
        try DomainRecord.pair(command.pair).validateStructure()
        try require(command.authorPlayerID == command.pair.playerOneID || command.authorPlayerID == command.pair.playerTwoID, "Author is not a pair member")
        try failure(.beforeReservation)
        let context = stack.backgroundContext()
        let revision: RecordRevision = try context.performAndWait {
            if let row = try reservation(command.operationID, in: context) {
                let stored = try decode(row)
                try requireMatches(stored, row: row, command: command)
                return stored
            }
            guard let enrollment = try enrollment(pairID: command.pair.pairID, in: context) else { throw PersistenceError.corrupt("Enroll before writing") }
            guard enrollment.value(forKey: "playerID") as? UUID == command.authorPlayerID,
                  let deviceID = enrollment.value(forKey: "deviceID") as? UUID,
                  try reservation(deviceID, in: context)?.value(forKey: "route") as? String == command.route.rawValue else { throw PersistenceError.operationMismatch }
            let revision = try reserve(command, enrollment: enrollment, in: context)
            try context.save() // Only Local configuration objects are dirty here.
            return revision
        }
        try failure(.afterReservation)
        try deliver(operationID: command.operationID, pair: command.pair)
        return revision
    }

    /// Replays ALL reservations, including acknowledged ones: restored stores may
    /// represent different backup instants. Retained local receipts repair that gap.
    func recover() throws {
        let context = stack.backgroundContext()
        let pending: [(UUID, UUID)] = try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Reservation")
            request.affectedStores = [try stack.store(.local)]
            return try context.fetch(request).map { row in
                guard let operationID = row.value(forKey: "operationID") as? UUID else { throw PersistenceError.corrupt("Reservation operation ID") }
                return (operationID, try decode(row).pairID)
            }
        }
        for (operationID, pairID) in pending {
            // Routing roots carry no authoritative business fields. Domain pair
            // snapshots in the log determine membership and creation time.
            try deliver(operationID: operationID, pairID: pairID)
        }
    }

    func revisions(in route: StoreRoute) throws -> [StoredRevision] {
        try require(route != .local, "History is in mirrored stores")
        let context = stack.backgroundContext()
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorRevision")
            request.affectedStores = [try stack.store(route)]
            return try context.fetch(request).map {
                guard let bytes = $0.value(forKey: "revisionBytes") as? Data else { throw PersistenceError.corrupt("Revision bytes") }
                return StoredRevision(route: route, bytes: bytes)
            }
        }
    }

    func isAcknowledged(_ operationID: UUID) throws -> Bool {
        let context = stack.backgroundContext()
        return try context.performAndWait { try reservation(operationID, in: context)?.value(forKey: "acknowledged") as? Bool ?? false }
    }

    private nonisolated func enrollment(pairID: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Enrollment")
        request.affectedStores = [try stack.store(.local)]
        request.predicate = NSPredicate(format: "pairID == %@ AND installationToken == %@", pairID as NSUUID, epoch)
        let rows = try context.fetch(request)
        guard rows.count <= 1 else { throw PersistenceError.corrupt("Duplicate enrollment") }
        return rows.first
    }
    private nonisolated func reservation(_ id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Reservation")
        request.affectedStores = [try stack.store(.local)]
        request.predicate = NSPredicate(format: "operationID == %@", id as NSUUID)
        let rows = try context.fetch(request)
        guard rows.count <= 1 else { throw PersistenceError.corrupt("Duplicate reservation") }
        return rows.first
    }
    private nonisolated func insert(_ entity: String, in context: NSManagedObjectContext, route: StoreRoute) throws -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        context.assign(object, to: try stack.store(route))
        return object
    }
    private nonisolated func decode(_ row: NSManagedObject) throws -> RecordRevision {
        guard let bytes = row.value(forKey: "revisionBytes") as? Data,
              case .supported(let revision) = try PortableRevision.decode(bytes) else { throw PersistenceError.corrupt("Reservation bytes") }
        return revision
    }
    private nonisolated func reserve(_ command: WriteCommand, enrollment: NSManagedObject, in context: NSManagedObjectContext) throws -> RecordRevision {
        guard let sequence = enrollment.value(forKey: "nextSequence") as? Int64, sequence > 0 else { throw PersistenceError.sequenceExhausted }
        guard let deviceID = enrollment.value(forKey: "deviceID") as? UUID else { throw PersistenceError.corrupt("Writer ID") }
        let revision = RecordRevision(schemaVersion: 1, revisionID: makeUUID(), pairID: command.pair.pairID,
                                      entityType: command.entityType, entityID: command.entityID,
                                      originDeviceID: deviceID, originSequence: DecimalInt64(rawValue: sequence),
                                      authorPlayerID: command.authorPlayerID, recordedAt: command.recordedAt,
                                      parentRevisionIDs: command.parentRevisionIDs.sorted { $0.uuidString < $1.uuidString },
                                      operation: command.operation, payload: command.payload)
        let bytes = try PortableRevision.supported(revision).encoded()
        let row = try insert("Reservation", in: context, route: .local)
        row.setValue(command.operationID, forKey: "operationID")
        row.setValue(revision.revisionID, forKey: "revisionID")
        row.setValue(command.pair.pairID, forKey: "pairID")
        row.setValue(bytes, forKey: "revisionBytes")
        row.setValue(command.route.rawValue, forKey: "route")
        row.setValue(false, forKey: "acknowledged")
        enrollment.setValue(sequence == Int64.max ? 0 : sequence + 1, forKey: "nextSequence")
        return revision
    }
    private nonisolated func requireMatches(_ revision: RecordRevision, row: NSManagedObject, command: WriteCommand) throws {
        guard revision.pairID == command.pair.pairID, revision.authorPlayerID == command.authorPlayerID,
              revision.entityType == command.entityType, revision.entityID == command.entityID,
              revision.operation == command.operation, revision.payload == command.payload,
              revision.parentRevisionIDs == command.parentRevisionIDs.sorted(by: { $0.uuidString < $1.uuidString }),
              revision.recordedAt == command.recordedAt, row.value(forKey: "route") as? String == command.route.rawValue else {
            throw PersistenceError.operationMismatch
        }
    }
    private func deliver(operationID: UUID, pair: Pair) throws { try deliver(operationID: operationID, pairID: pair.pairID) }

    private func deliver(operationID: UUID, pairID: UUID) throws {
        let local = stack.backgroundContext()
        let (revision, bytes, route): (RecordRevision, Data, StoreRoute) = try local.performAndWait {
            guard let row = try reservation(operationID, in: local),
                  let bytes = row.value(forKey: "revisionBytes") as? Data,
                  let routeName = row.value(forKey: "route") as? String,
                  let route = StoreRoute(rawValue: routeName), route != .local else { throw PersistenceError.corrupt("Reservation route") }
            let revision = try decode(row)
            try require(revision.pairID == pairID, "Reservation pair mismatch")
            return (revision, bytes, route)
        }
        try failure(.beforeRevisionPersistence)
        let mirrored = stack.backgroundContext()
        try mirrored.performAndWait {
            let store = try stack.store(route)
            let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorRevision")
            request.affectedStores = [store]
            request.predicate = NSPredicate(format: "revisionID == %@ OR (pairID == %@ AND originDeviceID == %@ AND originSequence == %lld)", revision.revisionID as NSUUID, pairID as NSUUID, revision.originDeviceID as NSUUID, revision.originSequence.rawValue)
            let matches = try mirrored.fetch(request)
            for match in matches {
                guard match.value(forKey: "revisionBytes") as? Data == bytes else { throw PersistenceError.corrupt("Conflicting revision identity") }
            }
            if matches.isEmpty {
                let roots = NSFetchRequest<NSManagedObject>(entityName: "MirrorPair")
                roots.affectedStores = [store]
                roots.predicate = NSPredicate(format: "pairID == %@", pairID as NSUUID)
                let root = try mirrored.fetch(roots).first ?? insert("MirrorPair", in: mirrored, route: route)
                root.setValue(pairID, forKey: "pairID")
                let row = try insert("MirrorRevision", in: mirrored, route: route)
                row.setValue(revision.revisionID, forKey: "revisionID")
                row.setValue(pairID, forKey: "pairID")
                row.setValue(revision.entityID, forKey: "entityID")
                row.setValue(revision.entityType.rawValue, forKey: "entityType")
                row.setValue(revision.originDeviceID, forKey: "originDeviceID")
                row.setValue(revision.originSequence.rawValue, forKey: "originSequence")
                row.setValue(bytes, forKey: "revisionBytes")
                row.setValue(root, forKey: "root")
                try mirrored.save() // Only one mirrored store participates.
            }
        }
        try failure(.afterRevisionPersistence)
        try failure(.beforeAcknowledgment)
        try local.performAndWait {
            guard let row = try reservation(operationID, in: local) else { throw PersistenceError.corrupt("Lost reservation") }
            row.setValue(true, forKey: "acknowledged")
            try local.save() // Separate local acknowledgment transaction.
        }
        try failure(.afterAcknowledgment)
    }
}
