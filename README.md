# Us vs Us

A paired scorekeeping app for tracking lifetime game wins between two people.

Us vs Us is the working app name. The proposed implementation is Apple-first: **SwiftUI + Core Data + iCloud/CloudKit**, with possible later peer-to-peer Android interoperability. This repository currently documents the design; it does not yet contain a runnable app.

## Repository layout

```text
README.md
iOS/        SwiftUI app, Core Data model, Apple synchronization, and tests
android/    Future Android app (directory not created yet)
```

Keep the Xcode project and all Apple implementation files under `iOS/` so the future Android app can live alongside them. Portable record and synchronization specifications will belong at the repository root, outside either platform implementation.

## Proposed architecture

```text
SwiftUI screens
      |
Application services: pairing, games, results, lifetime totals
      |
Portable domain records and revision rules
      |
Core Data local persistence
      |                                |
NSPersistentCloudKitContainer          Future P2P import/export
      |                                |
iCloud private/shared databases        Nearby authorized Android devices
```

- **SwiftUI** presents pair setup, a game catalog, match entry/history, and lifetime wins overall and per game.
- **Core Data** provides local persistence and offline reads/writes. Domain validation and result calculation live in application services, independently of views and transport APIs.
- **NSPersistentCloudKitContainer + CKShare** synchronize a person's Apple devices and share the pair's data with the other person's iCloud account. No app-operated synchronization server or separate app account is planned.
- **Future Android** uses its own local persistence and the same portable logical records. Nearby P2P is a separate transport; Core Data object IDs and CloudKit record representations are not its wire format.

### Apple synchronization and sharing

Configure private and shared CloudKit-backed Core Data stores. The pair creator owns the data in their private database; the invited partner accepts a private `CKShare` with read/write permission and accesses it through their shared database. Model one isolated object graph/share per pair, rooted at `Pair`, and place its related data in that same share/store. New records must be assigned to the correct store and associated with the pair's shared graph.

The app permits exactly two player identities per pair and supports multiple devices for either player. Bind the accepting iCloud participant to the existing second player identity; an installation is not a new player. Keep platform account/share bindings separate from portable player IDs. Do not enable public-link sharing or invite additional participants through the app.

Apple devices can synchronize regardless of physical location when iCloud is available. Synchronization is eventual, not instantaneous; the UI should show pending changes, errors, and last successful synchronization. Local use remains available offline. Initial invitations and share acceptance require iCloud connectivity.

CloudKit sharing has an owner. Revocation, account changes, and share deletion require explicit UI handling; do not promise that the shared store survives loss of access. A future portable export/recovery design must be completed before promising ownership transfer or restoration from a former participant's device.

## Logical data model

These are proposed domain objects, not a finalized Core Data schema. Every replicated entity has an application-generated UUID, created once and preserved across devices, imports, and transports. Names are display values, never identifiers.

| Object | Proposed fields and purpose |
| --- | --- |
| `Pair` | `pairID: UUID`, `playerOneID: UUID`, `playerTwoID: UUID`, `createdAt`. Root of the shared history; the two player slots are stable. |
| `Player` | `playerID: UUID`, `pairID: UUID`, `displayName`. A person within this pair, independent of their Apple account and devices. Both player records may exist before the partner accepts an invitation. |
| `Game` | `gameID: UUID`, `pairID: UUID`, `name: String`, `highScoreWins: Bool`, `isArchived: Bool`. A pair-scoped game definition; `true` means higher score wins, `false` means lower score wins. |
| `GameEvent` | `eventID: UUID`, `pairID: UUID`, `gameID: UUID`, `playerOneID: UUID`, `playerTwoID: UUID`, `startedAt`, `finishedAt?`, `playerOneScore?`, `playerTwoScore?`, `highScoreWinsAtStart: Bool`, `status`, `outcome`, `winnerPlayerID?`. One played match, referring to a Game and both players. |
| `Device` | `deviceID: UUID`, `pairID: UUID`, `playerID: UUID`, `createdAt`, optional display label. Identifies one writer installation/enrollment; not a hardware identifier or authorization credential. |
| `RecordRevision` | `revisionID: UUID`, `pairID: UUID`, `entityType`, `entityID: UUID`, `originDeviceID: UUID`, `originSequence: Int64`, `authorPlayerID: UUID`, `recordedAt`, `schemaVersion`, `parentRevisionIDs`, `operation`, `payload`. Immutable create/update/void revisions carrying a complete logical record snapshot, or a tombstone. |
| `ReplicaState` (local only) | This installation's device identity and next sequence, plus per-pair/per-origin received sequence ranges and future peer acknowledgments. Synchronization bookkeeping, not shared business data. |

`Pair` owns its players, games, events, device records, and revision history. Each `Game` has many `GameEvent` records. UUID references remain in the portable schema even where Core Data relationships provide convenient navigation. Keep credentials and local account bindings out of the shared domain graph.

### Match and scoring rules

- Proposed scores are signed 64-bit integers, allowing negative scores. Fractional scoring is outside the initial proposal; a later format change must be versioned.
- `startedAt` is required. An `inProgress` event may have missing scores and no finish time or winner. A `completed` event requires both scores and `finishedAt >= startedAt`.
- Players must be the pair's two distinct members, and the game must belong to that pair. Both scores are explicitly associated with stable player IDs, never with whichever person is using the current device.
- Snapshot `Game.highScoreWins` when starting the event. Editing a game's rule affects new matches, not old results. Archiving a game hides it from new-match selection while preserving its history.
- On completion, calculate and store the winner using the snapshot rule. Equal scores produce `outcome = draw` and no winner; otherwise `outcome = win` and `winnerPlayerID` must identify the player with the winning score. In-progress or voided matches have no active winner. Validate these fields together on both local entry and import.
- Store timestamps as absolute instants and display them in the user's timezone. Clock time describes play/history; it does not decide synchronization conflicts.
- Lifetime totals are derived from distinct, completed, non-voided, non-conflicted events. Each match counts once; draws count as draws and give neither person a win. Any cached totals are local and rebuildable.

## Revisions and future P2P synchronization

Distinguish a **GameEvent** (a match) from a **RecordRevision** (a change to a record). Match creation, completion, correction, and voiding append immutable revisions under the same stable `eventID`. Game/name changes also use revisions. Current domain objects are rebuildable projections of that history; sync must not merge individual score/winner fields independently.

1. Generate UUIDs locally. Persist each local revision and increment its per-pair device sequence atomically. A new installation gets a fresh device ID; do not clone a writer identity/counter onto another device.
2. Preserve `revisionID`, origin device, and sequence on relay. Import idempotently by revision ID and validate that the same origin/sequence does not identify different content. Conflicting payloads under an existing identity are rejected or quarantined.
3. Rebuild projections and totals after local writes, CloudKit imports, and future P2P imports. CloudKit may deliver duplicate logical records or dependencies out of order; collapse identical revision IDs logically and defer projection until required records are present.
4. Each update references the revision(s) it supersedes. A descendant replaces its ancestor. Concurrent revisions remain an explicit conflict for user resolution; a resolving revision references all competing heads. Exclude conflicted matches from totals and show them for review. Do not choose a winner using device timestamps or a Core Data property merge policy.
5. Record removal as a retained void/tombstone revision. Do not physically erase replicated history during ordinary deletion, because an offline device could otherwise resurrect it. Compaction and retention remain future protocol decisions.
6. Future P2P exchanges versioned portable records and missing sequence ranges. Track gaps, not just the greatest sequence received: receiving revision 10 does not imply revisions 1–9 arrived. Preserve unknown schema versions without projecting unsupported data.

The revision log is authoritative. To avoid redundant CloudKit writes, derived current-state projections and totals should live in a separate local-only store with UUID references to mirrored history; Core Data relationships must not cross stores. CloudKit share-root and routing objects may be mirrored alongside the log, but must not become a second authority for scores or conflict resolution.

Future Android devices synchronize while physically nearby an authorized pair device. Either person's Apple device can relay imported records through CloudKit, and later export received records to Android. Plan a foreground “Sync nearby” flow; background discovery is not a correctness requirement. Transport selection, encoding, enrollment/authentication, revocation, and protocol compatibility negotiation still need design. Knowing a pair or device UUID is never sufficient authorization.

## Core Data implementation constraints

The physical model must accommodate CloudKit mirroring: attributes need optionality or suitable defaults, relationships must be optional and have inverses, and unique constraints and ordered relationships are unsupported. Enforce domain requirements and UUID deduplication in application/import logic, including after remote imports. Missing relationships during synchronization must not crash the UI or produce incomplete totals. See Apple's [Core Data model requirements](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit).

Use background contexts and persistent history/remote-change handling to reconcile imports and refresh SwiftUI. A Core Data merge policy handles persistence conflicts; the revision rules above handle application conflicts. Apple's [cross-user sharing sample](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users) describes private/shared stores and sharing entire related object graphs.

Before implementation, finalize the physical schema and migrations, minimum supported iOS version, bundle/container identifiers, signing, and iCloud capabilities. Before release, verify two-account sharing and additional-device sync, offline concurrent corrections, duplicate/out-of-order revision delivery, draws and low-score games, void propagation, and share revocation. Android and the P2P transport remain future work.
