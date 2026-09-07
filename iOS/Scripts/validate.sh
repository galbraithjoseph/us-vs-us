#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-all}"
case "$mode" in build|unit|ui|all) ;; *) echo "Usage: $0 [build|unit|ui|all]" >&2; exit 2 ;; esac
: "${SIMULATOR_ID:?Set SIMULATOR_ID from xcrun simctl list devices available}"
report="TestResults/$(date -u +%Y%m%dT%H%M%SZ)-${mode}-$$"
mkdir -p "$report"
git rev-parse HEAD > "$report/commit.txt"
git status --porcelain > "$report/worktree.txt"
xcodebuild -version > "$report/xcode.txt"
xcrun simctl list devices available > "$report/devices.txt"
args=(-project UsVsUs.xcodeproj -scheme UsVsUs -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath .build CODE_SIGNING_ALLOWED=NO)
for configuration in Debug Release; do
    xcodebuild "${args[@]}" -configuration "$configuration" -showBuildSettings -json > "$report/settings-$configuration.json"
done
python3 - "$report" <<'PY'
import json, pathlib, sys
for configuration in ('Debug', 'Release'):
    settings = json.loads((pathlib.Path(sys.argv[1]) / f'settings-{configuration}.json').read_text())
    app = next(row['buildSettings'] for row in settings if row['target'] == 'UsVsUs')
    assert app['PRODUCT_BUNDLE_IDENTIFIER'] == 'com.galbraiths.joseph1970.usvsus'
    assert app['DEVELOPMENT_TEAM'] == 'ZBQ9AKMQTP'
print('Debug and Release app identifiers and signing teams verified.')
PY
case "$mode" in
    build) action=(build) ;;
    unit) action=(test -only-testing:UsVsUsTests) ;;
    ui) action=(test -only-testing:UsVsUsUITests) ;;
    all) action=(test) ;;
esac
printf '%q ' xcodebuild "${args[@]}" "${action[@]}" -parallel-testing-enabled NO -resultBundlePath "$report/results.xcresult" > "$report/command.txt"
printf '\n' >> "$report/command.txt"
xcodebuild "${args[@]}" "${action[@]}" -parallel-testing-enabled NO -resultBundlePath "$report/results.xcresult" 2>&1 | tee "$report/xcodebuild.log"
echo "Reports: iOS/$report"
