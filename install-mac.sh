#!/usr/bin/env bash
# Build, Dev-ID sign, and install CECDashboard to /Applications.
# The installed copy's Keychain grant (service com.atlasautomates.lead-dashboard)
# is keyed to: Team 848NM75DCC + bundle com.atlasautomates.cecdashboard + a valid
# Developer ID signature. This script preserves all three — NEVER install the
# ad-hoc xcode/build.sh output over /Applications (it breaks headless --query).
# Local install only: --skip-notarize (Gatekeeper only quarantines downloads).
#
# CREDENTIAL ORDER (7.2 remap): the app reads the v_cec_* views with TWO
# Keychain items (6.1 intel: the gateway validates the apikey HEADER against
# known keys, so the reader JWT must ride ONLY the bearer while the anon key
# rides apikey). Seed BOTH before running this — the pre-remap build cannot
# use them, so the outage window is exactly this script's runtime:
#   security add-generic-password -s com.atlasautomates.lead-dashboard \
#     -a supabase_api_key -w "$READER_JWT" -T /Applications/CECDashboard.app -U
#   security add-generic-password -s com.atlasautomates.lead-dashboard \
#     -a supabase_anon_key -w "$ANON_KEY" -T /Applications/CECDashboard.app -U
# (-w with the VALUE inline — the arg-less form prompts the TTY and truncates.)
set -euo pipefail
cd "$(dirname "$0")/xcode"

IDENTITY="${CEC_SIGN_IDENTITY:-Developer ID Application: Adrian Tolentino (848NM75DCC)}"

xcodegen generate >/dev/null
xcodebuild -project CECDashboard.xcodeproj -scheme CECDashboard \
  -configuration Release -derivedDataPath build-rel \
  CODE_SIGNING_ALLOWED=NO build
APP="build-rel/Build/Products/Release/CECDashboard.app"

../../sign-mac-app.sh "$APP" --skip-notarize --identity "$IDENTITY"

# A TCC Automation denial must not pass silently: the old GUI keeps running
# through the bundle swap and the acceptance below, which muddies diagnosis.
if ! osascript -e 'quit app "CECDashboard"' 2>/dev/null; then
  echo "WARN: could not ask CECDashboard to quit (TCC Automation denied, or not"
  echo "      running) — if the app is open, the swap proceeds under it; quit it"
  echo "      manually and relaunch after the install."
fi

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
#
# CAPTURE THEN MATCH — never `codesign … | grep -q` under `set -o pipefail`.
#
# `grep -q` exits the moment it matches, `codesign` gets SIGPIPE and returns 141,
# and pipefail then reports the PIPELINE as failed — precisely BECAUSE the pattern
# was found. Whether it bites depends on which process wins the race, which is why
# this looked like a flaky "trustd lag" when it was first seen (2026-07-24) and was
# recorded as a known nit rather than a bug. On 2026-08-03 it lost the race five
# times in a row and aborted a perfectly good install. A here-string has no pipe and
# no race.
signed_ok() {
  local out
  out="$(codesign -dvv "$1" 2>&1)" || return 1
  grep -q "Authority=Developer ID Application" <<<"$out"
}
signed_ok "$STAGED" \
  || { echo "FAIL: staged app is not Developer-ID signed — live app untouched"; exit 1; }

if [[ -d "$LIVE" ]]; then mv "$LIVE" "$PREVIOUS"; fi
mv "$STAGED" "$LIVE"

# Acceptance: headless query must answer WITHOUT a Keychain prompt (grant survived).
# This is the check that turns a broken Siri path into a loud failure — and now it
# can roll back instead of just reporting.
#
# Exit code AND an anchored pattern — `grep -q "leads"` alone would PASS a Debug
# build's 401 body ("permission denied for view v_cec_leads" contains "leads"),
# accepting a completely broken credential (reliability review, 7.2).
accepts() {
  local out rc=0
  out="$(/Applications/CECDashboard.app/Contents/MacOS/CECDashboard --query count 2>&1)" || rc=$?
  OUT="$out"   # keep the output either way — a FAIL that hides the error text is undiagnosable
  [ "$rc" -eq 0 ] && grep -qE '^You have [0-9]+ leads\.$' <<<"$out"
}
if ! accepts; then
  echo "FAIL: headless --query broke (wrong Keychain credential? see the CREDENTIAL"
  echo "ORDER note at the top of this script). Output was:"
  echo "  $OUT"
  if [[ -d "$PREVIOUS" ]]; then
    rm -rf "$LIVE"; mv "$PREVIOUS" "$LIVE"
    # The rolled-back build must PROVE it answers before this script calls it
    # live — after the 7.2 credential swap the previous build is usually just
    # as dead, and "live and unchanged" sent the operator away happy while
    # nothing worked (macos platform review).
    if accepts; then
      echo "ROLLED BACK to the previous install; it is live and answering."
    else
      echo "ROLLED BACK, but the PREVIOUS build does not answer either — both builds"
      echo "are broken against the current Keychain credentials. Fix them"
      echo "(supabase_api_key must hold the arcane_read_cec reader JWT AND"
      echo "supabase_anon_key must hold the project anon key — see the CREDENTIAL"
      echo "ORDER note above) and re-run this script."
    fi
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
