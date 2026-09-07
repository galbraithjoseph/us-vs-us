# Revision ingestion, reconciliation, and recovery

`RevisionIngestion` and `RevisionReducer` are pure Foundation code. `ReconciliationRepository` connects them to the versioned Core Data stack without generating new business revisions during projection refreshes. The [portable schema](../../portable/README.md) defines the underlying immutable records.

## Set-based ingestion

Every input has raw bytes plus a trusted pair/store-route binding supplied by the authorized transport. Supported snapshots must agree with that pair binding and pass schema/scoring checks. A canonical supported encoding normalizes whitespace, key order, optional nulls, and UUID case, so reformatting and repeated imports do not create new logical revisions.

The reducer evaluates the whole available set. Different contents claiming one revision ID, or distinct revisions claiming one pair/origin/sequence, quarantine all claimants and block the affected logical records. It never accepts the first variant merely because it arrived earlier. Invalid but decodable schema-1 records still participate in identity-claim collision checks. Invalid JSON without usable identities is retained in quarantine. Quarantine diagnostics preserve original inputs; raw representations may differ between replicas, while equivalent valid revision sets converge to the same projections and totals.

Unsupported versions retain their exact bytes. Because a future envelope may not expose trustworthy entity/ancestry semantics, an unsupported input conservatively blocks projection of its routed pair until the app supports that version. This prevents an older app from counting an ancestor while silently ignoring a future correction/void.

Received sequence ranges represent received, structurally valid positions, including positions with identity collisions. Quarantine remains a separate status and is not silently fixed by advancing a cursor. Ranges retain gaps rather than assuming the highest sequence implies all earlier values arrived. Adjacent ranges merge without overflowing at Int64 maximum. Unsupported/invalid inputs do not advance supported sequence ranges.

## Graph and dependency reduction

The reducer validates direct parents and immutable fields, then processes the graph topologically without recursion. Missing parents remain pending. Cycles and their dependents are quarantined. Maximal, unsuperseded heads determine the state:

- One supported, validated live head produces a ready complete snapshot.
- Multiple heads remain a conflict; recorded time and origin sequence do not select a winner.
- A resolving revision supersedes its listed heads only. Omitting a competing head leaves a conflict.
- A retained void removes the active projection. Concurrent void/live heads remain a conflict until all heads are resolved; a tombstone cannot be resurrected by an update.
- Missing, conflicted, unsupported, or voided pair/player/game dependencies defer dependent matches.

Historical creation records validate writer bindings, including old revisions from retired enrollment epochs. Device display-label conflicts/retirement do not turn an old writer into a different person. Author consistency is checked for tombstones as well as live snapshots. This is data validation; actual account/participant authorization is the CloudKit service's separate responsibility.

Projection arrays and head IDs are sorted deterministically. Ready, distinct, completed matches contribute once to overall and per-game totals. Draws increment one draw count and neither player's wins. In-progress, voided, pending, conflicted, quarantined, and unsupported matches contribute no wins. Game rule edits use the old match snapshot, and archived unconflicted games retain their historical totals.

If a mirrored row's bytes or same-store share root are incomplete, the repository withholds totals until routing finishes. It does not crash, attach the row to an arbitrary pair, or present a partially counted scoreboard.

## Persistent integration

Model **V2** retains V1 and adds local-only `Ingress` and `ReconciliationState` entities plus the `SyncCursor.scope` attribute. Mirrored entity schemas are unchanged. Automatic V1→V2 migration is tested with an existing acknowledged reservation, followed by history recovery.

`importHistory` first saves each distinct raw input to the local ingress inbox. Accepted supported envelopes can then be copied to the correct mirrored pair graph while preserving their original revision/writer/sequence identity. Invalid, collided, and unsupported data remain available for quarantine/upgrade; they are not rewritten as new business revisions. Deduplication checks envelopes rather than trusting partially synchronized index columns. Transport authorization must precede this API.

Application code should use `await RevisionRepository.open(...)`: it recovers retained reservations/ingress, builds projections, and then registers persistent-store remote-change observation. Local enrollment/writes/recovery also invoke reconciliation. Closing removes the observer; queued notifications do not reopen closed stores. Processing failures are surfaced as errors or `lastReconciliationError` for later status UI.

Every reconciliation captures persistent-history tokens for private/shared stores **before** reading the current source set. A concurrent later import is either included in this pass or replayed in the next; the cursor never advances beyond a write that has not had an opportunity to be read. Tokens are securely archived per route. Missing, corrupt, or expired tokens fall back to full history; the authoritative set is fully reduced on every pass in this initial implementation. No persistent history is pruned yet.

One local-store transaction replaces entity projections, the aggregate snapshot/totals, sequence ranges, and history tokens together. A failure before this save leaves the previous complete snapshot; a failure after it leaves the new complete snapshot. There is no partially acknowledged rebuild across stores. Local cache saves do not request remote-change notifications, preventing a refresh feedback loop or redundant cloud revisions.

`discardRebuildableState()` deletes only projections/snapshot/cursors. It never deletes mirrored history, ingress, enrollment records, or durable write receipts. A later full pass rebuilds the same results. `cachedSnapshot()` is a cached read; it returns nil if the projection set was removed. Durable ingress and receipts are deliberately retained without compaction in this version.

## Verification and limits

Run `SIMULATOR_ID=<UUID> iOS/Scripts/validate.sh all`. Tests cover deterministic shuffled/repeated/incremental deliveries, missing dependencies, sequence gaps, identity collisions, partial/full resolution, concurrent void/edit, cycles, draw/unfinished/void handling, game metadata conflicts, and retired writers. On-disk tests cover repeated import and relay loops, projection deletion, corrupt-token recovery, interruptions at ingress/projection boundaries, automatic local-write refresh, remote-change notification processing, incomplete routing, quarantine/unknown retention, and baseline migration.

Notification tests simulate a remote persistent-store update locally. They are not proof of real CloudKit delivery, cross-account sharing, authorization, or device/account lifecycle behavior. Issue #6 supplies that separate gate. This implementation deliberately favors complete, deterministic rebuilds over incremental projection performance; future optimization must preserve the same results and durability boundaries.
