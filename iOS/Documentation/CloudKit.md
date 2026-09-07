# CloudKit sharing and device verification

Issue #6 is **not complete** until the real-account tests below pass. The implementation, simulator tests, successful provisioning, and installed app do not demonstrate real sharing. The development harness is intentionally separate from the product setup UI scheduled in #7.

## Configuration

- App: `com.galbraiths.joseph1970.usvsus`.
- Developer: Joseph Galbraith, team `ZBQ9AKMQTP`.
- Container: `iCloud.com.galbraiths.joseph1970.usvsus`.
- Private and shared SQLite stores use `NSPersistentCloudKitContainerOptions` with their respective database scopes. The local configuration never mirrors.
- App entitlements include this container, CloudKit, development iCloud environment, and development APNs. Info.plist enables CloudKit sharing and background remote notifications. The harness registers for silent remote notifications; it does not request alert permission.
- Debug and Release are currently configured for the **development** CloudKit environment. These are development device builds, not an App Store/production deployment configuration.
- Xcode automatic provisioning must associate this exact app identifier with this container under the Joseph Galbraith team. Do not substitute another organization available in the keychain.

Build and verify before device checks:

```sh
xcodebuild -project iOS/UsVsUs.xcodeproj -scheme UsVsUs -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath iOS/.build-device \
  -allowProvisioningUpdates build

iOS/Scripts/verify-device-signing.sh \
  iOS/.build-device/Build/Products/Debug-iphoneos/UsVsUs.app \
  iOS/TestResults/cloud-signing
```

The script verifies the signature, app entitlements, provisioning profile association, and profile expiration. It retains only the relevant public provisioning summary, not the full device list/profile. Signing evidence on 2026-09-07 UTC passed. Xcode is 27.0 (27A5252f).

A CloudKit management token is not required for app provisioning or the development-schema API. `cktool get-teams` was unavailable because this machine has no management token configured. Provisioning verification above succeeded through Xcode instead.

## Sharing and authorization boundaries

`CloudAccountService`, `PairShareTransport`, and `CloudSyncService` are injectable. `SharingService` serializes UI operations, verifies account continuity around awaits, and validates ownership/permissions. The concrete adapter resolves one email to a CloudKit participant, sets read/write permission, disables public access, and persists changes through Core Data. It refreshes server metadata before invite/cancel changes and surfaces CloudKit conflicts and temporary errors without silently retrying mutations against changed participant lists.

A private owner maps to the pair's existing `playerOneID`. A private accepted participant in the shared store maps to its existing `playerTwoID`. Additional devices use those same players; each repository session has its own writer epoch (see Persistence.md). A pending invite cannot write. A different third recipient, a public share, unknown membership, duplicate accounts, and read-only shares are rejected. Canceling an unaccepted invite is repeatable; replacing an already accepted partner is not a supported flow.

Acceptance validates invitation metadata and calls Core Data's acceptance API into the shared store, including repeat acceptance on another device. The pair is discovered from the imported graph's share association, never from a caller-supplied pair UUID. Acceptance may finish before graph import; the harness shows this separately. Permission/server errors remain visible and retryable.

One pair root relates only to that pair's revisions. New revisions are assigned to the same persistent store and related to that existing root before saving. Core Data infers the shared record zone from this relationship. The shared route cannot create a replacement root in a cloud-enabled repository. Ambiguous/wrong-store roots are rejected. Unit graph checks prove local isolation; actual shared-zone placement still requires the real-device gate.

CloudKit enforces account access to the share/zone and read/write permissions. It does **not** enforce our two-person domain schema, append-only revisions, author UUIDs, or a global two-participant limit. An authorized modified client can change records; an owner can change the ACL outside our supported UI. Client validation and UUIDs are not server authorization. A revoked offline participant may still queue local work using cached membership; CloudKit decides whether export is allowed. Never report a local save as successful synchronization.

Account stores live under a SHA-256 account directory. The digest is a local namespace, not a credential. Account-change notifications invalidate cached identity. An online-verified `AuthorizedPairWriter` can queue writes during a disconnected session using cached identity and share permissions. Verification failure clears the harness's writer. Opening a new session requires online membership verification; comprehensive account switching/restoration is the later lifecycle issue, not claimed complete here.

## Development harness

Install the Debug app on each unlocked, paired, Developer Mode-enabled device signed into the intended iCloud account. Both accounts must be able to use this development container. Use Xcode's CloudKit Console to configure development access if Apple requires it for the partner. Keep all test devices on the same CloudKit environment.

```sh
xcrun devicectl device install app --device DEVICE_ID \
  iOS/.build-device/Build/Products/Debug-iphoneos/UsVsUs.app
xcrun devicectl device process launch --device DEVICE_ID --terminate-existing \
  com.galbraiths.joseph1970.usvsus --cloudkit-harness
```

For the first owner run only, append `--cloudkit-initialize-schema --cloudkit-create-pair`. This calls `initializeCloudKitSchema` for the development stores and creates a new disposable pair. It does not reset a schema, delete existing data, or deploy to production. Do not leave these flags enabled on routine relaunches: each launch creates another disposable graph. Inspect setup/export event outcomes; requesting initialization is not proof it succeeded.

The harness supports creating a disposable pair, selecting imported pairs, preparing a single named private invitation, canceling a pending invite, accepting an invitation URL, verifying membership online, and appending independent game-create revisions. An invitation link is only prepared; it is not sent automatically. The tester explicitly shares it with the named partner. App and scene callbacks also handle iCloud invitation delivery in Debug builds.

Tap Refresh after imports/exports. The report records device family/OS, account directory digest, pair/player IDs, revision IDs/origins/authors, row/distinct counts, quarantine state, actions, and setup/import/export event results. Event success is a completed CloudKit operation, not proof every other device received it. Compare actual revision IDs across reports. Add the actual device names/models to the evidence table; the generic UIKit device family is not enough to distinguish hardware.

Retrieve the harness's own report:

```sh
xcrun devicectl device copy from --device DEVICE_ID \
  --domain-type appDataContainer \
  --domain-identifier com.galbraiths.joseph1970.usvsus \
  --source Documents/cloudkit-report.txt \
  --destination iOS/TestResults/DEVICE_LABEL-cloudkit-report.txt
```

UI-test launches always use the isolated shell fixtures and cannot activate this harness. Release builds exclude the harness and invitation callbacks until product integration is implemented.

## Required real-account matrix — pending

1. Record physical device name/model, OS version, account label A/B (no passwords), build commit, signing summary, and development environment for A1, A2, B1, B2.
2. On A1 initialize development schema, create a disposable pair, wait for successful exports, and invite the named account B with read/write access. Record pair/player IDs and invitation state.
3. On B1 accept. Wait for the existing graph to import; verify membership maps to the original playerTwo. Append a revision on A1 and B1. Compare IDs and contents on both after completed imports.
4. On A2 and B2 launch the same build/account namespace, wait for import, and verify membership. Confirm the same two player IDs and history. Additional writer epochs are expected; additional Player records are not.
5. Verify a second disposable pair stays isolated. Confirm invite cancellation/retry behavior and the inability to invite a third participant through the supported flow. Verify a read-only or revoked share prevents online membership verification/writes; retain actual error results.
6. With A1 and B1 already verified, disconnect both devices. Append one independent revision on each. Record each local revision ID. Reconnect; wait for exports/imports and refresh all four reports. Both revisions must appear exactly once logically on every device, with unchanged IDs and authors. Record elapsed time, retries, event errors, and eventual convergence. Do not substitute a fixed sleep for evidence.
7. Rerun local tests on the final commit, include reports in PR evidence, then merge and verify main. Only then close #6 and advance #1 to #7.

Current device evidence (2026-09-07 11:09 UTC): the signed Debug build at `07c6cbcf9f3fae2f9c47b93d9bea7491d83fd698` launched on Joseph's unlocked iPhone (iPhone 16 Pro, iOS 26.6.1 / 23G83). The harness connected to the account, requested development-schema initialization, recorded successful setup events for both mirrored stores, and created disposable pair `6BFBE6EE-2D41-4524-980E-6F8149FD951F` with four distinct local revisions and no quarantine. The refreshed 11:11:27 UTC report records completed successful import and export events without errors. This demonstrates owner-side CloudKit activity; cross-device convergence is not yet verified. Evidence is in `iOS/TestResults/cloud-owner-20260907/`. Earlier locked-launch logs remain in `iOS/TestResults/cloud-device-blocker/` as historical evidence. The partner device/account and additional-device matrix remain unavailable, so the issue and PR are incomplete.

CloudKit also works in an iOS simulator signed into an Apple Account with iCloud enabled, as documented by Apple's [sharing sample](https://github.com/apple/sample-cloudkit-sharing). A simulator on a second account can exercise real partner-side CloudKit operations; one on the owner's account can exercise same-account synchronization. The account-free automated suite does neither. Sign in through the simulator's Settings app, and use a CloudKit-capable app build in the same development environment. This provides a useful development test path without a second physical phone; it does not silently rewrite the issue's explicitly required physical-device acceptance matrix.

## Local checks and references

Run `SIMULATOR_ID=... iOS/Scripts/validate.sh all`. Tests cover policy membership, wrong routes/accounts, public/read-only/third participants, pending writes, repeated/canceled/retried invitations, failed/repeated acceptance, delayed import, account changes, durable writer retry, and isolated graph insertion. No test double is counted as real CloudKit evidence.

Apple's [Core Data sharing session](https://developer.apple.com/videos/play/wwdc2021/10015/) explains zone sharing, relationship-based placement, and injectable sharing providers. The [Core Data sharing sample](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users) describes device prerequisites and shared-store setup. The installed SDK's `NSPersistentCloudKitContainer_Sharing.h` defines completion semantics: share creation does not imply export has finished.
