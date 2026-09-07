#!/bin/bash
set -euo pipefail
app=${1:?Usage: verify-device-signing.sh path/to/UsVsUs.app evidence-directory}
evidence=${2:?Provide an evidence directory}
mkdir -p "$evidence"
profile=$(mktemp)
trap 'rm -f "$profile"' EXIT
codesign --verify --deep --strict "$app"
codesign -d --entitlements :- "$app" > "$evidence/entitlements.plist" 2> "$evidence/codesign.txt"
security cms -D -i "$app/embedded.mobileprovision" > "$profile"
python3 - "$app/Info.plist" "$evidence/entitlements.plist" "$profile" "$evidence/profile-summary.json" <<'PY'
import datetime, json, plistlib, sys
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
with open(sys.argv[2], 'rb') as f: signed = plistlib.load(f)
with open(sys.argv[3], 'rb') as f: profile = plistlib.load(f)
bundle = 'com.galbraiths.joseph1970.usvsus'
team = 'ZBQ9AKMQTP'
container = 'iCloud.' + bundle
assert info['CFBundleIdentifier'] == bundle
assert signed['application-identifier'] == team + '.' + bundle
assert signed['com.apple.developer.team-identifier'] == team
assert signed['com.apple.developer.icloud-container-identifiers'] == [container]
assert signed['com.apple.developer.icloud-services'] == ['CloudKit']
assert signed['com.apple.developer.icloud-container-environment'] == 'Development'
assert signed['aps-environment'] == 'development'
assert profile['TeamIdentifier'] == [team]
entitlements = profile['Entitlements']
assert entitlements['application-identifier'] == signed['application-identifier']
assert container in entitlements['com.apple.developer.icloud-container-identifiers']
assert 'Development' in entitlements['com.apple.developer.icloud-container-environment']
assert entitlements['aps-environment'] == 'development'
assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
summary = dict(bundleIdentifier=bundle, teamIdentifier=team, containerIdentifier=container,
               profileName=profile['Name'], profileExpiration=profile['ExpirationDate'].isoformat(),
               cloudEnvironment='Development', verifiedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
with open(sys.argv[4], 'w') as f: json.dump(summary, f, indent=2)
print('Signed app and provisioning profile match the required bundle, team, and development CloudKit container.')
PY
