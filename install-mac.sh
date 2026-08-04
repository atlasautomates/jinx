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

# COPY → VERIFY → RENAME, with rollback. The previous ordering was `rm -rf` the
# working app and THEN `ditto` the new one: interrupt that (⌃C, disk full, sleep)
# and there is no app and nothing to roll back to. Staging inside /Applications
# keeps the swap on one volume, so the renames are atomic.
LIVE=/Applications/CECDashboard.app
STAGED=/Applications/.CECDashboard.staged
PREVIOUS=/Applications/.CECDashboard.previous
rm -rf "$STAGED" "$PREVIOUS"
cleanup() { rm -rf "$STAGED"; }        # a staged copy must never outlive a failure
trap cleanup EXIT

ditto "$APP" "$STAGED"
# Verify the SIGNATURE before anything is swapped — a bad signature must cost
# nothing. (The Keychain acceptance can only run after the swap: the grant is
# path-independent in principle, but this script is not the place to bet on it.)
codesign -dvv "$STAGED" 2>&1 | grep -q "Authority=Developer ID Application" \
  || { echo "FAIL: staged app is not Developer-ID signed — live app untouched"; exit 1; }

if [[ -d "$LIVE" ]]; then mv "$LIVE" "$PREVIOUS"; fi
mv "$STAGED" "$LIVE"

# Acceptance: headless query must answer WITHOUT a Keychain prompt (grant survived).
# This is the check that turns a broken Siri path into a loud failure — and now it
# can roll back instead of just reporting.
OUT="$(/Applications/CECDashboard.app/Contents/MacOS/CECDashboard --query count 2>&1 || true)"
if ! grep -q "leads" <<<"$OUT"; then
  echo "FAIL: headless --query broke (Keychain grant?): $OUT"
  if [[ -d "$PREVIOUS" ]]; then
    rm -rf "$LIVE"; mv "$PREVIOUS" "$LIVE"
    echo "ROLLED BACK to the previous install; it is live and unchanged."
  fi
  exit 1
fi
rm -rf "$PREVIOUS"
# The bundle id and version are identical across the swap, which is exactly when
# Finder/Dock keep serving a cached icon representation — and the copy being
# replaced has no icon keys at all, so without this the icon work looks unshipped.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f /Applications/CECDashboard.app || true
killall Dock 2>/dev/null || true

echo "Installed + verified: $OUT"
