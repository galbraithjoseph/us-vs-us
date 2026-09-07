import CoreData
import Foundation

extension RevisionRepository {
    /// A revision and its pair relationship are saved together in one store.
    /// CloudKit infers the existing shared zone from this relationship. Never
    /// create a second root in the participant store while awaiting import.
    nonisolated func revisionRoot(pairID: UUID, route: StoreRoute, in context: NSManagedObjectContext,
                                  requireExistingSharedRoot: Bool? = nil) throws -> NSManagedObject {
        guard route != .local else { throw SharingError.invalidShare }
        let request = NSFetchRequest<NSManagedObject>(entityName: "MirrorPair")
        request.affectedStores = [try stack.store(.private), try stack.store(.shared)]
        request.predicate = NSPredicate(format: "pairID == %@", pairID as NSUUID)
        let roots = try context.fetch(request)
        guard roots.count <= 1 else { throw PersistenceError.corrupt("Ambiguous pair graph") }
        if let root = roots.first {
            guard root.objectID.persistentStore == (try stack.store(route)) else { throw SharingError.invalidShare }
            if stack.cloudEnabled && route == .shared {
                guard try stack.container.fetchShares(matching: [root.objectID])[root.objectID] != nil,
                      stack.container.canUpdateRecord(forManagedObjectWith: root.objectID) else { throw SharingError.permissionDenied }
            }
            return root
        }
        guard route != .shared || !(requireExistingSharedRoot ?? stack.cloudEnabled) else { throw SharingError.awaitingImport }
        let root = try insert("MirrorPair", in: context, route: route)
        root.setValue(pairID, forKey: "pairID")
        return root
    }
}
