# Us vs Us for iOS

Open `UsVsUs.xcodeproj` and select the checked-in **UsVsUs** shared scheme. The current shell has Home and Settings screens, a locally saved setup-help preference, and deterministic unit/UI test entry points. The domain schema and Core Data repositories are implemented beneath the shell; pairing, feature screens, and CloudKit sharing remain tracked work. See [storage and crash recovery](Documentation/Persistence.md) and the [portable schema](../portable/README.md).

## Supported environment

- Deployment target: **iOS/iPadOS 18.0 or later**.
- Local development/test toolchain: **Xcode 27.0 (27A5252f)**, currently installed as `/Applications/Xcode-beta.app`. Earlier Xcode versions are not validated.
- iPhone and iPad use native tabs and navigation stacks in portrait and landscape; content adapts to the available window size and system text size.
- No package dependencies, generated project prerequisite, hosted CI, GitHub Actions, or Xcode Cloud configuration.

## Signing

`Configuration/Shared.xcconfig` applies to Debug and Release for the app and both test targets:

- App bundle ID: `com.galbraiths.joseph1970.usvsus`.
- Development team: **Joseph Galbraith**, ID **ZBQ9AKMQTP**.
- Automatic signing. Test bundles append `.UsVsUsTests` and `.UsVsUsUITests`.

The team ID was resolved from the installed Apple Development certificate's `O=Joseph Galbraith` and `OU=ZBQ9AKMQTP`, with a certificate valid April 4, 2026–April 4, 2027. The name suffix of an Apple Development certificate is not the team ID. No certificate, private key, account token, or provisioning profile is checked in.

Simulator commands disable code signing and need no iCloud account. For a physical device, add the Joseph Galbraith Apple Developer account to Xcode and allow automatic signing. CloudKit entitlements and the container are deliberately not enabled in the scaffold: issue #6 will provision and verify the intended `iCloud.com.galbraiths.joseph1970.usvsus` container, private/shared stores, and sharing capability. This is a planned identifier, not evidence of a provisioned container.

## Reproducible local validation

From a clean checkout at the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild -version
xcrun simctl list devices available
export SIMULATOR_ID='<available iPhone or iPad simulator UUID>'
iOS/Scripts/validate.sh build
iOS/Scripts/validate.sh unit
iOS/Scripts/validate.sh ui
# Or run both test targets in one invocation:
iOS/Scripts/validate.sh all
```

Validation uses the checked-in scheme and checks resolved Debug/Release bundle and team settings. Each run retains its commit, worktree status, Xcode version, simulator inventory, exact command, build settings, log, and `.xcresult` in ignored `iOS/TestResults/`. Open a result bundle in Xcode to inspect tests and UI-test attachments. Keep these local reports; record their paths and outcomes in the PR. Build products live in ignored `iOS/.build/`.

Equivalent direct commands (run from the repository root):

```sh
xcodebuild -project iOS/UsVsUs.xcodeproj -scheme UsVsUs \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath iOS/.build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iOS/UsVsUs.xcodeproj -scheme UsVsUs \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath iOS/.build CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -resultBundlePath iOS/TestResults/unit.xcresult \
  test -only-testing:UsVsUsTests
xcodebuild -project iOS/UsVsUs.xcodeproj -scheme UsVsUs \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath iOS/.build CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -resultBundlePath iOS/TestResults/ui.xcresult \
  test -only-testing:UsVsUsUITests
```

Use a new result-bundle path for each direct invocation. To launch the built app normally without a signed-in account:

```sh
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl install "$SIMULATOR_ID" iOS/.build/Build/Products/Debug-iphonesimulator/UsVsUs.app
xcrun simctl launch "$SIMULATOR_ID" com.galbraiths.joseph1970.usvsus
```

## Dependencies and test isolation

`AppDependencies` injects shell persistence, time, UUID generation, and cloud status. The live shell stores only its setup-help preference in UserDefaults; this is not a substitute for the Core Data domain store. Cloud status truthfully reports that sharing is not configured.

Debug UI-test launches pass `--ui-testing`. Every launch receives a new in-memory preference store, fixed time/UUID generators, and unavailable-cloud status. `--fixture-help-hidden` seeds a non-default preference. Removing that flag restores the empty fixture on the next launch. Tests never reset or read production preferences. Release builds ignore both flags.

The unit suite verifies injected services, preference persistence across recreation, and independent fixture launches. UI smoke tests navigate Home/Settings, change a preference, terminate/relaunch, and compare seeded/empty launches to verify isolation. Run UI tests twice to verify independent test invocations. Real CloudKit/account/device checks remain required in the relevant later issues; these fixtures do not provide cloud validation.
