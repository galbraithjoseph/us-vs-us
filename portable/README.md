# Portable records and revisions — schema 1

This specification and `fixtures/` are independent of SwiftUI, Core Data, and CloudKit. The Swift implementation is in `iOS/UsVsUs/Domain/`; the unit test bundle reads these root fixtures directly. No platform object ID, Apple account identifier, credential, or CloudKit record name is a portable identity or authorization credential.

## Encoding

One revision is one UTF-8 JSON object. `schemaVersion` is a positive JSON integer; version 1 has the closed fields below. UUIDs are standard hyphenated UUID strings; the Swift decoder accepts either case and the encoder emits uppercase. IDs are generated once and preserved on relay. Display names never identify records.

Every score, origin sequence, and timestamp is a **decimal JSON string**, never a JSON number. The exact range is −9223372036854775808 through 9223372036854775807. Canonical decimal syntax is `0`, positive digits without a leading zero, or `-` followed by nonzero digits; no `+`, whitespace, fraction, exponent, or `-0`. Scores use the full signed range. Sequences must be positive. Scoring compares values directly, without subtraction or other overflow-prone arithmetic.

Timestamps are signed Int64 **microseconds since 1970-01-01T00:00:00Z**, absolute instants. Negative values precede the epoch. Encoding performs no floating-point/date-formatter conversion, preserving all six microsecond digits and the entire Int64 range. Presentation converts supported instants to the user's timezone; clock values never rank revisions. Host time/UUID providers are injected by the app.

Optional fields may be omitted or null; encoding omits absent fields. Parent UUIDs are distinct and sorted lexicographically after uppercase normalization. JSON whitespace and object-key order are insignificant. Canonical output sorts object keys, omits optional nulls, and preserves array order. This is a data encoding, not a signature or authenticated transport protocol.

## Revision envelope

| Field | Meaning |
| --- | --- |
| `schemaVersion` | JSON integer, currently 1 |
| `revisionID` | Immutable UUID for this change |
| `pairID` | Owning pair UUID |
| `entityType` | `pair`, `player`, `game`, `gameEvent`, or `device` |
| `entityID` | UUID of the logical entity being revised |
| `originDeviceID` | Enrolled writer installation UUID, preserved by relays |
| `originSequence` | Positive decimal-string Int64, monotonic per pair/writer |
| `authorPlayerID` | Stable player UUID bound to that writer |
| `recordedAt` | Absolute microsecond timestamp |
| `parentRevisionIDs` | Sorted UUID array of superseded revisions of this same entity/pair |
| `operation` | `create`, `update`, or `void` |
| `payload` | For create/update: `{ "type": <entityType>, "value": <complete record> }`; absent/null for void |

A revision cannot parent itself, repeat a parent, mismatch its payload identity/type/pair, or use an invalid snapshot. Create has no parents; update/void requires at least one. Revisions and their snapshots are immutable values. Relay preserves identities, author, origin sequence, parents, timestamp, and payload. Reconciliation must reject/quarantine changed content under an existing revision ID or reused pair/origin/sequence; it must not silently overwrite it. Duplicate logical revisions must collapse even when CloudKit supplies duplicate physical rows.

Schema 1 rejects unknown envelope/payload fields, unknown enum cases, malformed UUIDs, invalid integers, and invalid result combinations. For any other positive schema version, the decoder retains the **original byte sequence** and version without interpreting fields or projecting it. A missing/nonpositive/noninteger/out-of-range version or syntactically invalid JSON is rejected. Unsupported bytes are for quarantine/relay by a future compatible implementation, never current totals.

## Complete snapshot fields

| Type | Required fields | Optional fields |
| --- | --- | --- |
| pair | `pairID`, `playerOneID`, `playerTwoID`, `createdAt` | None |
| player | `playerID`, `pairID`, `displayName` | None |
| game | `gameID`, `pairID`, `name`, `highScoreWins`, `isArchived` | None |
| device | `deviceID`, `pairID`, `playerID`, `createdAt` | `displayLabel` |
| gameEvent | `eventID`, `pairID`, `gameID`, `playerOneID`, `playerTwoID`, `startedAt`, `highScoreWinsAtStart`, `status`, `outcome` | `finishedAt`, `playerOneScore`, `playerTwoScore`, `winnerPlayerID` |

Names must contain non-whitespace text. Booleans are JSON booleans. The pair has exactly two distinct stable player slots. Players must occupy one of those slots, and devices bind to one player in that pair. Match slots must match the pair's ordered slots exactly, with both player records and the game belonging to that pair. UUID relationships check consistency; transport authorization must be enforced separately.

## Scoring and match state

Starting a match rejects archived/cross-pair games and copies the game's `highScoreWins` value. Later game edits never alter this snapshot, including on imported completed matches. Both player scores are associated with the fixed player slots.

- `inProgress`: either/both scores may be absent; `finishedAt` and `winnerPlayerID` must be absent; `outcome` is `none`.
- `completed`: both scores and `finishedAt` are required, and `finishedAt >= startedAt`. Equal scores require `draw` and no winner. Otherwise `win` and the exact high/low winner ID are required.
- `voided`: `outcome` is `none` and no winner is active. Retained scores/finish are optional. Any supplied finish must be at/after the start.

A completion service only completes an in-progress match. Corrections use a new complete snapshot and validate all fields again. A revision may correct play timestamps, scores, state, and outcome together, but never change the match's game, players, or rule snapshot. Incorrect winners are rejected on import, not silently repaired.

## Operations, dependencies, and conflicts

The full revision graph is authoritative; these rules are the contract for reconciliation in issue #5. The codec and direct-parent validators enforce structure, reference consistency, and immutable-field rules now; graph traversal, cycle detection, head selection, idempotent import, and totals are implemented in subsequent issues.

- **Pair setup:** generate a pair, two players, and the first enrolled device with distinct application IDs, then emit their create snapshots. The bootstrap graph contains mutually dependent references. Persist structurally valid revisions and defer semantic application until the complete pair/player/device dependency set is available. A missing dependency is a typed pending condition, not a valid projection or a reason to erase history.
- **Pair updates:** player slots and creation time are immutable. The current schema permits an identical update/resolution snapshot, not membership or ownership transfer.
- **Player updates:** display names may change. Player/pair identity is fixed. A name edit does not create a new person.
- **Game updates:** name, scoring rule, and archive state may change. Archive prevents new starts while retaining existing match validity. Ordinary catalog removal should archive; it should not physically delete history.
- **Device updates:** display labels may change; player binding and creation time are immutable. Reinstallation creates a new enrollment. Voiding an enrollment cannot invalidate past revisions from it; historical writer bindings are retained for validation. A device UUID is never proof of current authorization.
- **Match updates:** use complete snapshots for start, score entry, completion, and correction. Old snapshots remain in the log. A voided snapshot has no active result; ordinary removal appends a retained `void` tombstone.
- **Void for every entity:** retains identity and parent references with no payload. It removes that entity's active projection, not its history. A descendant update cannot resurrect a tombstone. Concurrent live and void heads are a conflict; resolving them must reference all heads and remain void. Multiple competing tombstones can be resolved by another void referencing all of them. A new logical entity requires a new ID.
- **Conflict resolution:** a descendant supersedes its ancestors. Independent heads (including competing creates) remain an explicit conflict; no timestamp, origin sequence, or field merge chooses one. An update resolution contains a complete valid snapshot and references every competing head, preserving immutable fields against every parent. If immutable fields themselves disagree, void the conflicted entity and create a new one. The reconciler must detect cycles and incomplete ancestry before projection.
- **Dependent metadata:** missing, unsupported, voided, or conflicted pair/player/game metadata keeps dependent matches pending/excluded from totals until usable dependencies are available. This conservative rule includes display-name-only conflicts. An unconflicted archived game remains usable for existing history. Historical enrollment snapshots validate old writer references independently of current device availability.
- **Totals:** count each distinct, completed, non-voided, non-conflicted, fully validated match once. Draws increment draws and neither player's wins. Projections and totals are local/rebuildable; the codec does not cache or calculate them.

Do not assume receiving sequence N means earlier sequences arrived. Storage/import will retain gaps, reserve sequences durably, and preserve original identities through retries. Parent ordering is canonical encoding only; it gives no head priority.

## Fixtures and tests

`01`–`06` create the initial pair/player/device/game/match graph. `07` completes with Int64 maximum/minimum scores and exact microsecond timestamps. `08` is a concurrent completion from the same start with scores beyond JavaScript's exact integer range. `09` resolves both heads; `10` voids the result. `unsupported-v2.json` must round-trip byte-for-byte without projection. `invalid-overflow.json` and `invalid-winner.json` must fail validation.

The local unit suite verifies these fixtures, malformed envelopes, unsupported retention, direct-parent rules, writer consistency, scoring boundaries, reference errors, and round trips. Run `SIMULATOR_ID=<UUID> iOS/Scripts/validate.sh unit`; use `all` to include the existing UI smoke suite. Fixtures are language-neutral inputs for future Android/P2P implementations, not a transport authorization design.
