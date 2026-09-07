import Foundation

struct WriteCommand: Equatable, Sendable {
    let operationID: UUID
    let pair: Pair
    let authorPlayerID: UUID
    let route: StoreRoute
    let entityType: EntityType
    let entityID: UUID
    let operation: RevisionOperation
    let payload: DomainRecord?
    let parentRevisionIDs: [UUID]
    let recordedAt: Timestamp
}

enum WriteStage: CaseIterable, Equatable, Sendable {
    case beforeReservation, afterReservation, beforeRevisionPersistence
    case afterRevisionPersistence, beforeAcknowledgment, afterAcknowledgment
}

struct StoredRevision: Equatable, Sendable {
    let route: StoreRoute
    let bytes: Data
}
