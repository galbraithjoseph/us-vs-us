# Core Data storage and durability

The checked-in `UsVsUsModel.xcdatamodeld` retains baseline `UsVsUsModelV1` (identifier `1`) and uses `UsVsUsModelV2` (identifier `2`) for the local reconciliation inbox/snapshot/cursor additions. `StoreStack` opens three SQLite stores in a caller-supplied directory. The directory must be scoped to the correct account/share lifecycle by the synchronization layer; it is not a global mixed-account database.

| File | Model configuration | Contents | Cloud mirroring |
| --- | --- | --- | --- |
| `private.sqlite` | Mirrored | Pair routing roots and immutable revision bytes/indices | Private scope when a real container ID is supplied |
| `shared.sqlite` | Mirrored | Partner-owned pair roots and revision bytes/indices | Shared scope when a real container ID is supplied |
| `local.sqlite` | Local | Enrollment epochs/counters, durable reservations/receipts, projections, sync cursors, ingress, reconciliation snapshots | Never enabled |

`MirrorPair` is a routing/share root, not authority for player membership or scores. `MirrorRevision.revisionBytes` contains the complete portable envelope. Index fields are conveniences; imports must validate them against the envelope. Root/revision relationships are optional, inverse, unordered, and assigned to the same store. Local projections/bookkeeping reference UUIDs and have no cross-store relationships. The model uses optional attributes/defaults and no uniqueness constraints, following [Apple's model requirements](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit).

The stack creates `NSPersistentCloudKitContainer` store descriptions with explicit configurations. Passing no cloud container ID disables mirroring for on-disk tests. Supplying a provisioned ID configures private/shared database scopes; this code alone is not proof that sharing or account authorization works. [Apple documents the per-store database scope](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontaineroptions/databasescope). Capabilities, actual pair sharing, participant authorization, and real account/device verification belong to issue #6.

## Serialized local writes

`RevisionRepository` is an actor. Each operation uses private Core Data contexts and completes synchronously inside actor isolation, so another write cannot interleave a reservation. Managed objects remain within `performAndWait` context queues; only immutable portable values leave them. Per-context error merge policies surface persistence errors instead of merging business fields. An advisory OS lock prevents a second repository from opening the same directory. Close/drain the repository before opening another one or migrating its files.

Use the recovering/observing `await RevisionRepository.open(...)` entry point, then call `enroll(pair:playerID:route:at:)` before new writes. It validates pair membership, creates the local enrollment and its Device-create reservation in one local save, then persists that revision to the explicit route. Logical bootstrap dependencies may arrive out of order; reconciliation validates the complete pair/player/device graph later.

A caller creates a `WriteCommand` with a stable `operationID`. Retain that ID and the exact command until the operation finishes; a retry with changed contents under the same operation ID is rejected. New writes use this protocol:

1. In one **local-only** transaction, reserve a revision ID and origin sequence, store the full encoded revision and target route, and increment the enrollment counter. At Int64 maximum, the next counter becomes a zero exhaustion sentinel; it never wraps or reuses a positive sequence.
2. In one transaction involving **only the selected mirrored store**, find the pair's routing root, assign the revision to that same store/root, and save. A matching revision ID or origin/sequence must have identical bytes. Identical retry deliveries are a no-op; conflicting identity content fails.
3. In a separate **local-only** transaction, mark the reservation acknowledged. Acknowledged means locally durable, not uploaded to CloudKit.

No multi-store save is treated as atomic. SQLite stores use WAL with FULL synchronization. The counter and encoded outbox entry commit together; the mirrored write and local acknowledgment happen afterward. No caller is told a write succeeded before both the history row and local receipt exist. An error after a durable boundary may mean the operation already committed; retrying the original operation ID returns that same revision.

## Recovery and retained receipts

`recover()` replays every reservation, including acknowledged receipts. This repairs crash windows after reservation or history persistence, and handles a copied backup whose local receipt is newer than its mirrored database. It never regenerates revision IDs, writer IDs, sequence numbers, parents, or payloads during replay. It then acknowledges the local receipt. Repeating recovery does not duplicate history rows.

Receipts remain indefinitely in this first implementation. Deleting them would weaken recovery across independently restored stores; compaction requires a separately designed protocol and is deferred. Received ranges/history tokens and projections are handled by the [reconciliation layer](Reconciliation.md). Cloud transport verification is still separate.

The synchronization layer must gate opening/recovery on the correct account and current share access. It must not replay a revoked partner's receipts into a newly authorized account or redirect shared data to a private store. Missing stores and load failures are errors, not requests to silently change route or erase databases.

## Installation, restart, and copied backups

A writer is an **enrollment epoch**, not a hardware identifier. Every `RevisionRepository` open generates a fresh in-memory epoch UUID, and each pair gets a fresh Device UUID for new writes in that epoch. Enrollment records persist the epoch under the physical field name `installationToken`; the currently active epoch is never loaded from a backup. New Device-create revisions make these bindings portable. Existing revision origins and old enrollments remain immutable.

This deliberately rotates the writer on ordinary repository restart as well as reinstall/restore. It avoids relying on backup exclusion hints or restored keychain counters to prove that a counter has never been rewound. A copy of every database, including the old enrollment/counter rows, cannot make two new repository instances use the same writer ID. Pending/acknowledged old reservations still replay their original bytes safely. Logical player identity stays stable across these writer epochs; future device UI must distinguish writer epochs from physical devices, rather than presenting each epoch as a new person.

The tradeoff is a small additional Device revision per active pair/repository session. Never open a new repository per action; keep it alive for the account session. UUID generation is injectable for tests, but production must generate fresh random UUIDs and never supply a restored/deterministic epoch generator. Device UUIDs and this local mechanism are not transport credentials or authorization.

## Load errors and migrations

The baseline model is bundled and explicitly versioned. Store descriptions enable automatic migration and inferred mappings so future additive model versions can retain old `.mom` versions in the bundle. Unknown/incompatible/corrupt store loads throw an error and preserve the existing files; no empty-store fallback is used. The app's recovery/status UI is implemented in the subsequent lifecycle issues.

`StoreMigration.migrateCopy` provides an explicit staging harness: require a new destination path, verify source-model compatibility for the named configuration, infer a mapping, migrate into the staging file, and verify destination compatibility. It does not promote a staged file or overwrite the source. A future migration must hold the writer lock, close all contexts/stores, validate its domain invariants in the staged store, and use coordinator-managed store replacement only after those checks. Migrate each store separately, preserving reservations so recovery can repair mixed-version interruption windows. Do not edit a shipped model version in place.

The migration test uses the bundled V1 as source and an in-test next version with one optional projection attribute. It checks the source remains V1-readable and that the staged destination preserves UUID/data values. This is baseline infrastructure and an additive migration exercise, not a claim that all future schema changes migrate automatically.

## Local evidence

Run `SIMULATOR_ID=<UUID> iOS/Scripts/validate.sh all` from the repository root. The suite uses real temporary on-disk SQLite stores and tests:

- Version/configuration membership, CloudKit-compatible attributes/relationships, no local mirroring, and same-store root/revision routing.
- Restart persistence, directory-lock exclusion, and corrupt-load preservation.
- Failures before/after reservation, history persistence, and acknowledgment, followed by reopen/recovery/retry.
- Concurrent actor writes, unique monotonic origin sequences, invalid-write rollback, and operation-ID reuse rejection.
- Full store copies with a missing/older mirrored database: acknowledged revisions recover, while new writer enrollments differ from both the backup and the original's next session.
- Baseline additive migration preserving source files and values.

These are deterministic failure-boundary simulations and SQLite integration tests. They are not physical power-loss tests or CloudKit account/device evidence. Detailed commands, tested commits, simulator IDs, and retained result-bundle paths belong in the issue PR.
