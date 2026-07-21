#!/usr/bin/env bash
# Build, Dev-ID sign, and install CECDashboard to /Applications.
# The installed copy's Keychain grant (service com.atlasautomates.lead-dashboard)
# is keyed to: Team 848NM75DCC + bundle com.atlasautomates.cecdashboard + a valid
# Developer ID signature. This script preserves all three — NEVER install the
# ad-hoc xcode/build.sh output over /Applications (it breaks headless --query).
# Local install only: --skip-notarize (Gatekeeper only quarantines downloads).
set -euo pipefail
cd "$(dirname "$0")/xcode"

IDENTITY="${CEC_SIGN_IDENTITY:-Developer ID Application: Adrian Tolentino (848NM75DCC)}"

xcodegen generate >/dev/null
xcodebuild -project CECDashboard.xcodeproj -scheme CECDashboard \
  -configuration Release -derivedDataPath build-rel \
  CODE_SIGNING_ALLOWED=NO build
APP="build-rel/Build/Products/Release/CECDashboard.app"

../../sign-mac-app.sh "$APP" --skip-notarize --identity "$IDENTITY"

osascript -e 'quit app "CECDashboard"' 2>/dev/null || true
rm -rf /Applications/CECDashboard.app
ditto "$APP" /Applications/CECDashboard.app

codesign -dvv /Applications/CECDashboard.app 2>&1 | grep -q "Authority=Developer ID Application" \
  || { echo "FAIL: installed app is not Developer-ID signed"; exit 1; }
# Acceptance: headless query must answer WITHOUT a Keychain prompt (grant survived).
OUT="$(/Applications/CECDashboard.app/Contents/MacOS/CECDashboard --query count 2>&1 || true)"
grep -q "leads" <<<"$OUT" || { echo "FAIL: headless --query broke (Keychain grant?): $OUT"; exit 1; }
echo "Installed + verified: $OUT"
